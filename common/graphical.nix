# This contains settings to provide a graphical system.
{ config, pkgs, lib, ... }:
with lib;
let
  cfg = config.hsys;
  needDisplayServer = cfg.enablei3 /* || cfg.enableDwm... */;
  xmodmapFile = pkgs.writeText "xmodmap" ''
    remove Lock = Caps_Lock
    keysym Caps_Lock = Control_L
    add Control = Control_L
  '';
in
{
  options.hsys.enablei3 = mkOption {
    description = "Enable the i3 window manager";
    type = types.bool;
    default = false;
  };
  options.hsys.isVM = mkOption {
    description = "Configures system for VM use";
    type = types.bool;
    default = false;
  };
  options.hsys.hidpi = mkOption {
    description = "Configures system for HiDPI displays";
    type = types.bool;
    default = false;
  };
  options.hsys.isGraphical = mkOption {
    description = "Configures the system for graphical UI";
    type = types.bool;
    default = cfg.enablei3 /* || cfg.enableDwm */;
  };

  config = mkMerge [
    # All graphical HiDPI systems
    (mkIf (cfg.isGraphical && cfg.hidpi) {
      #hardware.video.hidpi.enable = true;
      hardware.opengl.enable = true;
      services.xserver.dpi = 180;
      environment.variables = {
        GDK_SCALE = "2";
        GDK_DPI_SCALE = "0.5";
        _JAVA_OPTIONS = "-Dsun.java2d.uiScale=2";
      };
    })
    # Graphical non-VM systems
    (mkIf (cfg.isGraphical && !cfg.isVM) {
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

      # On VMs, these applications would reside on the host.
      environment.systemPackages = with pkgs; [
        pavucontrol
        pulseaudio # for pactl
        gimp
        pinta
        inkscape
        libreoffice
        vlc
        rpi-imager
        prusa-slicer
      ];
    })
    # All graphical systems
    (mkIf cfg.isGraphical {
      # Global Xorg/wayland and desktop settings go here
      services = {
        # Display server (X11)
        xserver = {
          enable = true;
          layout = "us,ar";
          xkbOptions = "grp:win_space_toggle";
          enableCtrlAltBackspace = false; #prevent lockscreen bypass
          screenSection = ''
            Option  "TripleBuffer" "on"
          '';
          #logFile = "/var/log/Xorg.0.log";
        };

        # Track highest uptimes :)
        uptimed.enable = true;
      };

      # home-manager can get angry if dconf is not enabled.
      programs.dconf.enable = true;

      # We need to make system look better overall when we have a graphical system
      boot.plymouth = {
        enable = true;
        logo = ./assets/hsys-icon-blue.png;
        font = "${pkgs.inter}/share/fonts/opentype/Inter-Regular.otf";
      };

      services.xserver.displayManager = {
        lightdm = {
          enable = true;
          background = ./assets/hsys-lightdm.png;
          greeters = {
            gtk.theme.name = "Adwaita-dark";
          };
        };
        # Make the Caps Lock key both Esc and Ctrl (when long pressed)
        sessionCommands = ''
          ${pkgs.xorg.xmodmap}/bin/xmodmap ${xmodmapFile}
          ${pkgs.xcape}/bin/xcape -e 'Control_L=Escape'
        '';
      };

      # Fonts
      fonts = {
        enableDefaultFonts = true;
        enableGhostscriptFonts = true;
        fonts = with pkgs; [
          noto-fonts
          noto-fonts-cjk
          noto-fonts-emoji
          source-code-pro
          source-sans-pro
          source-serif-pro
          amiri
          #corefonts
          roboto
          ubuntu_font_family
          fira-code
          fira-code-symbols
          cantarell-fonts
          freefont_ttf
          inconsolata
          liberation_ttf
          lmodern
          ttf_bitstream_vera
          inter
          # Bitmap fonts
          terminus_font
        ];
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
        appimage-run
        nsxiv
        zathura
        firefox
      ];

      programs._1password-gui = {
        enable = true;
        polkitPolicyOwners = [ "humaid" ];
      };
      environment.variables = {
        "SSH_AUTH_SOCK" = "~/.1password/agent.sock";
      };
    })
    # i3 Basic configurations
    (mkIf cfg.enablei3 {
      services.xserver.windowManager.i3.enable = true;
      environment.systemPackages = with pkgs; [
        dmenu
        feh
        picom
        maim
        alacritty
      ];
    })
    # i3 non-VM settings
    (mkIf (cfg.enablei3 && !cfg.isVM) {
      environment.systemPackages = with pkgs; [
        brightnessctl
        i3lock
        xidlehook
		nm-tray
      ];
    })
  ];
}

