{
  config,
  pkgs,
  lib,
  vars,
  ...
}: let
  cfg = config.sifr.graphics;
  mod = "Mod4";
in {
  options.sifr.graphics = {
    sway.enable = lib.mkEnableOption "desktop environment with sway";
  };

  config = lib.mkIf cfg.sway.enable {
    programs.sway = {
      enable = true;
      wrapperFeatures.gtk = true; # so that gtk works properly
      extraPackages = with pkgs; [
        swaylock-effects # lockscreen
        pavucontrol
        swayidle
        xwayland
        (i3pystatus.override {
          extraLibs = [
            python3.pkgs.keyrings-alt
            python3.pkgs.paho-mqtt
          ];
        })
        rofi-wayland
        libnotify
        dunst # notification daemon
        kanshi # auto-configure display outputs
        wdisplays
        wl-clipboard
        blueberry
        sway-contrib.grimshot # screenshots
        wtype

        libnotify
        pamixer
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

    environment.systemPackages = with pkgs; [foot];
    home-manager.users."${vars.user}".wayland.windowManager.sway = {
      enable = true;
      config = {
        input."*" = {
          xkb_layout = "us,ara,fi";
        };
        terminal = "foot";
        keybindings = {
          "${mod}+Shift+Return" = "exec foot";
          "${mod}+Shift+c" = "kill";
          "${mod}+p" = "exec ${pkgs.dmenu}/bin/dmenu_run";
        };
        floating.modifier = mod;
        bars = [
          {
            statusCommand = "${pkgs.i3status}/bin/i3status";
            #colors = {
            #  background = "#130e24";
            #  activeWorkspace = {
            #    background = "#1d2e86";
            #    border = "#130e24";
            #    text = "#eeeeee";
            #  };
            #  focusedWorkspace = {
            #    background = "#1d2e86";
            #    border = "#130e24";
            #    text = "#eeeeee";
            #  };
            #  inactiveWorkspace = {
            #    background = "#130e24";
            #    border = "#130e24";
            #    text = "#eeeeee";
            #  };
            #};
          }
        ];
        #colors = {
        #  background = "#130e24";
        #  focused = {
        #    border = "#1d2e86";
        #    background = "#1d2e86";
        #    text = "#eeeeee";
        #    indicator = "#1d2e86";
        #    childBorder = "#1d2e86";
        #  };
        #  focusedInactive = {
        #    border = "#130e24";
        #    background = "#130e24";
        #    text = "#bbbbbb";
        #    indicator = "#484e50";
        #    childBorder = "#130e24";
        #  };
        #  unfocused = {
        #    border = "#130e24";
        #    background = "#130e24";
        #    text = "#bbbbbb";
        #    indicator = "#484e50";
        #    childBorder = "#130e24";
        #  };
        #};
      };
    };
  };
}
