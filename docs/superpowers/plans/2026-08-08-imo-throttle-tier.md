# imo Throttle Tier Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move imo from a hard IP block to a second throttle tier — capped at 2mbit at all hours, 70% packet loss during call-peak windows and 3% otherwise.

**Architecture:** The existing tunnel throttle is one nftables mark (`0x2`) steering into one HTB class (`1:20`) with netem underneath. This adds a parallel second tier: a new list file feeds new `imo4`/`imo6` nft sets, whose packets are marked `0x3` and steered into a new HTB class `1:30`. A systemd timer rewrites the netem loss value on a half-hourly tick according to the time of day.

**Tech Stack:** NixOS modules, nftables, iproute2 (`tc`, HTB + netem), systemd timers.

## Global Constraints

- Spec: `docs/superpowers/specs/2026-08-08-imo-throttle-tier-design.md`
- Rate is `2mbit` in both directions at **all** hours; only loss varies.
- Peak windows are local time (`Asia/Dubai` on both routers): `07:00-11:30` and `15:30-21:30`.
- Loss is `70%` inside those windows, `3%` outside.
- The imo mark is `0x3` and its rules go **after** the `0x2` rules in `forward_throttle`.
- No added delay or jitter on the imo class — rate cap and loss only.
- This repo has no unit-test framework. "Test" means `nix flake check`, building a host's `toplevel`, inspecting generated store files, and running the extracted shell helper with fixed inputs.
- Commit with `--no-gpg-sign` (hardware key is unavailable in agent sessions).
- The repo is public: no device names, no per-person activity, no byte totals in any committed file.
- Do **not** commit the pre-existing working-tree changes to `custom-blocklist.txt` and `custom-throttle-list.txt`; they are unrelated in-flight work. Stage explicit paths, never `git add -A`.

---

## File Structure

| File | Responsibility |
|---|---|
| `modules/router/default.nix` | New `sifr.router.imoThrottle` option block (modify, after the existing `throttle` block ending line ~120) |
| `modules/router/custom-imo-list.txt` | New. The imo address list, same format as the other lists |
| `modules/router/ip-blocklist.nix` | New `imoList` generator, `imo4`/`imo6` sets, `0x3` marking rules, apply in `nft-blocklists-local` (modify) |
| `modules/router/qos.nix` | New HTB class `1:30` + netem `30:` + `0x3` filter; the `imo-loss-for` helper, schedule service and timer (modify) |
| `modules/router/custom-ip-blocklist.txt` | imo entries removed (modify, Task 5) |

---

### Task 1: Options and the empty list file

**Files:**
- Modify: `modules/router/default.nix` (immediately after the `throttle` block, which ends at line ~120)
- Create: `modules/router/custom-imo-list.txt`

**Interfaces:**
- Consumes: nothing.
- Produces: `config.sifr.router.imoThrottle.{rate,baseLoss,peakLoss,peakWindows}` — `rate`/`baseLoss`/`peakLoss` are `str`, `peakWindows` is `listOf str` with each element `"HH:MM-HH:MM"`. Tasks 2–4 read these.

- [ ] **Step 1: Add the option block**

In `modules/router/default.nix`, directly after the closing `};` of the existing `throttle = { ... }` block:

```nix
    # A second throttle tier, independent of `throttle` above. imo is rate
    # capped at every hour of the day and made lossy only during the windows
    # the household actually places calls. The reasoning, and the fact that
    # this replaces an outright block that kept losing to re-homing, is in
    # docs/superpowers/specs/2026-08-08-imo-throttle-tier-design.md.
    imoThrottle = {
      rate = lib.mkOption {
        type = lib.types.str;
        default = "2mbit";
        description = "Rate cap applied to imo addresses, each direction, at all hours.";
      };
      baseLoss = lib.mkOption {
        type = lib.types.str;
        default = "3%";
        description = "Packet loss applied to imo addresses outside the peak windows.";
      };
      peakLoss = lib.mkOption {
        type = lib.types.str;
        default = "70%";
        description = "Packet loss applied to imo addresses inside the peak windows.";
      };
      peakWindows = lib.mkOption {
        type = with lib.types; listOf str;
        default = [
          "07:00-11:30"
          "15:30-21:30"
        ];
        description = "Local-time windows, each HH:MM-HH:MM, during which peakLoss applies instead of baseLoss.";
      };
    };
```

