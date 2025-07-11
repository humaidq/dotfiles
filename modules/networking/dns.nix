{ config, lib, ... }:
let
  cfg = config.sifr.security;
in
{
  options.sifr.security.encryptDNS = lib.mkEnableOption "encrypted DNS over TLS";

  config = lib.mkIf cfg.encryptDNS {
    networking = {
      networkmanager.dns = "systemd-resolved";
      nameservers = [
        "10.10.0.12"
      ];
    };
    services.resolved = {
      enable = true;
      #dnssec = "allow-downgrade";
      domains = [ "~." ];
    };
  };
}
