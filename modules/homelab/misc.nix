{
  config,
  lib,
  ...
}: let
  cfg = config.sifr.homelab;
  inherit (lib) mkOption types mkIf;
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
    nas-media.enable = mkOption {
      description = "Enables nas media mount configuration";
      type = types.bool;
      default = false;
    };
    deluge.enable = mkOption {
      description = "Enables deluge web configuration";
      type = types.bool;
      default = false;
    };
    prowlarr.enable = mkOption {
      description = "Enables prowlarr configuration";
      type = types.bool;
      default = false;
    };
    radarr.enable = mkOption {
      description = "Enables radarr configuration";
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

    sops.secrets.kavita-token = {
      sopsFile = ../../secrets/gadgets.yaml;
    };
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

    services.deluge = mkIf cfg.deluge.enable {
      enable = true;
      #authFile = config.sops.secrets."deluge-auth".path;
      #declarative = true;
      web.enable = true;
    };
    services.radarr = mkIf cfg.radarr.enable {
      enable = true;
    };
    services.prowlarr = mkIf cfg.prowlarr.enable {
      enable = true;
    };

    sops.secrets."nas/media" = {
      sopsFile = ../../secrets/gadgets.yaml;
    };
    fileSystems."/mnt/nas-media" = mkIf cfg.nas-media.enable {
      device = "//nas.alq.ae/video";
      fsType = "cifs";
      options = [
        "credentials=${config.sops.secrets."nas/media".path}"
        "dir_mode=0777,file_mode=0777,iocharset=utf8,auto"
      ];
    };
  };
}
