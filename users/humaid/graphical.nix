{
  nixosConfig,
  config,
  pkgs,
  lib,
  ...
}: let
  wallpaper = ./wallhaven-13mk9v.jpg;
in {
  config = lib.mkMerge [
    (lib.mkIf nixosConfig.sifr.isGraphical {
      qt = {
        enable = true;
        platformTheme = "gtk";
        style.package = pkgs.adwaita-qt;
        style.name = "adwaita-dark";
      };

      gtk = {
        enable = true;
        theme.name = "Adwaita-dark";
        gtk3.extraConfig = {
          gtk-application-prefer-dark-theme = true;
          gtk-cursor-theme-name = "Adwaita";
        };
        gtk3.bookmarks = [
          "file:///home/humaid/docs"
          "file:///home/humaid/repos"
          "file:///home/humaid/inbox"
          "file:///home/humaid/inbox/web"
        ];
      };
      home.file.".Xmodmap".text = ''
        remove Lock = Caps_Lock
        keysym Caps_Lock = Control_L
        add Control = Control_L
      '';

      #  xdg.configFile."vlc/vlcrc".text = ''
      #[qt]
      ## Do not ask for network policy at start
      #qt-privacy-ask=0
      #'';

      programs.alacritty = {
        enable = true;
        settings = {
          font = {
            normal.family = "spleen";
            size = 18;
          };

          # Without this, $TERM in tmux is set as xterm-256color which breaks
          # vim colouring
          env.TERM = "alacritty";
        };
      };

      xsession.enable = true;
      xsession.profileExtra = "export PATH=$PATH:$HOME/.bin";
      services.dunst = {
        enable = true;
        #iconTheme.package = pkgs.gnome.adwaita-icon-theme;
        settings = {
          global = {
            frame_color = "#1d2e86";
          };
          urgency_normal = {
            background = "#130e24";
            foreground = "#ffffff";
            timeout = 8;
          };
        };
      };
    })
    (lib.mkIf (nixosConfig.sifr.enablei3 && nixosConfig.sifr.isVM) {
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
    })
    (lib.mkIf (nixosConfig.sifr.enablei3 && !nixosConfig.sifr.isVM) {
      #xsession.windowManager.i3.config.startup = [
      #  {command = "xidlehook --not-when-fullscreen --not-when-audio --timer 180 'i3lock' \\'\\'"; }
      #];
      services.screen-locker = {
        enable = true;
        inactiveInterval = 3; # minutes
        lockCmd = "i3lock";
      };
    })
    (lib.mkIf (nixosConfig.sifr.enablei3 && nixosConfig.sifr.installer) {
      xsession.windowManager.i3.config.startup = [
        {command = "alacritty -e 'sifr-install'";}
      ];
    })
    (lib.mkIf nixosConfig.sifr.enablei3 {
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
            modifier = config.xsession.windowManager.i3.config.modifier;
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
    })
  ];
}
