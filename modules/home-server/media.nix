{ config, lib, ... }:
let
  cfg = config.sifr.home-server;
  inherit (lib) mkIf;
in
{
  config = {
    services.lldap = mkIf cfg.enable {
      enable = true;
      environmentFile = "${config.sops.secrets.lldap-env.path}";
      settings = {
        ldap_base_dn = "dc=home,dc=alq";
        ldap_user_email = "admin@home.alq";
        http_url = "http://lldap.alq";
      };
    };

    sops.secrets.kavita-token = mkIf cfg.enable { sopsFile = ../../secrets/gadgets.yaml; };
    services.kavita = mkIf cfg.enable {
      enable = true;
      tokenKeyFile = config.sops.secrets.kavita-token.path;
    };

    services.mealie = mkIf cfg.enable { enable = true; };

    services.audiobookshelf = mkIf cfg.enable { enable = true; };
    services.jellyseerr = mkIf cfg.enable { enable = true; };

    services.deluge = mkIf cfg.enable {
      enable = true;
      #authFile = config.sops.secrets."deluge-auth".path;
      #declarative = true;
      web.enable = true;
    };
    services.radarr = mkIf cfg.enable { enable = true; };
    services.prowlarr = mkIf cfg.enable { enable = true; };
  };
}