- [ ] **Step 2: Create the list file**

Create `modules/router/custom-imo-list.txt` with only this header (no addresses yet — Task 5 migrates them):

```
# imo (com.imo.android.imoim) — throttled, not blocked.
#
# These addresses were blocked outright in custom-ip-blocklist.txt across
# eleven documented runs. Every run had the same shape: a layer was blocked,
# the app failed hard, and the operator re-homed onto fresh infrastructure
# that then had to be found. That is the same failure the tunnel throttle
# list documents for VPN nodes — a dropped endpoint is replaced within a
# minute, a slow one is not, because nothing fails cleanly enough to trigger
# failover.
#
# Matching traffic is rate capped at sifr.router.imoThrottle.rate at all
# hours, and given sifr.router.imoThrottle.peakLoss during the call-peak
# windows, baseLoss otherwise. Format is the same as every other list here:
# one address or CIDR per line, comments free-form.
```

- [ ] **Step 3: Verify the option evaluates**

Run:

```bash
nix eval --raw .#nixosConfigurations.bongo.config.sifr.router.imoThrottle.rate
nix eval --json .#nixosConfigurations.bongo.config.sifr.router.imoThrottle.peakWindows
```

Expected: `2mbit`, then `["07:00-11:30","15:30-21:30"]`.

- [ ] **Step 4: Commit**

```bash
git add modules/router/default.nix modules/router/custom-imo-list.txt
git commit --no-gpg-sign -m "router: add sifr.router.imoThrottle options and an empty imo list"
```

---

### Task 2: nftables sets and the 0x3 mark

**Files:**
- Modify: `modules/router/ip-blocklist.nix` (generator at ~line 184, sets at ~line 238, chain at ~line 288, service script at ~line 424)

**Interfaces:**
- Consumes: `modules/router/custom-imo-list.txt` from Task 1.
- Produces: nft sets `imo4`/`imo6` in table `inet router-blocklists`, and packet mark `0x3` on matching forwarded traffic. Task 3's tc filter matches `handle 0x3`.

- [ ] **Step 1: Add the generator**

In the `let` block of `modules/router/ip-blocklist.nix`, directly after the `throttleList` definition (ends line ~184):

```nix
  # Same generator again, third target. See the note on throttleList above:
  # the file format and validation are identical and only the set names
  # differ, because what happens to a matching packet is decided in the
  # ruleset and in tc rather than here.
  imoList =
    pkgs.runCommand "nft-imo-list.nft"
      {
        nativeBuildInputs = [ pkgs.python3 ];
      }
      ''
        python3 ${localBlocklistGen} ${./custom-imo-list.txt} "$out" \
          router-blocklists imo4 imo6
      '';
```

- [ ] **Step 2: Add the sets**

After the `throttle6` set (ends line ~238), before the `blocked_ports` comment:

```nix
        # Populated from custom-imo-list.txt by nft-blocklists-local. Marked
        # 0x3 rather than 0x2 so tc can steer it into a class of its own: imo
        # is rate capped and lossy on a schedule, not crippled outright the
        # way a tunnel node is.
        set imo4 {
          type ipv4_addr
          flags interval
        }

        set imo6 {
          type ipv6_addr
          flags interval
        }
```

- [ ] **Step 3: Add the marking rules**

In `chain forward_throttle`, after the four existing `0x2` rules (ends line ~294):

```nix
          # After the 0x2 rules deliberately. `meta mark set` overwrites, so an
          # address that somehow appears in both lists resolves to the imo
          # tier — which is the weaker of the two and therefore the safer
          # outcome for a misfiled address.
          ip daddr @imo4 counter meta mark set 0x3 comment "imo upload (IPv4)"
          ip saddr @imo4 counter meta mark set 0x3 comment "imo download (IPv4)"
          ip6 daddr @imo6 counter meta mark set 0x3 comment "imo upload (IPv6)"
          ip6 saddr @imo6 counter meta mark set 0x3 comment "imo download (IPv6)"
```

