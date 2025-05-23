{
  config,
  pkgs,
  lib,
  vars,
  ...
}:
let
  cfg = config.sifr.graphics.sway;
  mod = config.sifr.graphics.sway.modifier;
  screen = pkgs.callPackage ./screenshot.nix { };
in
{
  options.sifr.graphics = {
    sway.enable = lib.mkEnableOption "desktop environment with sway";
    sway.modifier = lib.mkOption {
      type = lib.types.str;
      default = "Mod1";
      description = "The modifier key to use with sway";
    };
  };

  config = lib.mkIf cfg.enable {
    fonts.packages = with pkgs; [
      cherry
      spleen
    ];
    environment.systemPackages = with pkgs; [
      rofi
      xwayland
      gnome-online-accounts-gtk
      gnome-calendar
      gnome-contacts
      geary
    ];
    services.xserver.displayManager.lightdm.enable = false;
    services.gnome.gnome-online-accounts.enable = true;
    programs.sway = {
      enable = true;
      wrapperFeatures.gtk = true; # so that gtk works properly
      extraPackages = with pkgs; [
        brightnessctl
        alsa-utils
        pamixer

        swaylock-effects # lockscreen
        pavucontrol
        swayidle
        xwayland

        libnotify
        dunst # notification daemon
        kanshi # auto-configure display outputs
        wdisplays
        wl-clipboard
        #blueberry
        sway-contrib.grimshot # screenshots
        wtype

        libnotify
        networkmanagerapplet
      ];
      extraSessionCommands = ''
        # SDL:
        export SDL_VIDEODRIVER=wayland
        # QT (needs qt5.qtwayland in systemPackages):
        export QT_QPA_PLATFORM=wayland-egl
        export QT_WAYLAND_DISABLE_WINDOWDECORATION="1"
        # Fix for some Java AWT applications (e.g. Android Studio),
        # use this if they aren't displayed properly:
        export _JAVA_AWT_WM_NONREPARENTING=1
        # Others
        export MOZ_ENABLE_WAYLAND=1
        export XDG_SESSION_TYPE=wayland
        export XDG_CURRENT_DESKTOP=sway
      '';
    };

    home-manager.users."${vars.user}" = {

      # home manager programs
      programs = {
        zathura = {
          enable = true;
        };
        i3status = {
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
        foot = {
          enable = true;
          settings = {
            main = {
              term = "xterm-256color";
              dpi-aware = "yes";
              font = "spleen:size=12";
            };
          };
        };
        swaylock = {
          enable = true;
          settings = {
            color = "130e24";
            line-color = "ffffff";
            show-failed-attempts = true;
          };
        };
        rbw = {
          enable = true;
          settings = {
            email = "me@huma.id";
            base_url = "https://vault.alq.ae";
            pinentry = pkgs.pinentry-tty;
          };
        };
      };

      # home manager services
      services = {
        swayidle = {
          enable = true;
          events = [
            {
              event = "before-sleep";
              command = "${lib.getExe pkgs.swaylock} -f";
            }
            {
              event = "lock";
              command = "${lib.getExe pkgs.swaylock} -f";
            }
            {
              event = "unlock";
              command = "${pkgs.procps}/bin/pkill -USR1 swaylock";
            }
          ];
          timeouts = [
            {
              timeout = 250;
              command = ''${pkgs.libnotify}/bin/notify-send -t 30000 -- "Screen will lock soon..."'';
            }
            {
              timeout = 300;
              command = "${pkgs.swaylock}/bin/swaylock -f";
            }
            {
              timeout = 600;
              command = "${pkgs.systemd}/bin/systemctl suspend";
            }
          ];
        };
        dunst = {
          enable = true;
          settings = {
            global = {
              origin = "top-right";
              frame_color = "#130e24";
              font = "cherry 11";
            };
            urgency_normal = {
              background = "#1d2e86";
              foreground = "#fff";
              timeout = 10;
            };
          };
        };
      };
      wayland.windowManager.sway = {
        enable = true;
        config = {
          input = {
            "type:keyboard" = {
              xkb_layout = "us,ara,fi";
              xkb_options = "caps:ctrl_modifier,grp:win_space_toggle";
            };
            "type:touchpad" = {
              tap = "disabled";
              natural_scroll = "enabled";
              dwt = "enabled"; # disable while typing
              middle_emulation = "enabled";
            };
          };
          seat."*" = {
            xcursor_theme = "Adwaita 24";
          };

          terminal = "foot";
          # https://github.com/nix-community/home-manager/blob/master/modules/services/window-managers/i3-sway/sway.nix
          keybindings = lib.mkOptionDefault {
            "${mod}+Shift+Return" = "exec foot";
            "${mod}+Shift+c" = "kill";
            "${mod}+Shift+r" = "reload";
            "${mod}+p" = "exec ${pkgs.dmenu}/bin/dmenu_run";
            "${mod}+o" = "exec ${lib.getExe pkgs.rofi-rbw}";
            "${mod}+Shift+l" = "exec ${lib.getExe pkgs.swaylock} -f";

            # laptop bindings
            "XF86MonBrightnessUp" = "exec brightnessctl set 5%+";
            "XF86MonBrightnessDown" = "exec brightnessctl set 5%-";
            "XF86AudioRaiseVolume" = "exec amixer set Master 5%+";
            "XF86AudioLowerVolume" = "exec amixer set Master 5%-";
            "XF86AudioMute" = "exec amixer set Master toggle";
            "XF86AudioMicMute" = "exec amixer set Capture toggle";
            "XF86Sleep" = "exec systemctl suspend";
            "XF86Display" = "exec ${lib.getExe pkgs.wdisplays}";

            "Print" = "exec ${screen}/bin/screen";
          };
          modifier = mod;
          floating.modifier = mod;
          output."*".bg = "${./wallhaven-13mk9v.jpg} fill #000000";
          fonts = {
            names = [ "cherry" ];
            size = 10.0;
          };
          defaultWorkspace = "workspace number 1";
          bars = [
            {
              fonts = {
                names = [ "cherry" ];
                size = 10.0;
              };
              position = "top";
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
        };
      };
    };
  };
}
