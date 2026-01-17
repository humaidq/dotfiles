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
  mod = config.sifr.graphics.sway.modifier;
  screen = pkgs.callPackage ../screenshot.nix { };
  recorder = pkgs.callPackage ../recorder.nix { };
  clipboardManager = pkgs.callPackage ../clipboard-manager.nix { };
in
{
  imports = [
    ./bar.nix
    ./applications.nix
    ../wayland-services.nix
  ];

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

    services.xserver.displayManager.lightdm.enable = false;
    services.gnome.gnome-online-accounts.enable = true;

    # Thunar functionality
    programs.thunar = {
      enable = true;
      plugins = with pkgs.xfce; [
        thunar-archive-plugin
        thunar-volman
        thunar-vcs-plugin
        thunar-media-tags-plugin
      ];
    };

    services.gvfs.enable = true;
    services.tumbler.enable = true;

    services.colord.enable = true; # needed for printing
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
        libsForQt5.qt5.qtwayland

        networkmanagerapplet
      ];
      extraSessionCommands = "";
    };

    home-manager.users."${vars.user}" = {
      home.sessionVariables = {
        # Cursor size for HiDPI
        XCURSOR_SIZE = "24";
        XCURSOR_THEME = "Adwaita";
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

      #xfconf.settings = {
      #};

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

          terminal = "ghostty";
          # https://github.com/nix-community/home-manager/blob/master/modules/services/window-managers/i3-sway/sway.nix
          keybindings = lib.mkOptionDefault {
            "${mod}+Shift+Return" = "exec ghostty";
            "${mod}+Shift+c" = "kill";
            "${mod}+Shift+r" = "reload";
            "${mod}+p" = "exec ${lib.getExe pkgs.j4-dmenu-desktop} --dmenu='bemenu' --term='ghostty'";
            "${mod}+shift+p" = "exec bemenu-run";
            "${mod}+o" =
              "exec ${lib.getExe pkgs.rbw} unlock && ${lib.getExe pkgs.rbw} ls | bemenu | xargs ${lib.getExe pkgs.rbw} get | wl-copy";
            "Mod4+l" = "exec ${lib.getExe pkgs.swaylock} -f";
            "Mod4+c" = "exec caffeine-toggle";
            "Mod4+v" = "exec ${clipboardManager}/bin/clipboard-manager";

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
            "Control+Print" = "exec ${recorder}/bin/recorder";
          };
          modifier = mod;
          floating.modifier = mod;
          output."*".bg = "${../wallhaven-13mk9v.jpg} fill #000000";
          fonts = {
            names = [ (if gfxCfg.berkeley.enable then "Berkeley Mono" else "Fira Code") ];
            size = 8.0;
          };
          defaultWorkspace = "workspace number 1";
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
