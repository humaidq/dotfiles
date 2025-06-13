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
    services.bazarr.enable = true;
    services.jellyfin = {
      enable = true;
    };
    environment.systemPackages = [
      pkgs.jellyfin
      pkgs.jellyfin-web
      pkgs.jellyfin-ffmpeg
    ];
  };
}