- [ ] **Step 4: Apply it in the service**

In `systemd.services.nft-blocklists-local`, change the script from:

```nix
        nft -f ${localBlocklist}
        nft -f ${portBlocklist}
        nft -f ${throttleList}
```

to:

```nix
        nft -f ${localBlocklist}
        nft -f ${portBlocklist}
        nft -f ${throttleList}
        nft -f ${imoList}
```

- [ ] **Step 5: Verify the generated ruleset**

Build the host and read the generated nft file that `nft-blocklists-local` applies. The unit's script references it by store path, so pull it back out of the built unit:

```bash
TOP=$(nix build --no-link --print-out-paths .#nixosConfigurations.bongo.config.system.build.toplevel)
UNIT=$(grep -ol 'nft-imo-list.nft' "$TOP"/etc/systemd/system/nft-blocklists-local.service \
       "$TOP"/etc/systemd/system/nft-blocklists-local.service.d/* 2>/dev/null | head -1)
IMO=$(grep -o '/nix/store/[^ "]*nft-imo-list.nft' "$UNIT" | head -1)
echo "generated: $IMO"
cat "$IMO"
```

Expected: the file declares `set imo4` / `set imo6` in table `inet router-blocklists`. With the list still empty from Task 1, the element lists are empty — that is correct at this stage, and Task 5 fills them.

If the `grep -ol` line finds nothing, the script may be an indirect `ExecStart` script; fall back to:

```bash
IMO=$(grep -ro '/nix/store/[^ "]*nft-imo-list.nft' "$TOP"/etc/systemd/system/ | head -1 | cut -d: -f2-)
cat "$IMO"
```

Then confirm the mark rules are in the ruleset:

```bash
nix eval --raw .#nixosConfigurations.bongo.config.networking.nftables.tables.router-blocklists.content \
  | grep -n "imo4\|imo6\|0x3"
```

Expected: the two set declarations and the four `meta mark set 0x3` rules, with the `0x3` rules appearing *after* the `0x2` ones.

- [ ] **Step 6: Run the real gate**

Run: `nix flake check`
Expected: passes.

- [ ] **Step 7: Commit**

```bash
git add modules/router/ip-blocklist.nix
git commit --no-gpg-sign -m "router: mark imo-list addresses 0x3 for a second throttle tier"
```

---

### Task 3: The tc class

**Files:**
- Modify: `modules/router/qos.nix` (let block line 11, `shape()` body lines 63-89)

**Interfaces:**
- Consumes: `imoThrottle.{rate,baseLoss}` from Task 1; mark `0x3` from Task 2.
- Produces: HTB class `1:30` with netem `handle 30:` on both `cfg.ppp` and `cfg.lan0`. Task 4's service rewrites that qdisc's loss.

- [ ] **Step 1: Bring the option into scope**

In `modules/router/qos.nix`, change line 11 from:

```nix
  inherit (cfg) throttle;
```

to:

```nix
  inherit (cfg) throttle imoThrottle;
```

- [ ] **Step 2: Add the class inside `shape()`**

In the `shape()` function, after the existing `tc filter replace ... handle 0x2 fw flowid 1:20` call and before the closing `}`:

```bash
            # imo class. Rate capped at every hour; only the loss varies, and
            # the value written here is just a starting point —
            # imo-throttle-schedule.service corrects it for the current time
            # of day as soon as this unit finishes, and every half hour after.
            #
            # No delay or jitter, unlike the throttled class above. Latency is
            # what makes a long-lived tunnel unusable; for imo the rate cap
            # and the loss are the whole mechanism.
            tc class replace dev "$dev" parent 1: classid 1:30 htb \
              rate ${imoThrottle.rate} ceil ${imoThrottle.rate}
            tc qdisc replace dev "$dev" parent 1:30 handle 30: netem \
              loss ${imoThrottle.baseLoss} \
              limit 1000

            tc filter replace dev "$dev" parent 1: protocol all prio 1 \
              handle 0x3 fw flowid 1:30
```

- [ ] **Step 3: Verify the script text**

Run:

