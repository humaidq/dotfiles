{
  config,
  lib,
  pkgs,
  ...
}:

# Cooldown — take one device off the internet for a fixed period, without
# touching its Wi-Fi association.
#
# The instrument this network was missing. Everything else here acts on a PEER:
# tempblock drops an address, tempthrottle shapes one, the low-trust pool
# narrows what a device may reach. None of them answers "this device is done for
# the next twenty minutes", and the ways of doing that by hand are all worse
# than the problem — kicking a device off the AP makes the phone roam, blame the
# Wi-Fi, and fall back to cellular, and a permanent block has to be remembered
# and undone.
#
# So: a forward-chain drop keyed on the device, with an nftables element timeout
# as the clock. Nothing has to remember to lift it — the element removes itself,
# and if this router reboots mid-cooldown the punishment ends rather than
# outliving everyone's memory of it.
#
# WHAT KEEPS WORKING, and why each one is deliberate:
#
#   * DHCP, DNS, NTP and everything else the router itself serves. Those are
#     addressed TO the router, so they go through the input hook and this chain
#     never sees them. A device in cooldown keeps its lease, keeps resolving,
#     and keeps thinking the network is fine.
#   * Anything on the device's own LAN segment, for the same structural reason:
#     traffic between two addresses on one subnet is not forwarded at all. A
#     printer, a Chromecast and the home server stay reachable.
#   * The captive-portal probes, via cooldown_allow4/6 below. This is the only
#     part that had to be built rather than inherited, and the only part with a
#     cost — see sifr.router.cooldown.allowDomains.
#
# Everything else — every route through ppp0, and every route into the mesh —
# is dropped in both directions.
let
  cfg = config.sifr.router;

  cooldown = pkgs.writeShellApplication {
    name = "cooldown";
    runtimeInputs = with pkgs; [
      coreutils
      dnsutils
      gawk
      gnugrep
      iproute2
      jq
      nftables
      # Starting a cooldown tears down the flows the device already has open,
      # or an in-progress stream keeps arriving until conntrack times it out
      # and the button looks like it did nothing. Same package tools.nix
      # installs — see killconn-package.nix for why it is shared rather than
      # rebuilt here.
      (pkgs.callPackage ./killconn-package.nix { })
    ];
    # Read when the neighbour table has no entry for an address, which is the
    # normal state for a device that is merely asleep — and a device is put in
    # cooldown precisely when someone has decided it has been busy enough. Same
    # option dnsmasq is configured from, so the two cannot drift apart. Same
    # reasoning as lowtrust's LEASE_FILE in tools.nix.
    text = ''
      export LEASE_FILE=${lib.escapeShellArg cfg.dhcp.leasesFile}
      export LAN_INTERFACE=${lib.escapeShellArg cfg.lan0}
      export COOLDOWN_ALLOW_DOMAINS=${lib.escapeShellArg (lib.concatStringsSep " " cfg.cooldown.allowDomains)}
      export COOLDOWN_MAX_SECONDS=${toString cfg.cooldown.maxSeconds}
    ''
    + builtins.readFile ./cooldown.bash;
  };
