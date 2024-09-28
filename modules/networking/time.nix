{ config, lib, ... }:
let
  cfg = config.sifr.ntp;
in
{
  options.sifr.ntp = {
    zone = lib.mkOption {
      type = lib.types.str;
      default = "asia";
      description = "The ntp.org zone to use.";
    };
    useNTS = lib.mkEnableOption "NTS for all connections";
  };

  config = {
    # Use chrony as timeserver. Although chrony is more heavy (includes server
    # implementation), but it implements full NTP protocol.
    services.timesyncd.enable = false;

    # Don't let Nix add timeservers in chrony config, we want to manually add
    # multiple options.
    networking.timeServers = [ ];

    services.chrony = {
      enable = true;
      # We don't use NTS yet as it breaks on systems with no RTC
      extraConfig = ''
        # Cloudflare supports NTS
        pool time.cloudflare.com prefer iburst xleave ${if cfg.useNTS then "nts" else ""}

        ${
          if !cfg.useNTS then
            ''
              pool 0.${cfg.zone}.pool.ntp.org iburst xleave
              pool 1.${cfg.zone}.pool.ntp.org iburst xleave
              pool 2.${cfg.zone}.pool.ntp.org iburst xleave
              pool 3.${cfg.zone}.pool.ntp.org iburst xleave
            ''
          else
            ''
              # https://github.com/jauderho/nts-servers
              server ntppool1.time.nl iburst nts
              server ntpmon.dcs1.biz iburst xleave nts
              server ntp.miuku.net iburst xleave nts
              server ptbtime1.ptb.de iburst xleave nts
              server time.dfm.dk iburst xleave nts
              server time.cifelli.xyz iburst nts

              #authselectmode require
            ''
        }

        # Step if adjustment >1s.
        makestep 1.0 3

        # Set DSCP for networks with QoS
        dscp 46

        minsources 5
      '';
    };
  };
}
