{
  config,
  lib,
  ...
}: let
  cfg = config.sifr.homelab;
  inherit (lib) mkIf mkEnableOption;
in {
  options.sifr.homelab = {
    lldap.enable = mkEnableOption "lldap configuration";
    kavita.enable = mkEnableOption "Kavita configuration";
    mealie.enable = mkEnableOption "Mealie configuration";
    audiobookshelf.enable = mkEnableOption "Audiobookshelf configuration";
    jellyseerr.enable = mkEnableOption "Jellyseerr configuration";
    nas-media.enable = mkEnableOption "nas media mount configuration";
    deluge.enable = mkEnableOption "deluge web configuration";
    prowlarr.enable = mkEnableOption "prowlarr configuration";
    radarr.enable = mkEnableOption "radarr configuration";
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