```bash
nix eval --raw .#nixosConfigurations.bongo.config.systemd.services.cake-sqm.script | grep -n "1:30\|handle 30:\|0x3"
```

Expected: shows the class, the netem qdisc at `loss 3%` and `limit 1000`, and the `handle 0x3` filter.

- [ ] **Step 4: Run the gate**

Run: `nix flake check`
Expected: passes.

- [ ] **Step 5: Commit**

```bash
git add modules/router/qos.nix
git commit --no-gpg-sign -m "router: add the 2mbit imo tc class fed by mark 0x3"
```

---

### Task 4: The schedule

**Files:**
- Modify: `modules/router/qos.nix` (let block, and the `systemd.services` / `systemd.timers` attrsets)

**Interfaces:**
- Consumes: `imoThrottle.{baseLoss,peakLoss,peakWindows}` from Task 1; the `1:30` netem qdisc from Task 3.
- Produces: `imo-loss-for` on `$PATH` of the unit (takes an optional `HH:MM`, prints a netem loss value such as `3%` or `70%`), plus `imo-throttle-schedule.service` and `.timer`.

The helper takes the time as an argument specifically so the schedule can be tested without waiting for a real boundary. That is the only piece of this feature with logic worth testing.

- [ ] **Step 1: Write the helper in the let block**

In `modules/router/qos.nix`, add to the `let` block after `inherit (cfg) throttle imoThrottle;`:

```nix
  # Split out of the service so the schedule can be checked at any time
  # without waiting for a boundary: `imo-loss-for 07:00` answers for 07:00.
  # 10# forces base ten, otherwise "08" and "09" are invalid octal and the
  # arithmetic fails at exactly two hours of the day.
  imoLossFor = pkgs.writeShellApplication {
    name = "imo-loss-for";
    runtimeInputs = [ pkgs.coreutils ];
    text = ''
      now=''${1:-$(date +%H:%M)}

      to_min() {
        local hhmm="$1"
        echo $(( 10#''${hhmm%%:*} * 60 + 10#''${hhmm##*:} ))
      }

      n=$(to_min "$now")

      for w in ${lib.escapeShellArgs imoThrottle.peakWindows}; do
        s=$(to_min "''${w%%-*}")
        e=$(to_min "''${w##*-}")
        if [ "$n" -ge "$s" ] && [ "$n" -lt "$e" ]; then
          echo "${imoThrottle.peakLoss}"
          exit 0
        fi
      done

      echo "${imoThrottle.baseLoss}"
    '';
  };
```

- [ ] **Step 2: Test the helper against every boundary**

Build it standalone and check each edge. Windows are half-open — start inclusive, end exclusive — so 11:30 is already back to base loss.

This must run **before** any deploy, so build the toplevel and recover the helper's store path from the generated unit — the unit's `PATH=` line names it directly:

```bash
TOP=$(nix build --no-link --print-out-paths .#nixosConfigurations.bongo.config.system.build.toplevel)
HELPER=$(grep -o '/nix/store/[^:"]*imo-loss-for[^:"]*' \
         "$TOP"/etc/systemd/system/imo-throttle-schedule.service | head -1)
echo "helper: $HELPER"

for t in 02:59 06:59 07:00 08:30 09:00 11:29 11:30 13:00 15:29 15:30 18:45 21:29 21:30 23:59; do
  printf '%s -> %s\n' "$t" "$("$HELPER"/bin/imo-loss-for "$t")"
done
```

If the `PATH=` line lists the wrapper directory rather than the package, use the store path ending in `-imo-loss-for` and append `/bin/imo-loss-for` as above; `nix build --no-link --print-out-paths "$HELPER"` will realise it if it is not already present.

Expected output for the loop:

```
02:59 -> 3%
06:59 -> 3%
07:00 -> 70%
08:30 -> 70%
09:00 -> 70%
11:29 -> 70%
11:30 -> 3%
13:00 -> 3%
15:29 -> 3%
15:30 -> 70%
18:45 -> 70%
21:29 -> 70%
21:30 -> 3%
23:59 -> 3%
```

`08:30` and `09:00` are in the list on purpose: they are the cases that fail if the `10#` base-ten prefix is dropped.

- [ ] **Step 3: Add the service and timer**

