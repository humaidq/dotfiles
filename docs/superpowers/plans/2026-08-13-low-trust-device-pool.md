# Low-Trust Device Pool Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give named devices on bingo a stricter egress policy — extra port, subnet and public-STUN drops — and deny them CAKE's Voice tin, with membership held in a sops secret plus a runtime set the peers page can toggle.

**Architecture:** Two nftables sets of type `ether_addr` decide membership; a permanent one loaded at runtime from a sops secret and a temporary one mutated by a `lowtrust` CLI. Both jump to one `lowtrust_policy` chain holding the drops. A separate pair of rules in the existing `qos-mark` chain neutralises the conntrack mark and bleaches the device's own DSCP, which covers both traffic directions because the mark lives on the conntrack entry.

**Both pairs of sets are declared twice, in two tables.** The drop chains live in `inet router-blocklists`; `qos-mark` lives in `inet router-filter`. nftables sets are scoped to their table and there is no mechanism for sharing one across tables, so `lowtrust_macs` and `lowtrust_macs_temp` are declared in each, and every writer — the loader service and the CLI — updates both. Getting this wrong produces a ruleset that builds cleanly and fails at load with `set 'lowtrust_macs' does not exist`, so it is called out in every task that touches a set.

**Tech Stack:** NixOS modules (`modules/router/`), nftables, systemd oneshots and timers, bash (`writeShellApplication`), Go 1.x stdlib `net/http` for the peers page.

## Global Constraints

- **Scope is bingo only.** `sifr.router.lowTrust.enable` defaults to `false`; bongo must be unchanged. Every set, chain, rule, service and tool is gated on that option.
- **The MAC list is a secret.** It lives in `secrets/bingo.yaml` under the key `router/lowtrust-macs`. It must never be read with `builtins.readFile`, interpolated into a derivation, or otherwise reach the Nix store — the store is world-readable and this repository is public. Only the *path* to the decrypted file may appear in the store.
- **Nix string escaping.** All the shell below lives inside Nix `''` strings. Any literal `${` in shell (parameter expansion, `${var%%#*}`) must be written `''${` or Nix will try to interpolate it. This is the single most likely way these tasks break.
- **Commit with `--no-gpg-sign`.** The signing key is a hardware token that cannot be touched from an agent session.
- **Build gate:** `nix build --no-link '.#nixosConfigurations.bingo.config.system.build.toplevel'` must pass, and so must the same for `bongo`.
- **Formatting:** run `nix fmt` before every commit.
- Existing comment style in `modules/router/` is dense and explains *why*. Match it. Do not add comments that restate the code.

---

### Task 1: Options, sets, secret, and the loader service

**Files:**
- Modify: `modules/router/default.nix` (options block, after the `imoThrottle` block ending ~line 188; **and** the `router-filter` table content at ~line 386)
- Modify: `modules/router/ip-blocklist.nix` (set declarations ~line 340; new systemd service after `nft-blocklists-local` ~line 566)
- Modify: `hosts/bingo/default.nix` (sops secret declaration ~line 51; `sifr.router.lowTrust` config ~line 147)
- Modify: `secrets/bingo.yaml` (via `sops`, not by hand)

**Interfaces:**
- Produces: option `sifr.router.lowTrust.enable` (bool), option `sifr.router.lowTrust.macFile` (nullOr path); nft sets `lowtrust_macs` and `lowtrust_macs_temp` of type `ether_addr` **in both** `inet router-blocklists` and `inet router-filter`; systemd unit `nft-lowtrust-macs.service`.
- Consumes: nothing.

- [ ] **Step 1: Add the options**

In `modules/router/default.nix`, directly after the `imoThrottle = { ... };` block:

```nix
    # A pool of devices given a stricter egress policy than the rest of the
    # LAN, identified by MAC. See
    # docs/superpowers/specs/2026-08-13-low-trust-device-pool-design.md.
    #
    # MAC rather than IP because a device that sets its own address stays in
    # the pool. The known and unmitigated weakness is the other direction: a
    # device that randomises its MAC leaves the pool silently, and this network
    # has seen MAC rotation before.
    lowTrust = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Enforce the low-trust device pool. Off means no sets, no chains, no service, and no tool.";
      };
      macFile = lib.mkOption {
        type = with lib.types; nullOr path;
        default = null;
        description = ''
          Path to the decrypted file listing pool MAC addresses, one per line,
          `#` comments allowed.

          A path rather than a list of strings on purpose: the list identifies
          people's devices, this repository is public, and anything given to a
          NixOS option ends up world-readable in the Nix store. Point this at a
          sops secret's `.path`.
        '';
      };
    };
```

- [ ] **Step 2: Declare the two sets**

In `modules/router/ip-blocklist.nix`, inside `networking.nftables.tables.router-blocklists.content`, after the `blocked_ports` set declaration:

```nix
        ${lib.optionalString cfg.lowTrust.enable ''
          # Membership in the low-trust pool, matched as `ether saddr`, which is
          # only visible on the LAN-ingress (upload) direction — a download's
          # source MAC is the ISP's. That is sufficient because every consumer
          # either drops the packet outright or sets a ct mark, and a ct mark
          # applies to both directions of the conversation.
          #
          # Two sets rather than one so that removal is safe: the peers page can
          # only touch the _temp set, so a button press can never silently undo
          # a device that was deliberately put in the permanent list. A device
          # in both is simply in the pool.
          set lowtrust_macs {
            type ether_addr
          }

          set lowtrust_macs_temp {
            type ether_addr
          }
        ''}
