{
  config,
  pkgs,
  lib,
  ...
}:

let
  cfg = config.sifr.router;
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

          +ipv6
          defaultroute

          persist
          maxfail 0
          holdoff 5

          noauth
          noproxyarp

          lcp-echo-interval 10
          lcp-echo-failure 3

          mtu 1492
          mru 1492

          noresolvconf
        '';
      };
    };

    #  Restart pppd if systemd-networkd restarts
    systemd.services."pppd-uplink" = {
      partOf = [ "systemd-networkd.service" ];
    };

    # Enfore redial once a day
    systemd.services."pppd-uplink-redial" = {
      requires = [ "pppd-uplink.service" ];
      serviceConfig = {
        Type = "simple";
        ExecStart = "${pkgs.systemd}/bin/systemctl kill -s HUP --kill-who=main pppd-uplink";
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