In `modules/router/qos.nix`, inside the same `lib.mkIf config.services.pppd.enable` attrset that holds `cake-sqm`, add a sibling unit:

```nix
      imo-throttle-schedule = {
        description = "Apply the time-of-day loss value to the imo tc class";
        # cake-sqm rebuilds the qdiscs from scratch whenever pppd flaps, which
        # resets this class to baseLoss. Running after it means the correct
        # value is restored immediately rather than at the next tick, and the
        # timer below is then only a backstop.
        after = [ "cake-sqm.service" ];
        wantedBy = [ "cake-sqm.service" ];

        path = [
          pkgs.iproute2
          imoLossFor
        ];

        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = false;
        };

        script = ''
          set -euo pipefail

          loss=$(imo-loss-for)

          for dev in ${cfg.ppp} ${cfg.lan0}; do
            # `tc qdisc change` replaces the entire netem parameter set, so
            # limit has to be restated every time rather than loss alone.
            #
            # Tolerate failure: the timer fires regardless of whether cake-sqm
            # has built the class yet, and a missing qdisc before the link is
            # up is expected rather than an error.
            tc qdisc change dev "$dev" parent 1:30 handle 30: netem \
              loss "$loss" limit 1000 || true
          done
        '';
      };
```

Then add the timer. `systemd.timers` is a new top-level attrset in this file, guarded the same way:

```nix
    systemd.timers = lib.mkIf config.services.pppd.enable {
      imo-throttle-schedule = {
        description = "Re-evaluate the imo loss value every half hour";
        wantedBy = [ "timers.target" ];
        timerConfig = {
          # Half-hourly because the windows end at 11:30 and 21:30; an hourly
          # tick would hold peak loss for thirty minutes too long.
          OnCalendar = "*:00,30";
          Persistent = true;
        };
      };
    };
```

- [ ] **Step 4: Run the gate**

Run: `nix flake check`
Expected: passes.

- [ ] **Step 5: Commit**

```bash
git add modules/router/qos.nix
git commit --no-gpg-sign -m "router: flip the imo class loss on a half-hourly schedule"
```

---

### Task 5: Migrate imo out of the IP blocklist

**Files:**
- Modify: `modules/router/custom-ip-blocklist.txt`
- Modify: `modules/router/custom-imo-list.txt`

**Interfaces:**
- Consumes: the empty list from Task 1.
- Produces: a populated `custom-imo-list.txt`; imo entries absent from `custom-ip-blocklist.txt`.

**This task is reviewed block by block. Do not script it.** A keyword pass tags 293 of the 689 addresses as imo, but it is wrong in both directions — several BIGO and TikTok blocks mention imo only comparatively (for example "the same overwall fallback widening that imo showed"), and moving those would silently unblock infrastructure that was deliberately blocked.

- [ ] **Step 1: List the candidate blocks for review**

The file is organised as comment-run followed by address-run. Print each block with its tag so every one can be judged:

```bash
awk '
/^#/ { if (s=="a") { emit(); c=""; n=0; first="" } s="c"; c=c " " $0; next }
NF   { s="a"; n++; if (first=="") first=$0; next }
END  { if (n) emit() }
function emit(  tag) {
  tag = (tolower(c) ~ /imo|downstext|pagebites|imostatic/) ? "IMO?" : "----"
  printf "%s %3d addrs  first=%-18s %.90s\n", tag, n, first, c
}
' modules/router/custom-ip-blocklist.txt
```

- [ ] **Step 2: Judge each tagged block**

For every block tagged `IMO?`, read its full comment in the file and decide:

- **Move** if the comment says the addresses *are* imo infrastructure — AS36131 / PageBites prefixes, the Alibaba LBS /18, the Tencent Cloud SG addresses reached by imo, the `*.imo.im` and `downstext.com` origins.
- **Keep** if imo is mentioned only as a comparison to another app's behaviour. BIGO and TikTok blocks do this repeatedly.

Also scan the `----` blocks for imo addresses whose comment happens not to use the word.

- [ ] **Step 3: Move the confirmed blocks**

