{
  config,
  pkgs,
  lib,
  vars,
  ...
}:
let
  cfg = config.sifr.desktop.sway;
  gfxCfg = config.sifr.desktop;
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
            size = 7.0;
          };
          position = "top";
          statusCommand = "${pkgs.python3}/bin/python3 ${bar}/bin/i3status-with-orgclock";
          colors = {
            background = "#130e24";
            statusline = "#eeeeee";
            separator = "#484e50";
            activeWorkspace = {
              border = "#10245f";
              background = "#163672";
              text = "#eeeeee";
            };
            focusedWorkspace = {
              border = "#10245f";
              background = "#1d2e86";
              text = "#ffffff";
            };
            inactiveWorkspace = {
              border = "#0f1733";
              background = "#1a1830";
              text = "#bbbbbb";
            };
            urgentWorkspace = {
              border = "#900000";
              background = "#900000";
              text = "#ffffff";
            };
            bindingMode = {
              border = "#10245f";
              background = "#1d2e86";
              text = "#ffffff";
            };
          };
        }
      ];
    };
  };
}
