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
  xmodmapFile = pkgs.writeText "xmodmap" ''
    remove Lock = Caps_Lock
    keysym Caps_Lock = Control_L
    add Control = Control_L
  '';
in {
  imports = [
    ./i3.nix
    ./gnome.nix
    ./apps.nix
  ];
  options.sifr.graphics.enable = mkOption {
    description = "Sets up the graphical user environment with X11";
    type = types.bool;
    default = cfg.i3.enable || cfg.gnome.enable;
  };
  options.sifr.graphics.hidpi = mkOption {
    description = "Configures the system for HiDPI screens";
    type = types.bool;
    default = false;
  };
  options.sifr.graphics.enableSound = mkOption {
    description = "Enables sound server and configurations";
    type = types.bool;
    default = cfg.enable;
  };
  config = mkMerge [
    # All HiDPI graphical systems
    (mkIf (cfg.enable && cfg.hidpi) {
      #hardware.video.hidpi.enable = true;
      hardware.opengl.enable = true;
      services.xserver.dpi = 180;
      environment.variables = {
        GDK_SCALE = "2";
        GDK_DPI_SCALE = "0.5";
        _JAVA_OPTIONS = "-Dsun.java2d.uiScale=2";
      };
    })
    (mkIf cfg.enableSound {
      # Enable audio only on non-VMs (I don't use audio on VMs)
      services.pipewire = {
        enable = true;
        alsa.enable = true;
        alsa.support32Bit = true;
        pulse.enable = true;
        wireplumber.enable = true;
      };
      sound.enable = true;
      hardware.pulseaudio.enable = false; # replaced with pipewire above
    })
    (mkIf cfg.enable {
      # Global Xorg/wayland and desktop settings go here
      services = {
        # Display server (X11)
        xserver = {
          enable = true;
          #layout = "us,ar";
          xkbOptions = "grp:win_space_toggle";
          enableCtrlAltBackspace = false; # prevent lockscreen bypass
          screenSection = ''
            Option  "TripleBuffer" "on"
          '';
        };
      };

      # home-manager can get angry if dconf is not enabled.
      programs.dconf.enable = true;

      # We need to make system look better overall when we have a graphical system
      boot.plymouth = {
        enable = true;
        logo = ../../assets/sifr-icon-blue.png;
        font = "${pkgs.inter}/share/fonts/opentype/Inter-Regular.otf";
      };

      services.xserver.displayManager = {
        lightdm = {
          enable = true;
          background = ../../assets/sifr-lightdm.png;
          greeters = {
            gtk.theme.name = "Adwaita-dark";
          };
        };
        #gdm = {
        #  enable = true;
        #};
        # Make the Caps Lock key both Esc and Ctrl (when long pressed)
        sessionCommands = ''
          ${pkgs.xorg.xmodmap}/bin/xmodmap ${xmodmapFile}
          ${pkgs.xcape}/bin/xcape -e 'Control_L=Escape'
        '';
      };

      # Default applications for graphical systems
      environment.systemPackages = with pkgs; [
        xorg.xkill
        xorg.xmodmap
        xcape
        xcolor
        xdotool
        lxrandr
        xclip
        nsxiv
      ];

      home-manager.users."${vars.user}" = {
        # Default themeing for GTK and Qt
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
            "file:///home/${vars.user}/docs"
            "file:///home/${vars.user}/repos"
            "file:///home/${vars.user}/inbox"
            "file:///home/${vars.user}/inbox/web"
          ];
        };

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

        # Notification service
        services.dunst = {
          enable = true;
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
      };
    })
  ];
}
