{
  config,
  inputs,
  pkgs,
  lib,
  vars,
  ...
}:
let
  cfg = config.sifr.desktop.sway;
  gfxCfg = config.sifr.desktop;
  mod = config.sifr.desktop.sway.modifier;
  screen = pkgs.callPackage ../screenshot.nix {
    inherit (pkgs) fuzzel;
    inherit (inputs.blueshot.packages.${pkgs.stdenv.hostPlatform.system}) blueshot;
  };
  recorder = pkgs.callPackage ../recorder.nix { inherit (pkgs) fuzzel; };
  clipboardManager = pkgs.callPackage ../clipboard-manager.nix { inherit (pkgs) fuzzel; };
in
{
  imports = [
    ./bar.nix
    ./applications.nix
    ../wayland-services.nix
  ];

  options.sifr.desktop = {
    sway.enable = lib.mkEnableOption "desktop environment with sway";
    sway.modifier = lib.mkOption {
      type = lib.types.str;
      default = "Mod4";
      description = "The modifier key to use with sway";
    };
  };

  config = lib.mkIf cfg.enable {
    services.greetd = {
      enable = true;
      settings.default_session = {
        command = "${pkgs.tuigreet}/bin/tuigreet --time --cmd sway";
        user = "greeter";
      };
    };

    programs.xwayland.enable = true;

    fonts.packages = with pkgs; [
      cherry
      spleen
    ];

    environment.systemPackages = with pkgs; [
      wev
      bluetui
      hyprpicker
    ];

    # Thunar functionality
    programs.thunar = {
      enable = true;
      plugins = with pkgs; [
        thunar-archive-plugin
        thunar-volman
        thunar-vcs-plugin
        thunar-media-tags-plugin
      ];
    };

    services = {
      udisks2.enable = true;
      xserver.displayManager.lightdm.enable = false;
      gnome.gnome-online-accounts.enable = true;
      gvfs.enable = true;
      tumbler.enable = true;
      colord.enable = true; # needed for printing
    };

    xdg.portal = {
      enable = true;
      wlr.enable = true; # xdg-desktop-portal-wlr backend
      config.sway = {
        default = [ "gtk" ];
        "org.freedesktop.impl.portal.ScreenCast" = [ "wlr" ];
        "org.freedesktop.impl.portal.Screenshot" = [ "wlr" ];
      };
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

        pavucontrol
        kanshi # auto-configure display outputs
        wdisplays
        wl-clipboard
        cliphist # clipboard history
        sway-contrib.grimshot # screenshots
        wf-recorder # screen recording
        wtype
        gtk_engines # GTK2 Clearlooks engine for TraditionalOk
        libsForQt5.qt5.qtwayland
        lxqt.lxqt-openssh-askpass

        networkmanagerapplet
      ];
    };

    home-manager.users."${vars.user}" = {
      home.sessionVariables = {
        # Cursor size for HiDPI
        XCURSOR_SIZE = "20";
        XCURSOR_THEME = "DMZ-White";
        # SDL:
        SDL_VIDEODRIVER = "wayland";
        # QT (needs qt5.qtwayland in systemPackages):
        QT_QPA_PLATFORM = "wayland";
        QT_WAYLAND_DISABLE_WINDOWDECORATION = "1";
        # Fix for some Java AWT applications (e.g. Android Studio),
        # use this if they aren't displayed properly:
        _JAVA_AWT_WM_NONREPARENTING = "1";
        # Others
        MOZ_ENABLE_WAYLAND = "1";
        XDG_SESSION_TYPE = "wayland";
        XDG_CURRENT_DESKTOP = "sway";
        ELECTRON_OZONE_PLATFORM_HINT = "wayland";
        SSH_ASKPASS = lib.getExe pkgs.lxqt.lxqt-openssh-askpass;
        SSH_ASKPASS_REQUIRE = "prefer";
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
            xcursor_theme = "DMZ-White 20";
          };
          floating = {
            criteria = [
              { class = "wlogout"; }
              { class = "file_progress"; }
              { class = "confirm"; }
              { class = "dialog"; }
              { title = "^OpenSSH Authentication .* request$"; }
              { title = "^Picture in picture$"; }
              # Thunar dialogs and pop-ups
              {
                app_id = "thunar";
                title = "^(File Operation Progress|Confirm to replace files|Delete files).*";
              }
              {
                app_id = "thunar";
                window_role = "GtkFileChooserDialog";
              }
              {
                class = "Thunar";
                window_role = "GtkFileChooserDialog";
              }
              {
                class = "Thunar";
                title = "^(File Operation Progress|Confirm to replace files|Delete files).*";
              }
            ];
          };

          # Stop swayidle from dimming/locking while a window is fullscreen
          # (e.g. videos). Covers both wayland-native (app_id) and xwayland
          # (class) clients.
          window.commands = [
            {
              criteria.app_id = ".*";
              command = "inhibit_idle fullscreen";
            }
            {
              criteria.class = ".*";
              command = "inhibit_idle fullscreen";
            }
          ];

          terminal = "foot";
          # https://github.com/nix-community/home-manager/blob/master/modules/services/window-managers/i3-sway/sway.nix
          keybindings = lib.mkOptionDefault {
            "${mod}+Shift+Return" = "exec foot";
            "${mod}+Shift+c" = "kill";
            "${mod}+Shift+r" = "reload";
            "${mod}+p" = "exec ${lib.getExe pkgs.fuzzel}";
            "${mod}+o" =
              "exec ${lib.getExe pkgs.rbw} unlock && ${lib.getExe pkgs.rbw} ls | ${lib.getExe pkgs.fuzzel} --dmenu | xargs ${lib.getExe pkgs.rbw} get | wl-copy";
            "${mod}+c" = "exec caffeine-toggle";
            "${mod}+v" = "exec ${clipboardManager}/bin/clipboard-manager";

            # laptop bindings
            "XF86MonBrightnessUp" = "exec brightnessctl set 5%+";
            "XF86MonBrightnessDown" = "exec brightnessctl set 5%-";
            "XF86AudioRaiseVolume" = "exec pamixer -i 5";
            "XF86AudioLowerVolume" = "exec pamixer -d 5";
            "XF86AudioMute" = "exec pamixer -t";
            "XF86AudioMicMute" = "exec pamixer --default-source -t";
            "XF86Sleep" = "exec systemctl suspend";
            "XF86Display" = "exec ${lib.getExe pkgs.wdisplays}";

            "Print" = "exec ${screen}/bin/screen";
            "Control+Print" = "exec ${recorder}/bin/recorder";
            "${mod}+Escape" = "exec ${lib.getExe pkgs.swaylock} -f";
            "${mod}+Shift+Escape" = "exec ${lib.getExe pkgs.swaylock} -f && systemctl suspend";
          };
          modifier = mod;
          floating.modifier = mod;
          output."*".bg = "${../wallhaven-13mk9v.jpg} fill #000000";
          fonts = {
            names = [ (if gfxCfg.berkeley.enable then "Berkeley Mono" else "Fira Code") ];
            size = 7.0;
          };
          defaultWorkspace = "workspace number 1";
          colors = {
            background = "#130e24";
            focused = {
              border = "#10245f";
              background = "#1d2e86";
              text = "#eeeeee";
              indicator = "#10245f";
              childBorder = "#10245f";
            };
            focusedInactive = {
              border = "#18264f";
              background = "#130e24";
              text = "#bbbbbb";
              indicator = "#484e50";
              childBorder = "#18264f";
            };
            unfocused = {
              border = "#1a1830";
              background = "#130e24";
              text = "#bbbbbb";
              indicator = "#484e50";
              childBorder = "#1a1830";
            };
          };
        };
      };
    };
  };
}
