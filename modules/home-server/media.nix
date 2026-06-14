{
  vars,
  config,
  lib,
  ...
}:
let
  cfg = config.sifr.home-server;
in
{
  config = lib.mkIf cfg.enable {
    users.groups.media = { };

    users.users."${vars.user}".extraGroups = [ "media" ];

    services.netatalk = {
      enable = true;
      settings = {
        humaid = {
          path = "/mnt";
        };
      };
    };
    networking.firewall.allowedTCPPorts = [ config.services.netatalk.port ];
  };
}
