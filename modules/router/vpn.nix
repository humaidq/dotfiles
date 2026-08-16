{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.sifr.router;
  inherit (cfg) vpn;

  # Everything the feature remembers lives here: the server key, the desired
  # state and what the reconciler last managed to do. Persisted on an
  # impermanent host (asserted below), because losing it would mean a new server
  # key — every client config invalidated — on the next reboot.
  stateDir = "/var/lib/router-vpn";
  desiredFile = "${stateDir}/desired";

  # The one thing router-web is allowed to touch. It is in this group and
  # nothing else: the private key stays root-only, so the network-facing service
  # cannot read the key material for the tunnel it switches on.
  group = "router-vpn";

  # Name and set the runtime gate lives in, shared between the declaration below
  # and the script that adds and removes the element.
  gateTable = "router-vpn";
  gateSet = "closed_ports";

  routervpn = pkgs.writeShellApplication {
    name = "routervpn";
    runtimeInputs = with pkgs; [
      coreutils
      curl
      gawk
      gnugrep
      gnused
      iproute2
      jq
      nftables
      util-linux # flock, so the timer and the path unit cannot overlap
      wireguard-tools
    ];
    # Every knob the script reads, exported here rather than parsed from a
    # config file: the module is the single authority on the interface name,
    # the port and the zone, and a script that could disagree with the firewall
    # rules generated beside it is the failure this avoids.
    text = ''
      export VPN_STATE_DIR=${lib.escapeShellArg stateDir}
      export VPN_STATE_GROUP=${lib.escapeShellArg group}
      export VPN_IFACE=${lib.escapeShellArg vpn.interface}
      export VPN_PORT=${toString vpn.listenPort}
      export VPN_ADDRESS=${lib.escapeShellArg vpn.address}
      export VPN_PPP_IFACE=${lib.escapeShellArg cfg.ppp}
      export VPN_GATE_TABLE=${lib.escapeShellArg gateTable}
      export VPN_GATE_SET=${lib.escapeShellArg gateSet}
      export VPN_PEERS_FILE=${
        lib.escapeShellArg (if vpn.peersFile == null then "" else toString vpn.peersFile)
      }
      export VPN_DNS_ZONE=${lib.escapeShellArg (if vpn.ddns.zone == null then "" else vpn.ddns.zone)}
      export VPN_DNS_TTL=${toString vpn.ddns.ttl}
      export VPN_DNS_LABEL_LENGTH=${toString vpn.ddns.labelLength}
      export VPN_DNS_KEY_FILE=${
        lib.escapeShellArg (if vpn.ddns.apiKeyFile == null then "" else toString vpn.ddns.apiKeyFile)
      }
    ''
    + builtins.readFile ./vpn.bash;
  };
in
{
  options.sifr.router.vpn = {
    enable = lib.mkEnableOption ''
      the on-demand WireGuard tunnel.

      For travelling: a WireGuard-capable travel router dials home, and the
      whole hotel-room network comes out of the home line. It is off almost all
      of the time, which is the reason none of it is declarative — a port open
      to the internet year-round to be used a fortnight a year is the thing this
      is shaped to avoid.

      Enabling it here only makes the tunnel *available*: the interface is not
      created, the port stays shut and no DNS record exists until someone turns
      it on from the mesh-side web UI (or with `routervpn on`). That runtime
      switch is what persists across reboots, not this option
    '';

    interface = lib.mkOption {
      type = lib.types.str;
      default = "wg0";
      description = ''
        Name of the tunnel interface. Created and destroyed by the reconciler
        rather than by systemd-networkd, so that its lifetime follows the
        runtime switch instead of the boot.
      '';
    };

    listenPort = lib.mkOption {
      type = lib.types.port;
      default = 51820;
      description = ''
        UDP port WireGuard listens on, and the port opened towards the internet
        on the PPP interface while the tunnel is on.

        Reachable from the WAN only while the tunnel is running: the firewall
        allows it unconditionally, and a drop rule in the ${gateTable} table
        closes it again whenever the tunnel is off. See the gate table below for
        why the toggle had to be a drop rather than an accept.
      '';
    };

    address = lib.mkOption {
      type = lib.types.str;
      default = "10.30.0.1/24";
      description = ''
        The router's own address on the tunnel, with the prefix length of the
        tunnel subnet.

        Each client takes an address inside this prefix. A client may also
        announce a network behind itself — a travel router's hotel-room LAN —
        by listing that prefix in its allowed IPs; the reconciler adds a route
        for anything outside this one, which is what makes the far side's whole
        network reachable rather than just the far router.
      '';
    };

    meshInterface = lib.mkOption {
      type = with lib.types; nullOr str;
      default = if (config.sifr.personal.net.sifr0 or false) then "sifr0" else null;
      defaultText = lib.literalExpression ''"sifr0" when this host is on the mesh, otherwise null'';
      description = ''
        Nebula interface tunnel clients may reach the mesh through. Null leaves
        the mesh unreachable from the tunnel, which is what a router that is not
        on it wants anyway.

        Derived rather than configured per host because
        modules/personal/networking/nebula.nix names the device "sifr0"
        unconditionally, so a hand-written value here could only ever be the
        same string or a mistake.

        Traffic is masqueraded onto this router's own mesh address on the way
        out — see the postrouting chain below for why that is not merely
        convenient.
      '';
    };

    peersFile = lib.mkOption {
      type = with lib.types; nullOr path;
      default = null;
      example = "/run/secrets/router/vpn-peers";
      description = ''
        Path to the file listing the clients allowed in, one per line:

        ```
        <public key> <allowed IPs>   # comment
        ```

        Allowed IPs is a comma-separated list with no spaces: the client's own
        tunnel address, plus any network behind it that should be reachable
        from here. A phone is `10.30.0.2/32`; a travel router announcing the
        room it is in is `10.30.0.3/32,192.168.8.0/24`.

        A path rather than a list of peers in Nix, for the reason
        `lowTrust.macFile` is: the entries identify people's devices, this
        repository is public, and anything given to a NixOS option is
        world-readable in the Nix store. Point this at a sops secret's `.path`.

        Read at reconcile time, not at build time, so adding a client is a
        `sops` edit followed by `systemctl start router-vpn` — no rebuild. Null
        means no clients, which leaves a tunnel that comes up and accepts
        nobody.
      '';
    };

    ddns = {
      zone = lib.mkOption {
        type = with lib.types; nullOr str;
        default = null;
        example = "huma.id";
        description = ''
          Vultr-hosted zone the ephemeral name is created in. Null disables the
          DNS half entirely, leaving a tunnel that has to be reached by address.

          Each time the tunnel is switched on it takes a fresh random label in
          this zone — `x7k2.huma.id` — which is created on enable, kept pointed
          at the current PPP address for as long as the tunnel is up, and
          deleted on disable. The label survives reboots; it only changes when
          the tunnel is turned off and on again.
        '';
      };

      apiKeyFile = lib.mkOption {
        type = with lib.types; nullOr path;
        default = null;
        description = ''
          Path to a file containing a Vultr API key with write access to the
          zone. A sops secret's `.path`; read by the reconciler as root and
          never by router-web.
        '';
      };

      ttl = lib.mkOption {
        type = lib.types.ints.positive;
        default = 120;
        description = ''
          TTL of the ephemeral record, in seconds. Short because the record's
          whole job is to track an address that changes: this line redials
          daily, and every minute of TTL is a minute of tunnel that cannot be
          re-established after it does. 120 is Vultr's floor.
        '';
      };

      labelLength = lib.mkOption {
        type = lib.types.ints.positive;
        default = 4;
        description = ''
          Length of the random label, in characters from [a-z0-9].

          Four is 1.7 million names, which is obscurity rather than security and
          is meant as such: the name is something to type into a client config,
          and what actually refuses strangers is WireGuard's own handshake,
          which answers nothing it cannot authenticate. Raise it if the concern
          is a zone-walking scanner finding the endpoint rather than an
          attacker doing anything with it.
        '';
      };
    };
  };

  config = lib.mkIf (cfg.enable && vpn.enable) {
    assertions = [
      {
        assertion = vpn.ddns.zone == null || vpn.ddns.apiKeyFile != null;
        message = ''
          sifr.router.vpn.ddns.zone is set without an apiKeyFile. The zone is
          managed through the Vultr API, so without a key the reconciler can
          neither create the ephemeral record on enable nor delete it on
          disable — and a record left behind pointing at this line is the one
          outcome the ephemeral name exists to avoid.
        '';
      }
      # The private key is generated on first enable and never leaves the
      # router, so an impermanent host that does not persist this directory
      # hands out a new server key on every reboot and silently invalidates
      # every client config. Caught here rather than discovered from a client
      # that will not handshake.
      {
        assertion =
          !(config.sifr.persist.enable or false) || builtins.elem stateDir (config.sifr.persist.dirs or [ ]);
        message = ''
          sifr.router.vpn.enable needs "${stateDir}" in sifr.persist.dirs on a
          host with impermanence. It holds the WireGuard server key, the
          on/off switch and the ephemeral DNS name — none of which can be
          regenerated without invalidating every client config and orphaning a
          record in the zone.
        '';
      }
    ];

    users.groups.${group} = { };

    # 0750 on the directory and 0660 on the switch: router-web is in the group
    # and can flip the switch, and can read the reconciler's report next to it,
    # but private.key stays 0600 root and out of reach.
    #
    # The switch is created rather than assumed so the path unit below has
    # something to watch from the first boot, and it is created "off" so a
    # router that has never been told otherwise comes up with no tunnel.
    systemd.tmpfiles.rules = [
      "d ${stateDir} 0750 root ${group} -"
      "f ${desiredFile} 0660 root ${group} - off"
    ];

    environment.systemPackages = [ routervpn ];

    # THE PORT AND THE GATE.
    #
    # The firewall opens the port whenever this module is enabled, and the gate
    # below closes it again whenever the tunnel is off. That is the opposite of
    # the obvious arrangement — keep it shut, open it on demand — and it is
    # forced by how netfilter composes base chains: `accept` in one chain only
    # means "carry on to the next chain at this hook", so an accept rule added
    # at runtime in a table of our own would still be followed by nixos-fw's
    # policy drop and would do nothing. `drop` is final wherever it appears, so
    # the toggle has to be the drop.
    #
    # What that costs: between a ruleset reload and the next reconcile (a minute
    # at most, see the timer) the port is allowed while the tunnel is off. There
    # is nothing listening on it in that window, so the packets are answered
    # with an ICMP port unreachable exactly as they would be by a router that
    # never had this feature.
    networking.firewall.interfaces.${cfg.ppp}.allowedUDPPorts = [ vpn.listenPort ];

    networking.nftables.tables.${gateTable} = {
      family = "inet";
      content = ''
        # Declared empty and filled in at runtime, so a ruleset reload leaves
        # the port allowed rather than leaving a running tunnel cut off. Of the
        # two ways this can be wrong for a minute, that is the harmless one:
        # an open port with no listener, against a tunnel that dies on every
        # `nixos-rebuild` and takes the remote access being used to run it.
        set ${gateSet} {
          type inet_service
          comment "WireGuard ports currently switched off; the reconciler owns the elements"
        }

        chain input {
          type filter hook input priority filter - 5; policy accept;

          iifname "${cfg.ppp}" udp dport @${gateSet} counter drop comment "Tunnel off: refuse WireGuard from the WAN"
        }

        ${lib.optionalString (vpn.meshInterface != null) ''
          # THE MESH, AND WHY IT IS MASQUERADED.
          #
          # Nebula is not a router: it carries traffic between hosts that hold
          # certificates, and the receiving node checks that a packet's source
          # address is one the sending node's certificate actually covers.
          # Forwarding a packet from 10.90.0.2 into the mesh unchanged would be
          # dropped at the far end as spoofed — this router's certificate says
          # 10.10.0.16, not the tunnel range. Making it work as-is would mean
          # re-issuing the certificate with the tunnel subnet in its `subnets`
          # field AND adding an unsafe_route for that subnet on every mesh host
          # that should be able to answer, since nothing else on the mesh has a
          # route back to it.
          #
          # Rewriting the source to this router's own mesh address avoids all of
          # it: the packet is then indistinguishable from one this router sent
          # itself, which every certificate already permits and every host
          # already routes back.
          #
          # The cost, stated plainly: mesh hosts see the tunnel's traffic as
          # coming from this router. A per-source firewall rule on the far end
          # cannot tell the two apart, so anything this router may reach on the
          # mesh, a tunnel client may reach too.
          chain postrouting {
            type nat hook postrouting priority srcnat + 10; policy accept;

            iifname "${vpn.interface}" oifname "${vpn.meshInterface}" counter masquerade comment "Tunnel -> mesh, as this router"
          }
        ''}
      '';
    };

    # Clients reach the internet through the same masquerade the LAN uses, and
    # the home network beside it. Return traffic needs no rule of its own:
    # nixos-fw's forward chain accepts established and related before it
    # consults these.
    #
    # Nothing here lets the LAN open a connection *to* a client. A tunnel is a
    # way in for the person holding a key, not a second interface for the
    # household to be reachable from.
    networking.nat.internalInterfaces = [ vpn.interface ];
    networking.firewall.extraForwardRules = ''
      iifname "${vpn.interface}" oifname "${cfg.ppp}" accept comment "VPN -> WAN"
      iifname "${vpn.interface}" oifname "${cfg.lan0}" accept comment "VPN -> LAN"
      ${lib.optionalString (
        vpn.meshInterface != null
      ) ''iifname "${vpn.interface}" oifname "${vpn.meshInterface}" accept comment "VPN -> mesh"''}
    '';
    # The resolver, so a client that points at the tunnel address gets the
    # house's own DNS — blocklists, local names and all — rather than falling
    # back to whatever network it is sitting on.
    networking.firewall.interfaces.${vpn.interface} = {
      allowedUDPPorts = [ 53 ];
      allowedTCPPorts = [ 53 ];
    };

    # THE RECONCILER. One script, three triggers, no state of its own beyond
    # the two files in stateDir:
    #
    #   - boot, so the switch survives a reboot, which is most of the point;
    #   - the path unit, so flipping the switch acts now rather than at the next
    #     tick;
    #   - the timer, which is what makes the whole thing self-healing: it
    #     re-points the DNS record after the daily redial, re-closes the gate
    #     after a ruleset reload, and covers any trigger that did not fire.
    #
    # Ordered after and wanted by nftables.service so a rebuild that reloads the
    # ruleset immediately gets the gate put back the way the switch says it
    # should be, rather than waiting for the timer.
    systemd.services.router-vpn = {
      description = "Reconcile the on-demand WireGuard tunnel with its switch";
      after = [
        "network-online.target"
        "nftables.service"
      ];
      # Wanted as well as ordered, or the boot run reaches the zone before
      # there is a route to it and the first pass of the day is one that can
      # only record a failure.
      wants = [ "network-online.target" ];
      wantedBy = [
        "multi-user.target"
        "nftables.service"
      ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${routervpn}/bin/routervpn apply";
        # Where the API key is assembled into a curl config and the peer list
        # into a WireGuard config — both carry secrets, and tmpfs means neither
        # is ever written to the disk this router boots from.
        RuntimeDirectory = "router-vpn";
        RuntimeDirectoryMode = "0700";
      };
    };

    systemd.paths.router-vpn = {
      description = "Watch the WireGuard switch";
      wantedBy = [ "multi-user.target" ];
      pathConfig = {
        # Close-after-write rather than every write, so one flip triggers one
        # reconcile. router-web rewrites this file in place for exactly this
        # reason: a rename would land as a directory event this does not watch.
        PathChanged = desiredFile;
        Unit = "router-vpn.service";
      };
    };

    systemd.timers.router-vpn = {
      description = "Keep the ephemeral tunnel name and the port gate current";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        # Two minutes after boot rather than immediately: the boot run has
        # already reconciled, and this one is only useful once PPP has an
        # address to publish.
        OnBootSec = "2min";
        OnUnitActiveSec = "1min";
        AccuracySec = "10s";
      };
    };

    # router-web renders the switch and flips it. It gets the group and the
    # directory path and nothing else — no capability, no tool on its PATH, no
    # access to the key. Writing one of two words into one file is the whole of
    # its privilege here.
    systemd.services.router-web = {
      environment.ROUTER_VPN_DIR = stateDir;
      serviceConfig.SupplementaryGroups = [ group ];
      # The group alone is not enough. DynamicUser implies ProtectSystem=strict,
      # which mounts the whole hierarchy read-only apart from the unit's own
      # StateDirectory — so without this the switch is readable, the group
      # permission is correct, and every write fails with EROFS.
      #
      # Prefixed with "-" so a missing directory is not a start failure. The
      # status page is what this service is for, and losing it because the
      # tunnel's directory went missing would trade a broken button for a dark
      # router. A write into a directory that is not there fails on the button
      # instead, where it is visible and harmless.
      serviceConfig.ReadWritePaths = [ "-${stateDir}" ];
    };
  };
}