Cut each confirmed block — its comment **and** its addresses together — out of `custom-ip-blocklist.txt` and append it to `custom-imo-list.txt` below the header. The comments are the record of why each address is known and must not be orphaned.

- [ ] **Step 4: Verify nothing was lost or duplicated**

```bash
# Every address still accounted for across the two files
before=$(git show HEAD:modules/router/custom-ip-blocklist.txt | awk '!/^#/ && NF' | sort -u | wc -l)
after=$(cat modules/router/custom-ip-blocklist.txt modules/router/custom-imo-list.txt | awk '!/^#/ && NF' | sort -u | wc -l)
echo "before=$before after=$after"

# Nothing in both lists at once
comm -12 \
  <(awk '!/^#/ && NF' modules/router/custom-ip-blocklist.txt | sort -u) \
  <(awk '!/^#/ && NF' modules/router/custom-imo-list.txt | sort -u)
```

Expected: `before` equals `after`, and `comm` prints nothing.

- [ ] **Step 5: Confirm both lists still generate**

Run: `nix flake check`
Expected: passes. The generator validates every address at build time, so a mangled line fails here.

- [ ] **Step 6: Commit**

```bash
git add modules/router/custom-ip-blocklist.txt modules/router/custom-imo-list.txt
git commit --no-gpg-sign -m "router: move imo's estate from the block list to the throttle tier"
```

---

### Task 6: Deploy and verify on both routers

**Files:** none — this is verification on `bongo` and `bingo`.

**Interfaces:**
- Consumes: everything above.
- Produces: confirmation the tier is live.

Both routers reuse the ControlMaster sockets at `/tmp/claude-1000/{bongo,bingo}.sock`; opening a new ssh connection costs a hardware key touch, so ride the existing ones.

- [ ] **Step 1: Rebuild bongo**

```bash
ssh -S /tmp/claude-1000/bongo.sock bongo \
  'sudo nixos-rebuild switch --flake github:humaidq/dotfiles#bongo --refresh'
```

(Or from a local checkout on the router if that is how the host is normally updated.)

- [ ] **Step 2: Confirm the nft sets are populated**

```bash
ssh -S /tmp/claude-1000/bongo.sock bongo \
  'nft list set inet router-blocklists imo4 | head -20'
```

Expected: the migrated addresses, not an empty set.

- [ ] **Step 3: Confirm the class and current loss**

```bash
ssh -S /tmp/claude-1000/bongo.sock bongo \
  'tc qdisc show dev enp2s0 | grep -A1 "netem 30:"; tc class show dev enp2s0 | grep 1:30'
```

Expected: class `1:30` at `rate 2Mbit`, netem `30:` showing `loss 70%` if run inside a peak window or `loss 3%` outside it.

- [ ] **Step 4: Confirm the schedule flips both devices**

```bash
ssh -S /tmp/claude-1000/bongo.sock bongo \
  'imo-loss-for 09:00; imo-loss-for 13:00; systemctl start imo-throttle-schedule; \
   for d in ppp0 enp2s0; do tc qdisc show dev $d | grep "netem 30:"; done'
```

Expected: `70%` then `3%` from the helper, and both devices showing the loss matching the current time.

- [ ] **Step 5: Confirm the counters move**

```bash
ssh -S /tmp/claude-1000/bongo.sock bongo \
  'nft list chain inet router-blocklists forward_throttle | grep imo'
```

Expected: non-zero counters on at least one imo rule once a device uses the app.

- [ ] **Step 6: Repeat for bingo**

Same six steps against `humaid@10.10.0.18` on the `/tmp/claude-1000/bingo.sock` socket. bingo's LAN device and ppp device names come from its own `sifr.router` config.

- [ ] **Step 7: Report**

Report to the user: which addresses moved, the live loss value at the time of checking, and whether counters are moving on both sites.

---

## Rollback

If imo turns out to be too usable at 3%, the change is one option — raise `sifr.router.imoThrottle.baseLoss` and rebuild; no list or ruleset edits are involved.

If the tier misbehaves entirely, `git revert` the Task 5 commit to restore the block, then the Task 2–4 commits. Reverting Task 5 alone is the safe first move: it puts imo back in the block list and leaves the (then empty) tier harmlessly in place.
