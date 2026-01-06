{ config, lib, ... }:
let
  cfg = config.sifr.security;
in
{
  options.sifr.security.encryptDNS = lib.mkEnableOption "encrypted DNS over Nebula";

  config = lib.mkIf cfg.encryptDNS {
    networking = {
      networkmanager = {
        dns = "systemd-resolved";
        connectionConfig = {
          "ipv4.ignore-auto-dns" = true;
          "ipv6.ignore-auto-dns" = true;
        };
      };
      nameservers = [
        "10.10.0.12"
      ];
    };
    services.resolved = {
      enable = true;
      #dnssec = "allow-downgrade";
      domains = [ "~." ];
    };
    assertions = [
      {
        assertion = config.sifr.net.sifr0;
        message = "Encrypted DNS `sifr.security.encryptedDNS` requires Nebula (sifr0)";
      }
    ];
  };
}