in
{
  options.sifr.router.cooldown = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Offer per-device cooldowns: a timed internet cut-off that leaves the
        device associated, leased, resolving and able to answer its own
        captive-portal probe.

        On by default because it costs one table with five small sets and a
        chain of eleven rules, all of which match nothing until a cooldown is
        actually started. Off means no table, no chain, no tool, and no button
        on the peers page.
      '';
    };

    maxSeconds = lib.mkOption {
      type = lib.types.ints.positive;
      default = 86400;
      description = ''
        Longest cooldown that may be requested, in seconds.

        A ceiling rather than a policy: a cooldown is meant to be a short,
        self-clearing consequence, and a typo in the duration box ("5h" for
        "5m") should not turn into a day nobody notices. Anything longer than
        this belongs in the blocklists, where it is written down.
      '';
    };

    allowDomains = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        # Android: the plain-HTTP 204 probe, then the HTTPS one it validates
        # on. Without the second, Android reports "limited connectivity" and
        # may prefer cellular over a Wi-Fi it has decided is broken — which is
        # the outcome this whole feature exists to avoid.
        "connectivitycheck.gstatic.com"
        "www.google.com"
        # Apple: captive.apple.com is the probe host, www.apple.com serves the
        # success page iOS fetches over TLS.
        "captive.apple.com"
        "www.apple.com"
        # Windows, current and legacy.
        "www.msftconnecttest.com"
        "www.msftncsi.com"
        "dns.msftncsi.com"
        # Firefox's own, which is what a laptop browser nags about.
        "detectportal.firefox.com"
      ];
      description = ''
        Names whose addresses a device in cooldown may still reach. Resolved
        through this router's own resolver and loaded into cooldown_allow4/6,
        refreshed while any cooldown is running.

        THE KNOWN COST, stated plainly because it is not obvious: these names
        live on shared frontends. Allowing the addresses behind
        connectivitycheck.gstatic.com admits any Google service that answers on
        the same anycast address to a client willing to send a different SNI,
        and listing www.google.com admits google.com search outright, for the
        length of the cooldown, to a client that does nothing clever at all.

        That is the price of the phone not declaring the Wi-Fi broken. Drop the
        two HTTPS validation hosts (www.google.com, www.apple.com) from this
        list to close the obvious half of it: the HTTP 204 probes still pass,
        so the device stays on the network and keeps its lease, and the cost
        moves to a "limited connectivity" notice.

        An empty list disables the carve-out entirely — nothing is allowed out,
        and the device will report no internet, which is honest and is
        occasionally what is wanted.
      '';
    };
  };

  config = lib.mkIf (cfg.enable && cfg.cooldown.enable) {
    # Declared here rather than created by the tool, for the reason
    # router-killrst gives in tools.nix: a table conjured at runtime is one more
    # thing nothing ever flushes, which is the failure tempblock.bash documents
    # at length.
    #
    # The cost of that choice, and it is a real one: a `nixos-rebuild switch`
    # that actually reloads nftables.service recreates this table with empty
    # sets, so any cooldown running at that moment ENDS THERE. That is a silent
    # early release. It is accepted because the alternative — a table that
    # survives every rebuild — is how tempblock ended up enforcing 99 blocks
    # nobody remembered setting, and because a cooldown is a minutes-long
    # consequence whose worst failure mode should be ending too early rather
    # than too late. The page always renders live set contents, so it never
    # claims a cooldown that is no longer there.
    networking.nftables.tables.router-cooldown = {
      family = "inet";
      content = ''
        # The device, by MAC. This is the primary key and the only one that
        # covers a dual-stack device completely: its IPv4 address comes from a
        # lease, but its IPv6 addresses are formed by the device itself, there
        # may be several, and it may form another one an hour into the
        # cooldown. `ether saddr` sees them all, because they all leave the
        # same NIC.
        #
        # Only ever matched on the LAN-ingress direction — a download's source
        # MAC is the ISP's — which is why the address sets below exist as well.
        set cooldown_macs {
          type ether_addr
          flags timeout
        }

        # The device, by address. Two jobs: the return direction, where no MAC
        # of the device is visible, and a device the neighbour table has no
        # entry for, where the MAC is not known at all.
        set cooldown4 {
          type ipv4_addr
          flags timeout
        }

        set cooldown6 {
          type ipv6_addr
          flags timeout
        }

        # The captive-portal carve-out, filled by `cooldown refresh` from the
        # names in sifr.router.cooldown.allowDomains.
        #
        # `flags timeout` with a default of 15 minutes, and no `flags interval`:
        # these are single addresses out of DNS answers, not ranges. The
        # timeout is a backstop rather than the mechanism — a refresh flushes
        # and refills — so that a table left populated by a cooldown that ended
        # hours ago does not keep a stale carve-out open indefinitely.
        set cooldown_allow4 {
          type ipv4_addr
          flags timeout
          timeout 15m
          size 512
        }

        set cooldown_allow6 {
          type ipv6_addr
          flags timeout
          timeout 15m
          size 512
        }

        # Priority -25: behind killrst at -30, so `cooldown add` still gets a
        # clean conntrack teardown instead of having its own drop swallow the
        # packet the reset needed to match, and ahead of tempblock at -20 and
        # the blocklists at -10, because a device in cooldown has nothing to
        # gain from being evaluated against thirty thousand more elements.
        #
        # policy accept, like every other filter chain here: this chain drops
        # what it recognises and has no opinion about anything else.
        chain cooldown {
          type filter hook forward priority -25; policy accept;

          # The carve-out, and note that every rule names BOTH ends. Scoping it
          # to devices in cooldown is what keeps it from being a statement
          # about the whole LAN: an unscoped `ip daddr @cooldown_allow4 accept`
          # would be harmless today, but it would also be the natural place for
          # someone to later hang a rate limit that the entire household's
          # Google traffic would then consume on the cooled device's behalf.
          #
          # `accept` ends evaluation of THIS chain only; the blocklist chains
          # at -10 still get their say, so a carve-out can never re-open an
          # address this router blocks for everyone.
          ether saddr @cooldown_macs ip daddr @cooldown_allow4 counter accept comment "Cooldown: captive-portal probe out (IPv4)"
          ether saddr @cooldown_macs ip6 daddr @cooldown_allow6 counter accept comment "Cooldown: captive-portal probe out (IPv6)"
          ip saddr @cooldown4 ip daddr @cooldown_allow4 counter accept comment "Cooldown: captive-portal probe out, no MAC (IPv4)"
          ip6 saddr @cooldown6 ip6 daddr @cooldown_allow6 counter accept comment "Cooldown: captive-portal probe out, no MAC (IPv6)"
          ip daddr @cooldown4 ip saddr @cooldown_allow4 counter accept comment "Cooldown: captive-portal probe back (IPv4)"
          ip6 daddr @cooldown6 ip6 saddr @cooldown_allow6 counter accept comment "Cooldown: captive-portal probe back (IPv6)"

          # The cooldown itself. The MAC rule is the one that does the work;
          # the address rules cut the return direction, so an already-open UDP
          # stream from a peer that keeps sending — a call, a push connection —
          # stops rather than dribbling in one-way for the rest of the
          # cooldown.
          ether saddr @cooldown_macs counter drop comment "Cooldown: device out"
          ip saddr @cooldown4 counter drop comment "Cooldown: device out (IPv4, no MAC)"
          ip daddr @cooldown4 counter drop comment "Cooldown: device in (IPv4)"
          ip6 saddr @cooldown6 counter drop comment "Cooldown: device out (IPv6, no MAC)"
          ip6 daddr @cooldown6 counter drop comment "Cooldown: device in (IPv6)"
        }
      '';
    };

    environment.systemPackages = [ cooldown ];

    # router-web's peers page shells out to this. A DynamicUser service builds
    # its PATH from this list alone — see the same note in tools.nix, whose
    # definition this merges with.
    systemd.services.router-web.path = [ cooldown ];

    # Keeps the carve-out current while a cooldown is running, and does nothing
    # at all when none is.
    #
    # It has to be refreshed rather than resolved once: the probe names answer
    # from anycast frontends whose addresses rotate, and a device that
    # re-resolves mid-cooldown (blocky's cache expires, typically in five
    # minutes) will probe an address the set may not hold. `cooldown add`
    # refreshes before it starts a cooldown, so the first probe is always
    # covered; this is what covers the tenth.
    #
    # --if-active is what keeps it free: with nothing in cooldown it exits
    # before asking the resolver anything, so an idle router does not put a
    # dozen queries a minute into a query log that is read by hand.
    systemd.services.nft-cooldown-allow = {
      description = "Refresh the cooldown captive-portal carve-out";
      after = [
        "nftables.service"
        "network-online.target"
        "blocky.service"
      ];
      wants = [
        "nftables.service"
        "blocky.service"
      ];
      serviceConfig = {
        Type = "oneshot";
        # The store path, not a bare name with `path = [ cooldown ]` beside it.
        # systemd resolves a relative ExecStart against its OWN built-in search
        # path, never against the unit's, so the bare form failed at every
        # elapse with status 203/EXEC and "Unable to locate executable". No
        # `path` is needed either way: writeShellApplication puts this tool's
        # own runtime inputs — nft, dig, jq — on its PATH from inside.
        ExecStart = "${cooldown}/bin/cooldown refresh --if-active";
      };
    };

    systemd.timers.nft-cooldown-allow = {
      description = "Refresh the cooldown captive-portal carve-out";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "5m";
        # Comfortably inside the 15-minute element timeout above, so a running
        # cooldown never sees the carve-out age out from under it, and inside a
        # typical DNS TTL, so the set tracks what the device is being told.
        OnUnitActiveSec = "3m";
      };
    };
  };
}
