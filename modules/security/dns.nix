{
  config,
  lib,
  ...
}: let
  cfg = config.sifr.security;
in {
  options.sifr.security.encryptDNS = lib.mkEnableOption "encrypted DNS over TLS";

  config = lib.mkIf cfg.encryptDNS {
    networking = {
      networkmanager.dns = "systemd-resolved";
      nameservers = [
        "1.1.1.1#one.one.one.one"
        "1.0.0.1#one.one.one.one"
        "8.8.8.8#dns.google"
        "8.8.4.4#dns.google"
      ];
    };
    services.resolved = {
      enable = true;
      dnssec = "allow-downgrade";
      domains = ["~."];
      dnsovertls = "true";
    };
  };
}
