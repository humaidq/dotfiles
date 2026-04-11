{ config, lib, ... }:
{
  options.sifr.personal.dns.enable = lib.mkEnableOption "personal DNS settings";

  imports = [
    ./networking/nebula.nix
  ];

  config = lib.mkIf config.sifr.personal.dns.enable {
    networking = {
      networkmanager = {
        dns = "systemd-resolved";
      };
      nameservers = [
        "10.10.0.16"
      ];
    };

    services.resolved = {
      enable = true;
      domains = [ "~." ];
    };

    assertions = [
      {
        assertion = config.sifr.personal.net.sifr0;
        message = "Personal DNS over Nebula requires sifr.personal.net.sifr0";
      }
    ];
  };
}
