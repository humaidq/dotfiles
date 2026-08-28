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
    ../uwsm.nix
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
        # `uwsm start` rather than bare `sway`, so the compositor lands in
        # wayland-wm@sway.service instead of the login session scope. See
        # ../uwsm.nix for why that matters. greetd runs this through the user's
        # login shell, so the quoting survives and the profile uwsm's
        # environment preloader relies on has already been sourced.
        command = "${pkgs.tuigreet}/bin/tuigreet --time --cmd '${lib.getExe pkgs.uwsm} start -F -- /run/current-system/sw/bin/sway'";
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

        # uwsm owns graphical-session.target now. home-manager's own
        # integration would start a second sway-session.target bound to the
        # same target and run its own dbus-update-activation-environment,
        # racing uwsm's environment export for the same variables.
        systemd.enable = false;

        config = {
          # Mandatory with uwsm, not an optimisation: the compositor unit uses
          # Type=notify, so without this it never signals readiness and systemd
          # kills it on startup timeout. The variable list is what
          # home-manager's systemd.variables was exporting, minus
          # WAYLAND_DISPLAY and DISPLAY (uwsm always does those) and
          # XDG_CURRENT_DESKTOP (uwsm sets it itself). SWAYSOCK is the one that
          # would be missed loudest -- kanshi's profile `exec` blocks shell out
          # to swaymsg, see hosts/anoa/default.nix.
          startup = [
            {
              command = "${lib.getExe pkgs.uwsm} finalize SWAYSOCK XDG_SESSION_TYPE NIXOS_OZONE_WL XCURSOR_THEME XCURSOR_SIZE";
            }
          ];

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
            # Every terminal window gets its own app-foot@*.scope. This is the
            # binding that matters most for ../uwsm.nix's purpose: a runaway
            # inside one terminal is now bounded by that window rather than by
            # the session. Bare `exec` would leave it in the compositor's own
            # unit, which is no better than the flat session scope it replaced.
            #
            # The doubled `exec` is sway's documented idiom -- sway runs the
            # command under `sh -c`, and the inner exec replaces that shell so
            # the scope's main PID is foot itself.
            "${mod}+Shift+Return" = "exec exec ${lib.getExe pkgs.app2unit} -- ${lib.getExe pkgs.foot}";
            "${mod}+Shift+c" = "kill";
            "${mod}+Shift+r" = "reload";
            "${mod}+p" = "exec ${lib.getExe pkgs.fuzzel}";
            "${mod}+o" =
              "exec ${lib.getExe pkgs.rbw} unlock && ${lib.getExe pkgs.rbw} ls | ${lib.getExe pkgs.fuzzel} --dmenu | xargs ${lib.getExe pkgs.rbw} get | wl-copy";
            "${mod}+c" = "exec caffeine-ctl cycle";
            "${mod}+v" = "exec ${clipboardManager}/bin/clipboard-manager";

            # laptop bindings
            "XF86MonBrightnessUp" = "exec ${lib.getExe config.sifr.desktop.brightness.package} up";
            "XF86MonBrightnessDown" = "exec ${lib.getExe config.sifr.desktop.brightness.package} down";
            "XF86AudioRaiseVolume" = "exec pamixer -i 5";
            "XF86AudioLowerVolume" = "exec pamixer -d 5";
            "XF86AudioMute" = "exec pamixer -t";
            "XF86AudioMicMute" = "exec pamixer --default-source -t";
            "XF86Sleep" = "exec systemctl suspend";
            "XF86Display" = "exec exec ${lib.getExe pkgs.app2unit} -- ${lib.getExe pkgs.wdisplays}";

            "Print" = "exec ${screen}/bin/screen";
            "Control+Print" = "exec ${recorder}/bin/recorder";
            "${mod}+Escape" = "exec ${lib.getExe pkgs.swaylock} -f";
            "${mod}+Shift+Escape" = "exec ${lib.getExe pkgs.swaylock} -f && systemctl suspend";
          };
          modifier = mod;
          floating.modifier = mod;
          output."*".bg = "${../wallhaven-13mk9v.jpg} fill #000000";
          output."Dell Inc. DELL P2725H 25FCXZ3".subpixel = "rgb";
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
