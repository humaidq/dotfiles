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
    # if gdm not enabled
    services.greetd = lib.mkIf (!config.sifr.graphics.gnome.enable) {
      enable = true;
      settings.default_session = {
        command = "${pkgs.greetd.tuigreet}/bin/tuigreet --time --cmd sway";
        user = "greeter";
      };
    };

    programs.xwayland.enable = true;

    # TODO add switch option for berkeley mono
    fonts.packages = with pkgs; [
      cherry
      spleen
    ];

    environment.systemPackages = with pkgs; [
      rofi
      wev
      bluetui
      hyprpicker
    ];
    services.xserver.displayManager.lightdm.enable = false;
    services.gnome.gnome-online-accounts.enable = true;

    systemd.user.services = {
      ianny = {
        enable = true;
        description = "ianny daemon";
        serviceConfig = {
          Type = "simple";
          ExecStart = "${pkgs.ianny}/bin/ianny";
        };
        partOf = [ "graphical-session.target" ];
        wantedBy = [ "graphical-session.target" ];
      };
    };

    xdg.portal = {
      enable = true;
      wlr.enable = true; # xdg-desktop-portal-wlr backend
      config.common.default = "wlr";
      extraPortals = with pkgs; [
        xdg-desktop-portal-wlr
        xdg-desktop-portal-gtk
      ];
    };

    programs.sway = {
      enable = true;
      wrapperFeatures.gtk = true; # so that gtk works properly
      xwayland.enable = true;
      extraPackages = with pkgs; [
        brightnessctl
        alsa-utils
        pamixer

        swaylock-effects # lockscreen
        pavucontrol
        swayidle

        libnotify
        dunst # notification daemon
        kanshi # auto-configure display outputs
        wdisplays
        wl-clipboard
        sway-contrib.grimshot # screenshots
        wtype
        libsForQt5.qt5.qtwayland

        libnotify
        networkmanagerapplet
      ];
      extraSessionCommands = '''';
    };

    home-manager.users."${vars.user}" =
      let
        hm-config = config.home-manager.users."${vars.user}";
      in
      {
        home.sessionVariables = {
          # SDL:
          SDL_VIDEODRIVER = "wayland";
          # QT (needs qt5.qtwayland in systemPackages):
          QT_QPA_PLATFORM = "wayland-egl";
          QT_WAYLAND_DISABLE_WINDOWDECORATION = "1";
          # Fix for some Java AWT applications (e.g. Android Studio),
          # use this if they aren't displayed properly:
          _JAVA_AWT_WM_NONREPARENTING = "1";
          # Others
          MOZ_ENABLE_WAYLAND = "1";
          XDG_SESSION_TYPE = "wayland";
          XDG_CURRENT_DESKTOP = "sway";
          ELECTRON_OZONE_PLATFORM_HINT = "wayland";
        };
        # home manager programs
        programs = {
          zathura = {
            enable = true;
            options = {
              "selection-clipboard" = "clipboard";
            };
            mappings = {
              "i" = "recolor";
              "r" = "reload";
              "R" = "rotate";
              "p" = "print";
              "u" = "scroll half-up";
              "d" = "scroll half-down";
              "D" = "toggle_page_mode";
              "g" = "goto top";
            };
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
                font = "Berkeley Mono:size=8";
              };
            };
          };
          rofi = {
            enable = true;
            font = "Berkeley Mono 14";
            package = pkgs.rofi-wayland;
            terminal = lib.getExe pkgs.ghostty;
            theme =
              let
                inherit (hm-config.lib.formats.rasi) mkLiteral;
              in
              {
                "*" = {
                  background-color = mkLiteral "#130e24";
                  foreground-color = mkLiteral "#ffffff";
                  text-color = mkLiteral "#ffffff";
                  border-color = mkLiteral "#1d2e86";
                  width = 512;
                };
                "#inputbar" = {
                  children = map mkLiteral [
                    "prompt"
                    "entry"
                  ];
                };
                "#textbox-prompt-colon" = {
                  expand = false;
                  str = ":";
                  margin = mkLiteral "0px 0.3em 0em 0em";
                  text-color = mkLiteral "@foreground-color";
                };
                "element" = {
                  background-color = mkLiteral "transparent";
                  text-color = mkLiteral "@foreground-color";
                };
                "element selected" = {
                  background-color = mkLiteral "#1d2e86";
                  text-color = mkLiteral "#ffffff";
                  border = mkLiteral "2px";
                  border-color = mkLiteral "#2b3ea6";
                  border-radius = 6;
                };
                "element-text" = {
                  highlight = mkLiteral "underline #9fb3ff";
                };
                "element selected element-text" = {
                  highlight = mkLiteral "none";
                };
                "element alternate" = {
                  background-color = mkLiteral "#171233";
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
              pinentry = pkgs.pinentry-gnome3;
            };
          };
        };

        # home manager services
        services = {
          gnome-keyring.enable = true;
          lxqt-policykit-agent.enable = true;
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
                font = "Berkeley Mono 8";
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
            floating = {
              criteria = [
                { class = "wlogout"; }
                { class = "file_progress"; }
                { class = "confirm"; }
                { class = "dialog"; }
              ];
            };

            terminal = "ghostty";
            # https://github.com/nix-community/home-manager/blob/master/modules/services/window-managers/i3-sway/sway.nix
            keybindings = lib.mkOptionDefault {
              "${mod}+Shift+Return" = "exec ghostty";
              "${mod}+Shift+c" = "kill";
              "${mod}+Shift+r" = "reload";
              "${mod}+p" =
                "exec rofi -modi drun -show-icons -show drun -drun-display-format \"{name} ({categories})\"";
              "${mod}+shift+p" = "exec rofi -show run -show-icons";
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
              names = [ "Berkeley Mono" ];
              size = 8.0;
            };
            defaultWorkspace = "workspace number 1";
            bars = [
              {
                fonts = {
                  names = [ "Berkeley Mono" ];
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
