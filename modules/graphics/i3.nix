{
  config,
  pkgs,
  home-manager,
  unstable,
  lib,
  vars,
  ...
}:
with lib; let
  cfg = config.sifr.graphics;
  wallpaper = ./wallhaven-13mk9v.jpg;
in {
  options.sifr.graphics.i3.enable = mkOption {
    description = "Enables i3wm";
    type = types.bool;
    default = false;
  };

  config = mkMerge [
    (mkIf cfg.i3.enable {
      services.xserver.windowManager.i3.enable = true;
      environment.systemPackages = with pkgs; [
        dmenu
        feh
        picom
        maim
        alacritty
      ];
      home-manager.users."${vars.user}" = {
        programs.i3status = {
          enable = true;
          modules = {
            ipv6.enable = false;
            "volume master" = {
              enable = true;
              position = 1;
            };
            load.enable = false;
            "disk /".enable = false;
            "ethernet _first_".enable = false;
            memory.enable = false;
            "tztime local".settings.format = "%Y-%m-%d %I:%M:%S %p";
          };
        };
        xsession.windowManager.i3 = {
          enable = true;
          config = {
            # Use "Alt" key.
            modifier = "Mod1";
            startup = [
              {
                command = "feh --bg-fill ${wallpaper}";
                always = true;
              }
              {command = "picom --vsync --dbus";}
            ];
            defaultWorkspace = "workspace number 1";
            bars = [
              {
                statusCommand = "${pkgs.i3status}/bin/i3status";
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
            colors = {
              background = "#130e24";
              focused = {
                border = "#1d2e86";
                background = "#1d2e86";
                text = "#eeeeee";
                indicator = "#1d2e86";
                childBorder = "#1d2e86";
              };
              focusedInactive = {
                border = "#130e24";
                background = "#130e24";
                text = "#bbbbbb";
                indicator = "#484e50";
                childBorder = "#130e24";
              };
              unfocused = {
                border = "#130e24";
                background = "#130e24";
                text = "#bbbbbb";
                indicator = "#484e50";
                childBorder = "#130e24";
              };
            };
            keybindings = let
              modifier = config.home-manager.users."${vars.user}".xsession.windowManager.i3.config.modifier;
            in
              lib.mkOptionDefault {
                "${modifier}+Return" = null;
                "${modifier}+d" = null;
                "${modifier}+Shift+Return" = "exec alacritty";
                "${modifier}+Shift+c" = "kill";
                "${modifier}+s" = "exec i3lock";
                "${modifier}+p" = "exec ${pkgs.dmenu}/bin/dmenu_run";

                # We shift the bindings to match vim
                "${modifier}+h" = "focus left";
                "${modifier}+j" = "focus down";
                "${modifier}+k" = "focus up";
                "${modifier}+l" = "focus right";
                "${modifier}+Shift+h" = "move left";
                "${modifier}+Shift+j" = "move down";
                "${modifier}+Shift+k" = "move up";
                "${modifier}+Shift+l" = "move right";

                # reassign due to vim bindings
                "${modifier}+g" = "split h";

                # laptop bindings
                "XF86MonBrightnessUp" = "exec brightnessctl set 5%+";
                "XF86MonBrightnessDown" = "exec brightnessctl set 5%-";
                "XF86AudioRaiseVolume" = "exec amixer set Master 5%+";
                "XF86AudioLowerVolume" = "exec amixer set Master 5%-";
                "XF86AudioMute" = "exec amixer set Master toggle";
                "XF86AudioMicMute" = "exec amixer set Capture toggle";
                "XF86Display" = "exec lxrandr";
                "Print" = "exec screen-sel";
                "XF86Sleep" = "exec systemctl suspend";

                "${modifier}+Shift+v" = "reload";
              };
          };
        };
      };
    })
    # i3 VM-specific configuration
    (mkIf (cfg.i3.enable && config.sifr.hardware.vm) {
      home-manager.users."${vars.user}" = {
        # Use "Command" key as modifier (equi. to Super key).
        xsession.windowManager.i3.config = {
          modifier = lib.mkForce "Mod4";
        };
        programs.i3status = {
          enable = true;
          modules = {
            "wireless _first_".enable = false;
            "battery all".enable = false;
          };
        };
      };
    })
    # i3 non-VM packages
    (mkIf (cfg.i3.enable && !config.sifr.hardware.vm) {
      environment.systemPackages = with pkgs; [
        brightnessctl
        i3lock
        xidlehook
        nm-tray
      ];
      home-manager.users."${vars.user}" = {
        #xsession.windowManager.i3.config.startup = [
        #  {command = "xidlehook --not-when-fullscreen --not-when-audio --timer 180 'i3lock' \\'\\'"; }
        #];
        services.screen-locker = {
          enable = true;
          inactiveInterval = 3; # minutes
          lockCmd = "i3lock";
        };
      };
    })
  ];
}