```

- [ ] **Step 3: Declare the same two sets in the other table**

`qos-mark` is in `inet router-filter`, declared in `modules/router/default.nix` at ~line 386, and nft sets cannot be shared across tables. Add to that table's `content`, near its other `set` declarations:

```nix
            ${lib.optionalString cfg.lowTrust.enable ''
              # Declared here as well as in router-blocklists, and populated by
              # the same service. nftables sets are scoped to their table with
              # no way to share one, and qos-mark needs the membership as much
              # as the drop chains do. Two declarations, one writer.
              set lowtrust_macs {
                type ether_addr
              }

              set lowtrust_macs_temp {
                type ether_addr
              }
            ''}
```

- [ ] **Step 4: Add the loader service**

In `modules/router/ip-blocklist.nix`, after the `nft-blocklists-local` service block:

```nix
    # Loads the permanent pool membership from the sops secret. A service
    # rather than a generated .nft file because the list must not reach the Nix
    # store: it names people's devices and this repository is public.
    #
    # partOf nftables.service for the same reason nft-blocklists-local is —
    # a ruleset reload recreates the table with empty sets, which would
    # silently empty the pool until the next rebuild.
    systemd.services.nft-lowtrust-macs = lib.mkIf cfg.lowTrust.enable {
      description = "Load low-trust pool MAC addresses";
      wantedBy = [ "multi-user.target" ];
      after = [ "nftables.service" ];
      wants = [ "nftables.service" ];
      partOf = [ "nftables.service" ];

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };

      path = with pkgs; [
        nftables
        gnugrep
        gnused
        coreutils
      ];

      # Fails loudly on a missing or malformed file rather than loading an
      # empty set. The plaintext lists get a build-time parse that fails the
      # rebuild on a typo; a runtime secret cannot, so a failed unit is the
      # substitute for that guarantee. An empty pool is a silent fail-open.
      script = ''
        set -euo pipefail

        file=${lib.escapeShellArg (toString cfg.lowTrust.macFile)}

        if [ ! -r "$file" ]; then
          echo "nft-lowtrust-macs: cannot read $file" >&2
          exit 1
        fi

        elements=""
        while IFS= read -r line || [ -n "$line" ]; do
          line=''${line%%#*}
          line=$(printf '%s' "$line" | tr -d '[:space:]' | tr 'A-F' 'a-f')
          [ -z "$line" ] && continue
          if ! printf '%s' "$line" | grep -qE '^([0-9a-f]{2}:){5}[0-9a-f]{2}$'; then
            echo "nft-lowtrust-macs: malformed MAC address: $line" >&2
            exit 1
          fi
          elements="$elements$line, "
        done < "$file"

        # Both tables, because the sets are declared in both and nftables has
        # no way to share one. Missing the second is the failure mode this
        # whole plan keeps warning about: the ruleset builds, and qos-mark
        # fails to load at runtime.
        for table in router-blocklists router-filter; do
          nft flush set inet "$table" lowtrust_macs
          if [ -n "$elements" ]; then
            nft add element inet "$table" lowtrust_macs "{ ''${elements%, } }"
          fi
        done
      '';
    };
