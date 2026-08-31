{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.sifr.router;
  clients = pkgs.writeShellApplication {
    name = "clients";
    runtimeInputs = with pkgs; [
      coreutils
      gawk
      iproute2
    ];
    text =
      lib.optionalString (cfg.dhcp.hostsFile != null) ''
        export HOSTS_FILE=${lib.escapeShellArg cfg.dhcp.hostsFile}
      ''
      + builtins.readFile ./clients.bash;
  };
  killconn = pkgs.writeShellApplication {
    name = "killconn";
    runtimeInputs = with pkgs; [
      coreutils
      gawk
      conntrack-tools
      # For the neighbour lookup that folds a device's IPv4 and IPv6 addresses
      # together, and for arming the reset set. Neither is optional: without
      # iproute2 a dual-stack device loses half its flows, and without nftables
      # a TCP teardown silently degrades to deleting state nobody is told about.
      iproute2
      nftables
    ];
    text = builtins.readFile ./killconn.bash;
  };
  tempblock = pkgs.writeShellApplication {
    name = "tempblock";
    runtimeInputs = [
      killconn
      pkgs.coreutils
      pkgs.gawk
      pkgs.nftables
    ];
    text = builtins.readFile ./tempblock.bash;
  };
  tempthrottle = pkgs.writeShellApplication {
    name = "tempthrottle";
    runtimeInputs = with pkgs; [
      coreutils
      gawk
      gnused
      iproute2
      nftables
    ];
    # Same option the forward_throttle rules are built from, so a pre-spent
    # grace element carries the quota the rule would have created and the two
    # cannot drift apart. Same reasoning as lowtrust's LEASE_FILE below.
    text = ''
      export GRACE_BYTES=${lib.escapeShellArg cfg.throttle.graceBytes}
    ''
    + builtins.readFile ./tempthrottle.bash;
  };
  lowtrust = pkgs.writeShellApplication {
    name = "lowtrust";
    runtimeInputs = with pkgs; [
      coreutils
      gawk
      gnugrep
      iproute2
      nftables
    ];
    # Read when the neighbour table has no entry for an address, which is the
    # normal state for a device that is merely asleep. Same option dnsmasq is
    # configured from, so the two cannot drift apart.
    text = ''
      export LEASE_FILE=${lib.escapeShellArg cfg.dhcp.leasesFile}
    ''
    + builtins.readFile ./lowtrust.bash;
  };
in
{
  config = lib.mkIf cfg.enable {
    environment.systemPackages = [
      clients
      killconn
      tempblock
      tempthrottle
    ]
    ++ lib.optional cfg.lowTrust.enable lowtrust;

    # The reset half of killconn. Declared here rather than created by the
    # script so that it is part of the ruleset a rebuild owns — a table a tool
    # conjures at runtime is one more thing nothing flushes, which is the
    # failure tempblock's header documents at length.
    #
    # PRIORITY -30, ahead of tempblock's -20, so that `tempblock add` — which
    # calls killconn after installing its drop rules — still gets a clean
    # teardown instead of having its own drop swallow the packet the reset
    # needed to match.
    #
    # The sets are keyed on a whole four-tuple and carry a timeout, which is
    # what keeps this from being a block: it can only ever match a conversation
    # that was already open when killconn ran, a redial draws a fresh source
    # port, and an element nobody removes removes itself. `tcp flags & rst == 0`
    # keeps a reset from answering a reset.
    networking.nftables.tables.router-killrst = {
      family = "inet";
      content = ''
        set killrst4 {
          type ipv4_addr . inet_service . ipv4_addr . inet_service
          flags timeout
          timeout 5s
        }

        set killrst6 {
          type ipv6_addr . inet_service . ipv6_addr . inet_service
          flags timeout
          timeout 5s
        }

        # NOT `reset`: that is a keyword in nft's grammar and the ruleset fails
        # to parse with "unexpected reset, expecting string or last". Same trap
        # as `fwd`, which this repo has hit before.
        chain killrst {
          type filter hook forward priority -30; policy accept;
          tcp flags & rst == 0 ip saddr . tcp sport . ip daddr . tcp dport @killrst4 counter reject with tcp reset
          tcp flags & rst == 0 ip6 saddr . tcp sport . ip6 daddr . tcp dport @killrst6 counter reject with tcp reset
        }
      '';
    };

    # router-web's peers page shells out to these to throttle/block a peer.
    # DynamicUser services (see web.nix) get a PATH built solely from their
    # own `path` list, not /run/current-system/sw/bin, so
    # environment.systemPackages above is not enough on its own to put these
    # on router-web's PATH.
    systemd.services.router-web.path = [
      killconn
      tempblock
      tempthrottle
    ]
    ++ lib.optional cfg.lowTrust.enable lowtrust;
  };
}
