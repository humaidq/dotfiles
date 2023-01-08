{ nixosConfig, config, pkgs, lib, ... }:
let
  wallpaper = ./wallhaven-13mk9v.jpg;
in
{
  config = lib.mkMerge [
    (lib.mkIf nixosConfig.hsys.isGraphical {
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

      #  xdg.configFile."vlc/vlcrc".text = ''
      #[qt]
      ## Do not ask for network policy at start
      #qt-privacy-ask=0
      #'';

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
    (lib.mkIf (nixosConfig.hsys.enablei3 && nixosConfig.hsys.isVM) {
      # Use "Command" key as modifier (equi. to Super key).
      xsession.windowManager.i3.config = {
        modifier = lib.mkForce "Mod4";
      };


      # TODO xidlehook
      #       xidlehook --not-when-fullscreen --not-when-audio --timer 180 'slock' \'\' &
      # TODO setxkbmap
      # setxkbmap -option caps:ctrl_modifier -layout us,ar,fi -option grp:win_space_toggle
      # This should be doen in xorg settings.
    })
    (lib.mkIf (nixosConfig.hsys.enablei3 && nixosConfig.hsys.isVM) {

      xsession.windowManager.i3.config.startup = [
        {command = "xidlehook --not-when-fullscreen --not-when-audio --timer 180 'slock' \\'\\'"; }
      ];
    })
    (lib.mkIf nixosConfig.hsys.enablei3 {
      xsession.windowManager.i3 = {
        enable = true;
        config = {
          # Use "Alt" key.
          modifier = "Mod1";
          startup = [
            {command = "feh --bg-fill ${wallpaper}"; always = true; }
            #{command = "picom --vsync --dbus --backend glx"; }
          ];
          bars = [{
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
          }];
          colors = {
            background = "#130e24";
            focused = {
              border = "#1d2e86";
              background = "#1d2e86";
              text = "#eeeeee";
              indicator = "#2e9ef4";
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
          in lib.mkOptionDefault {
            "${modifier}+Return" = null;
            "${modifier}+d" = null;
            "${modifier}+Shift+Return" = "exec alacritty";
            "${modifier}+Shift+c" = "kill";
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

            "${modifier}+Shift+v" = "reload";
          };
        };

      };
    })
  ];
}
