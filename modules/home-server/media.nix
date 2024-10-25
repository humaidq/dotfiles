{
  vars,
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.sifr.home-server;
in
{
  config = lib.mkIf cfg.enable {
    users.groups.media = { };

    users.users."${vars.user}".extraGroups = [ "media" ];
    users.users.radarr.extraGroups = [ "media" ];
    users.users.jellyfin.extraGroups = [ "media" ];
    users.users.sonarr.extraGroups = [ "media" ];
    users.users.deluge.extraGroups = [ "media" ];

    services.netatalk = {
      enable = true;
      settings = {
        humaid = {
          path = "/mnt";
        };
      };
    };
    networking.firewall.allowedTCPPorts = [ config.services.netatalk.port ];

    sops.secrets.kavita-token = {
      sopsFile = ../../secrets/gadgets.yaml;
    };
    services.kavita = {
      enable = true;
      settings.Port = 5555;
      tokenKeyFile = "${config.sops.secrets.kavita-token.path}";
    };

    services.mealie = {
      enable = true;
      settings = {
        OIDC_AUTH_ENABLED = true;
        BASE_DOMAIN = "https://recipes.alq.ae";
        OIDC_CONFIGURATION_URL = "https://auth.alq.ae/application/o/mealie/.well-known/openid-configuration";
        OIDC_CLIENT_ID = "FqLxxrnxse55b1tZ2WymAtzuDK24Lmi6P2p63y2k";
        OIDC_AUTO_REDIRECT = true;
        OIDC_ADMIN_GROUP = "admin";
      };
    };

    services.audiobookshelf = {
      enable = true;
    };
    services.jellyseerr = {
      enable = true;
    };

    services.deluge = {
      enable = true;
      #authFile = config.sops.secrets."deluge-auth".path;
      #declarative = true;
      web.enable = true;
    };
    services.radarr = {
      enable = true;
    };
    services.prowlarr = {
      enable = true;
    };
    services.sonarr = {
      enable = true;
    };
    services.jellyfin = {
      enable = true;
    };
    environment.systemPackages = [
      pkgs.jellyfin
      pkgs.jellyfin-web
      pkgs.jellyfin-ffmpeg
    ];

    services.invidious = {
      enable = true;
      domain = "yt.alq.ae";
      port = 4747;
      nginx.enable = true;
      sig-helper.enable = true;
      settings = {
        domain = "yt.alq.ae";
        https_only = true;
        dark_mode = "dark";
        default_home = "Subscriptions";
        popular_enabled = false;
        feed_menu = [
          "Subscriptions"
          "Playlists"
        ];
        statistics_enabled = true;
        default_user_preferences = {
          quality = "dash";
          local = true;
          region = "AE";
          captions = [
            "English"
            "English (auto-generated)"
            "Arabic"
          ];
        };
      };
    };

    services.redlib = {
      enable = true;
      port = 3014;
      address = "127.0.0.1";
    };
  };
}
