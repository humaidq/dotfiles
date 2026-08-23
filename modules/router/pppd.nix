{
  config,
  pkgs,
  lib,
  ...
}:

let
  cfg = config.sifr.router;
  pppdService = "pppd-etisalat.service";
in
{
  config = lib.mkIf cfg.enable {
    services.pppd = {
      enable = true;
      peers.etisalat = {
        autostart = true;
        config = ''
          plugin pppoe.so
          nic-${cfg.wan}

          file ${cfg.pppdConfig}

          ifname ${cfg.ppp}

          ${lib.optionalString config.networking.enableIPv6 "+ipv6"}
          defaultroute

          persist
          maxfail 0
          holdoff 5

          noauth
          noproxyarp

          lcp-echo-interval 10
          lcp-echo-failure 3

          mtu ${toString cfg.pppMtu}
          mru ${toString cfg.pppMtu}

          noresolvconf
        '';
      };
    };

    #  Restart pppd if systemd-networkd restarts
    systemd.services."pppd-etisalat" = {
      partOf = [ "systemd-networkd.service" ];
    };

    # Enfore redial once a day.
    #
    # Deliberate, and not a workaround for anything the ISP requires: the point
    # is to rotate the public IPv4 address and the delegated IPv6 prefix, and
    # to refresh the session rather than let one run for months.
    #
    # It has two consequences worth knowing before removing it. ppp0 is
    # destroyed and recreated, which is why cake-sqm binds to the netdev rather
    # than to this service (see qos.nix), and the delegated prefix changes
    # daily, which is why the router advertises its link-local address as the
    # RDNSS rather than a global one (see default.nix). An occasional
    # "Access number is exceed" on the first attempt is the far end not having
    # torn the old session down yet; `persist` with `holdoff 5` retries into
    # success five seconds later.
    systemd.services."pppd-uplink-redial" = {
      requires = [ pppdService ];
      serviceConfig = {
        Type = "simple";
        ExecStart = "${pkgs.systemd}/bin/systemctl kill -s HUP --kill-who=main ${pppdService}";
      };
    };

    systemd.timers."pppd-uplink-redial" = {
      wantedBy = [ "timers.target" ];

      timerConfig = {
        OnCalendar = "*-*-* 05:00:00";
      };
    };
  };
}
