{
  config,
  lib,
  ...
}:
with lib; let
  cfg = config.sifr.homelab;
in {
  options.sifr.homelab = {
    lldap.enable = mkOption {
      description = "Enables lldap configuration";
      type = types.bool;
      default = false;
    };
    kavita.enable = mkOption {
      description = "Enables Kavita configuration";
      type = types.bool;
      default = false;
    };
    mealie.enable = mkOption {
      description = "Enables Mealie configuration";
      type = types.bool;
      default = false;
    };
    audiobookshelf.enable = mkOption {
      description = "Enables Audiobookshelf configuration";
      type = types.bool;
      default = false;
    };
    jellyseerr.enable = mkOption {
      description = "Enables Jellyseerr configuration";
      type = types.bool;
      default = false;
    };
  };
  config = {
    services.lldap = mkIf cfg.lldap.enable {
      enable = true;
      environmentFile = "${config.sops.secrets.lldap-env.path}";
      settings = {
        ldap_base_dn = "dc=home,dc=alq";
        ldap_user_email = "admin@home.alq";
        http_url = "http://lldap.alq";
      };
    };

    sops.secrets.kavita-token = {};
    services.kavita = mkIf cfg.kavita.enable {
      enable = true;
      tokenKeyFile = config.sops.secrets.kavita-token.path;
    };

    services.mealie = mkIf cfg.mealie.enable {
      enable = true;
    };

    services.audiobookshelf = mkIf cfg.audiobookshelf.enable {
      enable = true;
    };
    services.jellyseerr = mkIf cfg.jellyseerr.enable {
      enable = true;
    };
  };
}