```

Note the two escaped expansions: `''${line%%#*}` and `''${elements%, }`. Written as `${` they become Nix interpolation and the build fails with an obscure error.

- [ ] **Step 5: Create the secret**

```bash
cd /home/humaid/repos/dotfiles
sops secrets/bingo.yaml
```

Add a key `router/lowtrust-macs` whose value is a multi-line string. Seed it with a comment line only, so the file exists and parses before any real device is added:

```yaml
router:
    lowtrust-macs: |
        # Low-trust pool membership, one MAC per line. See
        # docs/superpowers/specs/2026-08-13-low-trust-device-pool-design.md
```

- [ ] **Step 6: Wire it up on bingo**

In `hosts/bingo/default.nix`, alongside the other `sops.secrets` declarations:

```nix
  sops.secrets."router/lowtrust-macs" = {
    sopsFile = ../../secrets/bingo.yaml;
    mode = "0400";
    restartUnits = [ "nft-lowtrust-macs.service" ];
  };
```

and in the `sifr.router` block:

```nix
      lowTrust = {
        enable = true;
        macFile = config.sops.secrets."router/lowtrust-macs".path;
      };
```

- [ ] **Step 7: Build both routers**

```bash
cd /home/humaid/repos/dotfiles && nix fmt
nix build --no-link '.#nixosConfigurations.bingo.config.system.build.toplevel'
nix build --no-link '.#nixosConfigurations.bongo.config.system.build.toplevel'
```

Expected: both succeed. If bingo fails with `undefined variable` or a parse error pointing at the script, the `''${` escaping in Step 3 is wrong.

- [ ] **Step 8: Verify the secret never reached the store**

```bash
p=$(nix build --no-link --print-out-paths '.#nixosConfigurations.bingo.config.system.build.toplevel')
grep -rl 'lowtrust-macs' $p/etc/systemd/system/ | head
grep -rniE '([0-9a-f]{2}:){5}[0-9a-f]{2}' $(grep -rl 'lowtrust' $p/etc/systemd/system/ | head -1) || echo "no MAC literals in the unit - correct"
```

Expected: the unit references the `/run/secrets/...` path, and no MAC address literal appears anywhere in the store output.

- [ ] **Step 9: Commit**

```bash
git add modules/router/default.nix modules/router/ip-blocklist.nix hosts/bingo/default.nix secrets/bingo.yaml
git commit --no-gpg-sign -m "router: low-trust pool membership sets and loader"
```

---

### Task 2: The policy chain — ports and subnets

**Files:**
- Create: `modules/router/custom-lowtrust-ports.txt`
- Create: `modules/router/custom-lowtrust-subnets.txt`
- Modify: `modules/router/ip-blocklist.nix` (generator invocations ~line 168; set declarations; new chains)

**Interfaces:**
- Consumes: sets `lowtrust_macs`, `lowtrust_macs_temp` from Task 1.
- Produces: chains `forward_lowtrust` (hook forward, priority -10) and `lowtrust_policy` (regular); sets `lowtrust_ports`, `lowtrust_block4`, `lowtrust_block6`.

- [ ] **Step 1: Create the ports file**

`modules/router/custom-lowtrust-ports.txt`:

```
# Ports dropped LAN->WAN for devices in the low-trust pool only. The global
# custom-port-blocklist.txt is unchanged and applies to everybody; this file is
# the stricter set that only pool devices get.
#
# Same format and guarantees as that file: parsed at build time, so a typo
# fails the rebuild rather than silently blocking nothing.
#
# Seeded from the 2026-08-13 captures, which showed one client using each of
# these as a transport with nothing resembling the port's real protocol on it.
# 22 is deliberately NOT in the global file: SSH from other devices on this LAN
# is legitimate, and that is exactly the distinction this pool exists to draw.
21
22
553
554
```

- [ ] **Step 2: Create the subnets file**

`modules/router/custom-lowtrust-subnets.txt`:

```
# Destination networks dropped LAN->WAN for devices in the low-trust pool only.
#
# Unlike custom-ip-blocklist.txt this file is meant to hold BLANKET entries —
# a /16 or wider where a provider is not worth enumerating host by host for a
# device that has no business there. That is only defensible because it applies
# to the pool rather than the house.
#
# One CIDR per line, v4 or v6, # comments. Parsed at build time.
#
# Empty on purpose. Add ranges as they are decided; a subnet is not
# device-identifying, so unlike the MAC list this file belongs in git where it
# can be reviewed.
```

- [ ] **Step 3: Generate the sets from those files**

`ip-blocklist.nix` already builds `.nft` files from the plaintext lists with python generators around line 160-175. Add two more alongside them, following the existing pattern exactly. Find the existing `portBlocklist` and `localBlocklist` derivations and add:

```nix
  # Reuses portBlocklistGen verbatim, exactly as throttleList reuses
  # localBlocklistGen: same format, same build-time validation, only the target
  # set differs.
  lowTrustPorts =
    pkgs.runCommand "nft-lowtrust-ports.nft"
      {
        nativeBuildInputs = [ pkgs.python3 ];
      }
      ''
        python3 ${portBlocklistGen} ${./custom-lowtrust-ports.txt} "$out" \
          router-blocklists lowtrust_ports
      '';

  lowTrustSubnets =
    pkgs.runCommand "nft-lowtrust-subnets.nft"
      {
        nativeBuildInputs = [ pkgs.python3 ];
      }
      ''
        python3 ${localBlocklistGen} ${./custom-lowtrust-subnets.txt} "$out" \
          router-blocklists lowtrust_block4 lowtrust_block6
      '';
```

`portBlocklistGen` and `localBlocklistGen` already exist in that file's `let` block; `nativeBuildInputs` is required or `python3` is not on PATH in the builder.

- [ ] **Step 4: Declare the three sets**

Inside the same `lib.optionalString cfg.lowTrust.enable` block added in Task 1 Step 2:

```nix
          set lowtrust_ports {
            type inet_service
          }

          set lowtrust_block4 {
            type ipv4_addr
            flags interval
          }

          set lowtrust_block6 {
            type ipv6_addr
            flags interval
          }
```

- [ ] **Step 5: Add the chains**

In the same `content`, after the `forward_ports` chain:

```nix
        ${lib.optionalString cfg.lowTrust.enable ''
          # Entry point for the pool. Two membership rules jumping to one policy
          # chain, so the policy is written once rather than duplicated per set.
          #
          # Priority -10 matches forward_ports and forward_blocklists, which
          # puts these drops ahead of forward_throttle at 0: a pool device
          # reaching a throttled address is dropped rather than shaped, matching
          # the precedence the other chains already establish.
          chain forward_lowtrust {
            type filter hook forward priority -10; policy accept;

            ether saddr @lowtrust_macs jump lowtrust_policy
            ether saddr @lowtrust_macs_temp jump lowtrust_policy
          }

          # Scoped LAN -> WAN, so traffic between LAN devices is untouched.
          # Traffic to the router itself needs no rule and gets none: it arrives
          # at the input hook, and this chain is on forward. That is
          # load-bearing rather than incidental — a pool device must keep
          # reaching the router's resolver, because one that cannot falls back
          # to something worse, which is the opposite of the intent.
          #
          # Log and verdict are separate rules throughout, for the reason
          # forward_blocklists documents: a limit on the verdict rule would let
          # packets over the rate escape the drop.
          chain lowtrust_policy {
            iifname "${cfg.lan0}" oifname "${cfg.ppp}" meta l4proto { tcp, udp } th dport @lowtrust_ports limit rate 60/minute burst 20 packets log prefix "nft-block-lowtrust " comment "sample low-trust port drops"
            iifname "${cfg.lan0}" oifname "${cfg.ppp}" meta l4proto { tcp, udp } th dport @lowtrust_ports counter drop comment "low-trust port drop"

            iifname "${cfg.lan0}" oifname "${cfg.ppp}" ip daddr @lowtrust_block4 limit rate 60/minute burst 20 packets log prefix "nft-block-lowtrust " comment "sample low-trust subnet drops"
            iifname "${cfg.lan0}" oifname "${cfg.ppp}" ip daddr @lowtrust_block4 counter drop comment "low-trust subnet drop (IPv4)"
            iifname "${cfg.lan0}" oifname "${cfg.ppp}" ip6 daddr @lowtrust_block6 counter drop comment "low-trust subnet drop (IPv6)"
          }
        ''}
```

- [ ] **Step 6: Load the generated files**

In `systemd.services.nft-blocklists-local`'s `script`, add the two new files:

```nix
        nft -f ${lowTrustPorts}
        nft -f ${lowTrustSubnets}
```

Guard both with `lib.optionalString cfg.lowTrust.enable` so a router with the feature off does not try to populate sets that do not exist.

- [ ] **Step 7: Build**

```bash
nix fmt && nix build --no-link '.#nixosConfigurations.bingo.config.system.build.toplevel'
nix build --no-link '.#nixosConfigurations.bongo.config.system.build.toplevel'
```

Expected: both pass. A failure naming `lowtrust_ports` usually means the generator argument order in Step 3 does not match the existing helper.

- [ ] **Step 8: Verify the generated ruleset**

```bash
p=$(nix build --no-link --print-out-paths '.#nixosConfigurations.bingo.config.system.build.toplevel')
grep -rn 'lowtrust_policy' $p/etc/ | head -3
```

Expected: the chain appears with both membership jumps.

- [ ] **Step 9: Commit**

```bash
git add modules/router/custom-lowtrust-ports.txt modules/router/custom-lowtrust-subnets.txt modules/router/ip-blocklist.nix
git commit --no-gpg-sign -m "router: low-trust port and subnet drops"
```

---

### Task 3: Narrow public-STUN drops

**Files:**
- Create: `modules/router/custom-lowtrust-stun-hosts.txt`
- Modify: `modules/router/ip-blocklist.nix` (sets, policy chain, new service and timer)

**Interfaces:**
- Consumes: chain `lowtrust_policy` from Task 2.
- Produces: sets `lowtrust_stun4`, `lowtrust_stun6`; units `nft-lowtrust-stun.service` and `.timer`.

- [ ] **Step 1: Create the hosts file**

`modules/router/custom-lowtrust-stun-hosts.txt`:

```
# Generic public STUN servers, dropped for low-trust pool devices only.
#
# NAMES, not addresses, because these move; a timer resolves them into
# lowtrust_stun4/6.
#
# Why this list is narrow, and why STUN is NOT matched by signature: the
# qos-mark chain already matches the STUN magic cookie at a fixed payload
# offset, and reusing that as a drop would kill every WebRTC call on the
# device. Botim, Comera and GoChat must keep working. These three are the
# generic servers an arbitrary app uses for NAT discovery, which is what the
# tunnel client uses them for; app-specific STUN and TURN are not here and are
# not touched.
#
# The drop is port-scoped to 3478/5349/19302 rather than applied to the whole
# address, because stun.l.google.com resolves onto Google edge addresses shared
# with unrelated services. Port-scoped, the collateral is only STUN.
stun.l.google.com
stun.nextcloud.com
stun.voip.blackberry.com
```

- [ ] **Step 2: Declare the sets**

In the `lib.optionalString cfg.lowTrust.enable` set block:

```nix
          set lowtrust_stun4 {
            type ipv4_addr
          }

          set lowtrust_stun6 {
            type ipv6_addr
          }
```

- [ ] **Step 3: Add the drop rules**

Append to `chain lowtrust_policy`, after the subnet rules:

```nix
            iifname "${cfg.lan0}" oifname "${cfg.ppp}" udp dport { 3478, 5349, 19302 } ip daddr @lowtrust_stun4 limit rate 60/minute burst 20 packets log prefix "nft-block-lowtrust " comment "sample low-trust STUN drops"
            iifname "${cfg.lan0}" oifname "${cfg.ppp}" udp dport { 3478, 5349, 19302 } ip daddr @lowtrust_stun4 counter drop comment "low-trust public STUN drop (IPv4)"
            iifname "${cfg.lan0}" oifname "${cfg.ppp}" udp dport { 3478, 5349, 19302 } ip6 daddr @lowtrust_stun6 counter drop comment "low-trust public STUN drop (IPv6)"
```

- [ ] **Step 4: Add the resolver service and timer**

```nix
    # Resolves the public STUN server names into the drop sets. A timer rather
    # than a build-time resolution because those addresses move, and a stale
    # entry is a silently open hole rather than a visible failure.
    #
    # Deliberately tolerant where the MAC loader is strict: a name that fails to
    # resolve is skipped with a warning rather than failing the unit. The
    # failure mode differs — an unresolvable name leaves one STUN server
    # reachable, where an unreadable MAC file would empty the whole pool.
    systemd.services.nft-lowtrust-stun = lib.mkIf cfg.lowTrust.enable {
      description = "Resolve public STUN servers into the low-trust drop sets";
      after = [ "nftables.service" "network-online.target" ];
      wants = [ "nftables.service" "network-online.target" ];
      partOf = [ "nftables.service" ];
      wantedBy = [ "multi-user.target" ];

      # RemainAfterExit deliberately false, unlike nft-lowtrust-macs. systemd
      # treats `start` on an already-active oneshot as a no-op, so leaving this
      # one active would quietly stop the timer from ever re-resolving — the
      # exact trap imo-policy is commented against. partOf still re-triggers it
      # on a ruleset reload through wantedBy.
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = false;
      };

      path = with pkgs; [
        nftables
        dnsutils
        gnugrep
        gnused
        coreutils
      ];

      script = ''
        set -euo pipefail

        v4=""
        v6=""
        while IFS= read -r line || [ -n "$line" ]; do
          name=''${line%%#*}
          name=$(printf '%s' "$name" | tr -d '[:space:]')
          [ -z "$name" ] && continue

          got=""
          for addr in $(dig +short +timeout=3 +tries=2 "$name" A 2>/dev/null || true); do
            case "$addr" in
              *[!0-9.]*) continue ;;
            esac
            v4="$v4$addr, "
            got=yes
          done
          for addr in $(dig +short +timeout=3 +tries=2 "$name" AAAA 2>/dev/null || true); do
            case "$addr" in
              *:*) v6="$v6$addr, " ; got=yes ;;
            esac
          done

          [ -z "$got" ] && echo "nft-lowtrust-stun: could not resolve $name" >&2
        done < ${./custom-lowtrust-stun-hosts.txt}

        nft flush set inet router-blocklists lowtrust_stun4
        nft flush set inet router-blocklists lowtrust_stun6
        if [ -n "$v4" ]; then
          nft add element inet router-blocklists lowtrust_stun4 "{ ''${v4%, } }"
        fi
        if [ -n "$v6" ]; then
          nft add element inet router-blocklists lowtrust_stun6 "{ ''${v6%, } }"
        fi
      '';
    };

    systemd.timers.nft-lowtrust-stun = lib.mkIf cfg.lowTrust.enable {
      description = "Refresh low-trust public STUN addresses";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "5m";
        OnUnitActiveSec = "1h";
        Persistent = true;
      };
    };
```

- [ ] **Step 5: Build and verify**

```bash
nix fmt && nix build --no-link '.#nixosConfigurations.bingo.config.system.build.toplevel'
nix build --no-link '.#nixosConfigurations.bongo.config.system.build.toplevel'
```

- [ ] **Step 6: Commit**

```bash
git add modules/router/custom-lowtrust-stun-hosts.txt modules/router/ip-blocklist.nix
git commit --no-gpg-sign -m "router: drop public STUN for low-trust devices"
```

---

### Task 4: Deny the Voice tin

**Files:**
- Modify: `modules/router/default.nix` (the `qos-mark` chain, ~lines 506-531)

**Interfaces:**
- Consumes: sets `lowtrust_macs`, `lowtrust_macs_temp` from Task 1.
- Produces: nothing consumed by later tasks.

- [ ] **Step 1: Add the rules**

In `modules/router/default.nix`, inside `chain qos-mark`, **after** the `lowPriorityPorts` block and **before** the four `ct mark ... dscp set` translation rules:

```nix
              # Low-trust devices never reach CAKE's Voice tin. Placed after
              # every mark rule above so it overwrites what they set rather than
              # being overwritten: the STUN signature rule in particular grants
              # high priority to any flow speaking ICE, and the 2026-08-13
              # captures show the tunnel client running its own STUN. That rule
              # stays exactly as it is for every other device.
              #
              # ct mark rather than a packet mark, and the reason is the same
              # one the STUN rule documents: `ether saddr` only matches on the
              # LAN-ingress (upload) direction, because a download's source MAC
              # is the ISP's. The mark lands on the conntrack entry, so every
              # packet of the conversation inherits it in both directions.
              #
              # Mark 0 rather than the bulk mark: this removes the advantage the
              # tunnel is exploiting without penalising anything genuine on the
              # device. Calls from these devices are best-effort, which is the
              # intent — they are never dropped.
              ${lib.optionalString cfg.lowTrust.enable ''
                ether saddr @lowtrust_macs counter ct mark set 0 comment "Low-trust device: no priority"
                ether saddr @lowtrust_macs_temp counter ct mark set 0 comment "Low-trust device: no priority (temp)"

                # Closes a hole that exists today for every device and is only
                # closed here for pool ones: the bleach rules at the top of this
                # chain strip DSCP arriving from the WAN, but a LAN device's own
                # upload codepoint is untouched, so a device can mark its own
                # packets EF and reach the Voice tin on the uplink regardless of
                # its ct mark.
                ether saddr @lowtrust_macs meta nfproto ipv4 counter ip dscp set cs0 comment "Low-trust device: bleach self-marked DSCP (IPv4)"
                ether saddr @lowtrust_macs meta nfproto ipv6 counter ip6 dscp set cs0 comment "Low-trust device: bleach self-marked DSCP (IPv6)"
                ether saddr @lowtrust_macs_temp meta nfproto ipv4 counter ip dscp set cs0 comment "Low-trust device: bleach self-marked DSCP (IPv4, temp)"
                ether saddr @lowtrust_macs_temp meta nfproto ipv6 counter ip6 dscp set cs0 comment "Low-trust device: bleach self-marked DSCP (IPv6, temp)"
              ''}
```

The `meta nfproto` matches are not redundant despite nft deriving the same dependency from the `ip`/`ip6` expression — the chain's existing comment explains why: without them the implicit dependency is inserted after the counter and each counter tallies both families, doubling every number.

- [ ] **Step 2: Confirm the sets exist in this table**

`qos-mark` is in `inet router-filter`, and Task 1 Step 3 declared `lowtrust_macs`
and `lowtrust_macs_temp` there for exactly this reason. Verify before building,
because nothing downstream will catch it:

```bash
grep -n 'lowtrust_macs' modules/router/default.nix
```

Expected: four hits — two set declarations inside the `router-filter` table, and
the rules added in Step 1. If only the rules appear, Task 1 Step 3 was skipped
and this task will build cleanly and fail at ruleset load with
`set 'lowtrust_macs' does not exist`.

- [ ] **Step 3: Build**

```bash
nix fmt && nix build --no-link '.#nixosConfigurations.bingo.config.system.build.toplevel'
nix build --no-link '.#nixosConfigurations.bongo.config.system.build.toplevel'
```

Expected: both pass. `Error: set 'lowtrust_macs' does not exist` at *runtime* rather than build time is the symptom of the cross-table problem in Step 2 — the build cannot catch it, so read the table names rather than assuming.

- [ ] **Step 4: Commit**

```bash
git add modules/router/default.nix
git commit --no-gpg-sign -m "router: deny voice-tin priority to low-trust devices"
```

---

### Task 5: The `lowtrust` CLI tool

**Files:**
- Create: `modules/router/lowtrust.bash`
- Modify: `modules/router/tools.nix`

**Interfaces:**
- Consumes: set `lowtrust_macs_temp` from Task 1.
- Produces: executable `lowtrust` with subcommands `add <ip|mac>`, `del <ip|mac>`, `list`, `status`; on `router-web`'s PATH.

- [ ] **Step 1: Write the tool**

`modules/router/lowtrust.bash`:

```bash
#!/usr/bin/env bash
# lowtrust — add or remove a device from the low-trust pool at runtime.
#
# Writes only to lowtrust_macs_temp. The permanent set comes from a sops secret
# and is loaded by nft-lowtrust-macs.service; this tool cannot touch it, which
# is what makes "remove" safe — a button press can never silently undo a device
# that was deliberately put in the permanent list.
#
# "Temporary" means until the next rebuild reloads the ruleset, or until `del`.
# Unlike tempblock, which keeps its own table and therefore survives rebuilds,
# this writes to a set declared by networking.nftables.tables, so a rebuild
# genuinely does clear it.
#
# Accepts a device IP as well as a MAC, because the peers page is per-device-IP
# and the pool is keyed on MAC. Resolution is via the neighbour table.
set -euo pipefail

PATH="/run/wrappers/bin:$PATH"

# Both tables. The sets are declared in each because nftables scopes a set to
# its table and offers no way to share one: router-blocklists holds the drop
# chains, router-filter holds qos-mark. Writing only the first leaves a device
# blocked but still eligible for the voice tin, which is the half of the policy
# that is hardest to notice missing.
readonly TABLES=("inet router-blocklists" "inet router-filter")
readonly SET="lowtrust_macs_temp"
readonly PERM_SET="lowtrust_macs"

nft() {
	if [ "$(id -u)" -eq 0 ] || command nft list tables >/dev/null 2>&1; then
		command nft "$@"
	else
		sudo -n /run/current-system/sw/bin/nft "$@"
	fi
}

die() {
	echo "lowtrust: $*" >&2
	exit 1
}

usage() {
	cat <<-'USAGE'
		lowtrust — runtime membership of the low-trust device pool

		  lowtrust add <ip|mac>   put a device in the pool now
		  lowtrust del <ip|mac>   take it out again
		  lowtrust list           show temporary and permanent membership
		  lowtrust status         rule counters for the pool policy

		Temporary membership is cleared by the next rebuild. Permanent members
		live in a sops secret and cannot be changed from here.
	USAGE
	exit "${1:-0}"
}

# A MAC is six colon-separated hex pairs. Anything else is treated as an IP and
# looked up in the neighbour table.
is_mac() {
	printf '%s' "$1" | grep -qiE '^([0-9a-f]{2}:){5}[0-9a-f]{2}$'
}

resolve_mac() {
	local target="$1" mac
	if is_mac "$target"; then
		printf '%s' "$target" | tr 'A-F' 'a-f'
		return 0
	fi

	mac=$(ip neigh show "$target" 2>/dev/null | awk '/lladdr/ {print $5; exit}')
	[ -n "$mac" ] || die "no neighbour entry for $target — the device must have talked to the router recently"
	printf '%s' "$mac" | tr 'A-F' 'a-f'
}

# Refuses a device that is already permanent. Adding it to the temp set as well
# would work, but `del` would then appear to succeed while the device stayed in
# the pool — a button that reports success and changes nothing.
in_permanent() {
	nft list set ${TABLES[0]} $PERM_SET 2>/dev/null | grep -qiF "$1"
}

cmd_add() {
	local mac
	mac=$(resolve_mac "$1")
	if in_permanent "$mac"; then
		die "already a permanent member; remove it from the sops secret instead"
	fi
	for t in "${TABLES[@]}"; do
		# shellcheck disable=SC2086 # $t is two words on purpose: "inet <table>"
		nft add element $t $SET "{ $mac }"
	done
	echo "lowtrust: added $mac"
}

cmd_del() {
	local mac
	mac=$(resolve_mac "$1")
	if in_permanent "$mac"; then
		die "permanent member; remove it from the sops secret instead"
	fi
	for t in "${TABLES[@]}"; do
		# shellcheck disable=SC2086 # $t is two words on purpose: "inet <table>"
		nft delete element $t $SET "{ $mac }"
	done
	echo "lowtrust: removed $mac"
}

cmd_list() {
	echo "temporary:"
	nft list set ${TABLES[0]} $SET
	echo
	echo "permanent:"
	nft list set ${TABLES[0]} $PERM_SET
}

cmd_status() {
	nft list chain ${TABLES[0]} lowtrust_policy
}

sub="${1:-}"
shift || true
case "$sub" in
add) [ $# -ge 1 ] || usage 1; cmd_add "$1" ;;
del) [ $# -ge 1 ] || usage 1; cmd_del "$1" ;;
list) cmd_list ;;
status) cmd_status ;;
-h | --help | "") usage 0 ;;
*) die "unknown subcommand: $sub" ;;
esac
```

- [ ] **Step 2: Package it**

In `modules/router/tools.nix`, add to the `let` block:

```nix
  lowtrust = pkgs.writeShellApplication {
    name = "lowtrust";
    runtimeInputs = with pkgs; [
      coreutils
      gawk
      gnugrep
      iproute2
      nftables
    ];
    text = builtins.readFile ./lowtrust.bash;
  };
```

Add `lowtrust` to `environment.systemPackages` and to `systemd.services.router-web.path`, both gated:

```nix
    environment.systemPackages = [
      clients
      killconn
      tempblock
      tempthrottle
    ] ++ lib.optional cfg.lowTrust.enable lowtrust;

    systemd.services.router-web.path = [
      killconn
      tempblock
      tempthrottle
    ] ++ lib.optional cfg.lowTrust.enable lowtrust;
```

- [ ] **Step 3: Build**

```bash
nix fmt && nix build --no-link '.#nixosConfigurations.bingo.config.system.build.toplevel'
nix build --no-link '.#nixosConfigurations.bongo.config.system.build.toplevel'
```

Expected: both pass. `writeShellApplication` runs shellcheck, so a shell error fails the build here rather than at runtime.

- [ ] **Step 4: Check the sudo grant**

The peers page runs as a `DynamicUser`, so `lowtrust` will take the `sudo -n /run/current-system/sw/bin/nft` path. Check whether that grant exists:

```bash
grep -rn 'nft\|NOPASSWD' hosts/bingo/default.nix | head
```

If `tempblock`'s grant is scoped to specific nft arguments rather than the binary, extend it to cover `add element`/`delete element` on `lowtrust_macs_temp`. If it is a blanket grant on the nft binary, nothing to do.

- [ ] **Step 5: Commit**

```bash
git add modules/router/lowtrust.bash modules/router/tools.nix
git commit --no-gpg-sign -m "router: lowtrust CLI for runtime pool membership"
```

---

### Task 6: Peers page buttons and badge

**Files:**
- Modify: `modules/router/web/peers.go` (`peersPageData` ~line 32, `mux()` ~line 220)
- Modify: `modules/router/web/peers.html` (device actions, ~line 50)
- Modify: `modules/router/web/peers_test.go`

**Interfaces:**
- Consumes: `lowtrust` CLI from Task 5.
- Produces: routes `POST /peers/{device}/lowtrust` and `POST /peers/{device}/lowtrust/remove`; field `LowTrust string` on `peersPageData` with values `""`, `"temp"`, `"permanent"`.

- [ ] **Step 1: Write the failing test for the routes**

`peers_test.go` already has a `testPeersServer(t)` helper and an injectable
`server.runTool`, so these are real assertions rather than route-existence
smoke tests. Add, following the shape of `TestActionThrottlesPeer`:

```go
func TestActionAddsDeviceToLowTrustPool(t *testing.T) {
	server := testPeersServer(t)
	var gotName string
	var gotArgs []string
	server.runTool = func(name string, args ...string) (string, error) {
		gotName, gotArgs = name, args
		return "lowtrust: added aa:bb:cc:dd:ee:01", nil
	}

	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodPost, "/peers/192.168.0.10/lowtrust", nil)
	server.mux().ServeHTTP(rec, req)

	if rec.Code != http.StatusSeeOther {
		t.Fatalf("status = %d, want 303", rec.Code)
	}
	if gotName != "lowtrust" || len(gotArgs) != 2 || gotArgs[0] != "add" || gotArgs[1] != "192.168.0.10" {
		t.Fatalf("ran %s %v, want lowtrust add 192.168.0.10", gotName, gotArgs)
	}
}

func TestActionRemovesDeviceFromLowTrustPool(t *testing.T) {
	server := testPeersServer(t)
	var gotArgs []string
	server.runTool = func(_ string, args ...string) (string, error) {
		gotArgs = args
		return "lowtrust: removed aa:bb:cc:dd:ee:01", nil
	}

	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodPost, "/peers/192.168.0.10/lowtrust/remove", nil)
	server.mux().ServeHTTP(rec, req)

	if len(gotArgs) != 2 || gotArgs[0] != "del" {
		t.Fatalf("ran with %v, want del 192.168.0.10", gotArgs)
	}
}
```

Note both actions pass the **device** address, not a peer: they are `peerless`,
so no `peer=` form body is sent and the handler must not require one.

- [ ] **Step 2: Run them and watch them fail**

```bash
cd modules/router/web && go test ./... -run TestActionAddsDeviceToLowTrust -v
```

Expected: FAIL. The route is unregistered, so `mux` returns 404 and the status
assertion fires before anything else.

- [ ] **Step 3: Register the routes**

In `peers.go`'s `mux()`, after the `drop-all` registration:

```go
	// Device-scoped like drop-all: the pool is a property of the device, not of
	// one conversation, so there is no peer form field and peerless skips the
	// public-address guard that would have nothing to guard.
	mux.HandleFunc("POST /peers/{device}/lowtrust", s.handleAction(peerAction{
		name: "lowtrust", tool: "lowtrust", peerless: true,
		argv: func(_, device netip.Addr) []string {
			return []string{"add", device.String()}
		},
	}))
	mux.HandleFunc("POST /peers/{device}/lowtrust/remove", s.handleAction(peerAction{
		name: "lowtrust-remove", tool: "lowtrust", peerless: true,
		argv: func(_, device netip.Addr) []string {
			return []string{"del", device.String()}
		},
	}))
```

`invalidate` is deliberately left false: the shaping cache keyed by peer address is unaffected by device membership.

- [ ] **Step 4: Run the tests again**

```bash
go test ./... -run 'TestAction(Adds|Removes)DeviceFromLowTrustPool|TestActionAddsDeviceToLowTrustPool' -v
```

Expected: both PASS.

- [ ] **Step 5: Write the failing test for the badge**

```go
func TestLowTrustBadgeHidesRemoveForPermanent(t *testing.T) {
	var buf bytes.Buffer
	tmpl := template.Must(template.ParseFiles("peers.html"))
	data := peersPageData{Device: "192.168.50.10", LowTrust: "permanent"}
	if err := tmpl.Execute(&buf, data); err != nil {
		t.Fatal(err)
	}
	body := buf.String()
	if !strings.Contains(body, "low-trust") {
		t.Error("permanent member should show the low-trust badge")
	}
	if strings.Contains(body, "/lowtrust/remove") {
		t.Error("permanent member must not offer a remove button")
	}
}
```

- [ ] **Step 6: Run it and watch it fail**

```bash
go test ./... -run TestLowTrustBadge -v
```

Expected: FAIL — `LowTrust` is not a field on `peersPageData`.

- [ ] **Step 7: Add the field and populate it**

In `peers.go`, add to `peersPageData`:

```go
	// Low-trust pool membership: "", "temp", or "permanent". Which set a
	// device came from decides whether a remove button is offered, because
	// the tool refuses to remove a permanent member and a button that cannot
	// work should not be shown.
	LowTrust string
```

Populate it in `handlePage` by reading the two sets, following how `shaping.go` reads sets with `nft -j list set`. Add to `shaping.go`:

```go
// lowTrustMembership reports whether a device's MAC is in the low-trust sets.
// Returns "", "temp" or "permanent"; permanent wins, because that is what
// decides whether the page offers a remove button.
func lowTrustMembership(ctx context.Context, mac string) string {
	if mac == "" {
		return ""
	}
	for _, s := range []struct{ set, class string }{
		{"lowtrust_macs", "permanent"},
		{"lowtrust_macs_temp", "temp"},
	} {
		out, err := exec.CommandContext(ctx, "nft", "-j", "list", "set", "inet", "router-blocklists", s.set).Output()
		if err != nil {
			continue
		}
		if strings.Contains(strings.ToLower(string(out)), strings.ToLower(mac)) {
			return s.class
		}
	}
	return ""
}
```

The device's MAC comes from the neighbour table, which `main.go` already reads at line ~195 (`ip -4 neigh show`). Reuse that rather than shelling out again.

- [ ] **Step 8: Add the template block**

In `peers.html`, after the `drop-all` form:

```html
{{if eq .LowTrust "permanent"}}
<p class="note">This device is a <strong>low-trust</strong> pool member (permanent). Change it in the sops secret.</p>
{{else if eq .LowTrust "temp"}}
<form class="device" method="post" action="/peers/{{.Device}}/lowtrust/remove" style="margin: 0 0 1rem">
<button type="submit">remove from low-trust pool</button>
</form>
<p class="note">This device is temporarily in the <strong>low-trust</strong> pool: stricter egress, and no voice-tin priority. Cleared by the next rebuild.</p>
{{else}}
<form class="device" method="post" action="/peers/{{.Device}}/lowtrust" style="margin: 0 0 1rem">
<button type="submit">add to low-trust pool</button>
</form>
<p class="note">Stricter egress for this device: extra blocked ports and subnets, public STUN dropped, and no voice-tin priority. Cleared by the next rebuild.</p>
{{end}}
```

- [ ] **Step 9: Run the whole suite**

```bash
go test ./...
```

Expected: PASS, including the pre-existing tests. If a template test elsewhere fails on the new field, it is constructing `peersPageData` without `LowTrust`; the zero value takes the `else` branch, so the fix is in the assertion, not the template.

- [ ] **Step 10: Build and commit**

```bash
cd /home/humaid/repos/dotfiles && nix fmt
nix build --no-link '.#nixosConfigurations.bingo.config.system.build.toplevel'
nix build --no-link '.#nixosConfigurations.bongo.config.system.build.toplevel'
git add modules/router/web/peers.go modules/router/web/peers.html modules/router/web/peers_test.go modules/router/web/shaping.go
git commit --no-gpg-sign -m "router-web: low-trust pool membership button and badge"
```

---

## Post-implementation verification

Not a task — do this after deploying to bingo, since none of it can be checked from a build.

- [ ] `sudo systemctl status nft-lowtrust-macs` — active, no failure.
- [ ] `sudo nft list set inet router-blocklists lowtrust_macs` — holds the MACs from the secret.
- [ ] Break the secret deliberately (add `zz:zz:...`), `systemctl restart nft-lowtrust-macs`, confirm it **fails** rather than loading an empty set. Restore it.
- [ ] Press "add to low-trust pool" on a test device's peers page; confirm the MAC appears in `lowtrust_macs_temp` and the badge changes.
- [ ] From that device, `nc -vz <any-public-host> 22` — should fail; from a non-pool device it should not.
- [ ] Place a Botim or Comera call from the pool device — it must connect and stay usable.
- [ ] `sudo nft list chain inet router-blocklists lowtrust_policy` — counters non-zero on the rules you exercised.
- [ ] `journalctl -k | grep nft-block-lowtrust` — log samples present.
- [ ] Rebuild, then confirm `lowtrust_macs_temp` is empty and `lowtrust_macs` is not.
