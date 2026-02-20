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
  bar = pkgs.callPackage ../bar.nix { };
in
{
  config = lib.mkIf cfg.enable {
    home-manager.users."${vars.user}" = {
      programs.i3status = {
        enable = true;
        general = {
          colors = true;
          output_format = "i3bar";
        };
        modules = {
          ipv6.enable = false;
          "volume master" = {
            enable = true;
            position = 1;
          };
          load.enable = true;
          "disk /".enable = false;
          "ethernet _first_".enable = false;
          "wireless _first_".settings = {
            format_up = "W: (%quality at %essid)";
            format_down = "W: down";
          };
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
          statusCommand = "${pkgs.python3}/bin/python3 ${bar}/bin/i3status-with-orgclock";
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
