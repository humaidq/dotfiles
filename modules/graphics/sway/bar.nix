{
  config,
  pkgs,
  lib,
  vars,
  ...
}:
let
  cfg = config.sifr.graphics.sway;
  gfxCfg = config.sifr.graphics;
in
{
  config = lib.mkIf cfg.enable {
    home-manager.users."${vars.user}" = {
      programs.i3status = {
        enable = true;
        modules = {
          ipv6.enable = false;
          "volume master" = {
            enable = true;
            position = 1;
          };
          load.enable = true;
          "disk /".enable = false;
          "ethernet _first_".enable = false;
          memory.enable = false;
          "tztime local".settings.format = "%Y-%m-%d %I:%M:%S %p";
        };
      };

      wayland.windowManager.sway.config.bars = [
        {
          fonts = {
            names = [ (if gfxCfg.berkeley.enable then "Berkeley Mono" else "Fira Code") ];
            size = 8.0;
          };
          position = "top";
          statusCommand = "${pkgs.i3status}/bin/i3status";
          #statusCommand = "${pkgs.python3}/bin/python3 ${bar}/bin/i3status-with-orgclock";
          colors = {
            background = "#130e24";
            activeWorkspace = {
              background = "#1d2e86";
              border = "#130e24";
              text = "#eeeeee";
            };
            focusedWorkspace = {
              background = "#1d2e86";
              border = "#130e24";
              text = "#eeeeee";
            };
            inactiveWorkspace = {
              background = "#130e24";
              border = "#130e24";
              text = "#eeeeee";
            };
          };
        }
      ];
    };
  };
}
