# This contains settings to provide a graphical system.
{ config, pkgs, lib, ... }:
with lib;
let
  cfg = config.hsys;
  needDisplayServer = cfg.enableGnome || cfg.enablei3;
in
{
  options.hsys.enableGnome = mkOption {
    description = "Enable Gnome desktop environment";
    type = types.bool;
    default = false;
  };
  options.hsys.enableDwm = mkOption {
    description = "Enable dwm window manager";
    type = types.bool;
    default = false;
  };
  options.hsys.enablei3 = mkOption {
    description = "Enable the i3 window manager";
    type = types.bool;
    default = false;
  };

  config = mkMerge [
    (mkIf needDisplayServer {
      # Global Xorg/wayland and desktop settings go here
      services = {
        # Display server (X11)
        xserver = {
          enable = true;
          layout = "us,ar";
          xkbOptions = "caps:escape";
          enableCtrlAltBackspace = false; # security?
          screenSection = ''
            Option  "TripleBuffer" "on"
          '';
		  #logFile = "/var/log/Xorg.0.log";
        };

        # Printing
        printing.enable = true;
        printing.drivers = [
          pkgs.epson-escpr
        ];

        # Audio
        pipewire = {
          enable = true;
          alsa.enable = true;
          alsa.support32Bit = true;
          pulse.enable = true;
          #media-session.enable = true;
        };

        # Track highest uptimes :)
        uptimed.enable = true;
      };
      sound.enable = true;
      hardware.pulseaudio.enable = false; # replaced with pipewire above
      # We need to make system look better overall when we have a graphical system
      boot.plymouth = {
        enable = true;
        logo = ./assets/hsys-icon-blue.png;
        font = "${pkgs.inter}/share/fonts/opentype/Inter-Regular.otf";
      };

      # Define printers
      hardware.printers.ensurePrinters = [{
        name = "Home_Printer";
        model = "epson-inkjet-printer-escpr/Epson-L4150_Series-epson-escpr-en.ppd";
        location = "Home Office (Abu Dhabi)";
        deviceUri = "lpd://192.168.0.189:515/PASSTHRU";
        ppdOptions = { PageSize = "A4"; };
      }];
      hardware.printers.ensureDefaultPrinter = "Home_Printer";

      # Mouse
      hardware.logitech.wireless.enable = true;
      hardware.logitech.wireless.enableGraphical = config.hardware.logitech.wireless.enable;

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
          google-fonts
          corefonts
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
          cherry
        ];
      };

      # Default applications for graphical systems
      environment.systemPackages = with pkgs; [
        xdotool
        tor-browser-bundle-bin
        ungoogled-chromium
        gimp
        keepassxc
        thunderbird
        wike
        signal-desktop
        whatsapp-for-linux
        libreoffice
        vlc
        obs-studio
        sxiv
        zathura
        spotify
        ksnip
        xclip
        blanket
        appimage-run

        # Productivity
        emacs
        prusa-slicer
        audacity
        gimp
        inkscape
        audacity
        gimp
        inkscape
        libreoffice
        vlc
        kooha
        obs-studio
        contrast
        helvum
        wireshark
      ];
    })

    (mkIf cfg.enableGnome {
      # These are set when gnome is enabled.
      services.xserver.desktopManager.gnome.enable = true;
      #services.xserver.desktopManager.gnome.extraGSettingsOverrides = ''
      #[org.gnome.login-screen]
      #  logo='${./hsys-white.svg}'
      #'';
      services.xserver.displayManager.gdm = {
        enable = true;
        wayland = true;
        #nvidiaWayland = true;
      };

      environment.gnome.excludePackages = [
        pkgs.gnome.geary
        pkgs.gnome.gnome-music
        pkgs.epiphany
      ];
      environment.systemPackages = with pkgs; [
        gnome.dconf-editor
      ];
    })
    (mkIf cfg.enableDwm {
      services.xserver.windowManager.dwm.enable = true;
      environment.systemPackages = with pkgs; [
        brightnessctl
        dmenu
        st
        slock
        xwallpaper
        picom
        xidlehook
        maim
        (import ../pkgs/hstatus.nix)
      ];

      # Fux set UID issue
      security.wrappers.slock = {
        source = "${pkgs.slock.out}/bin/slock";
        setuid = true;
        owner = "root";
        group = "root";
      };
    })
  ];
}

