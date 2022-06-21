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
          #xkbOptions = "caps:escape";
          enableCtrlAltBackspace = false; # security?
          screenSection = ''
            Option  "TripleBuffer" "on"
          '';
          #logFile = "/var/log/Xorg.0.log";
        };

        # Printing
        printing = {
          enable = true;
          browsing = mkForce false;
          drivers = [
            pkgs.epson-escpr # Home Printer
          ];
        };

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

      services.xserver.displayManager.lightdm = {
        enable = true;
        background = ./assets/hsys-lightdm.png;
        #greeter.package = pkgs.pantheon.elementary-greeter;
        greeters = {
          gtk.theme.name = "Adwaita-dark";
        };
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
        xorg.xkill
        pavucontrol
        xcolor
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
        ungoogled-chromium
        rpi-imager
        unstable.minecraft

        # Productivity
        emacs
        prusa-slicer
        audacity
        gimp
        pinta
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
        deluge
      ];
    })

    (mkIf cfg.enableGnome {
      # These are set when gnome is enabled.
      services.xserver.desktopManager.gnome.enable = true;
      #services.xserver.desktopManager.gnome.extraGSettingsOverrides = ''
      #[org.gnome.login-screen]
      #  logo='${./hsys-white.svg}'
      #'';

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
      # When dwm is enabled, always make it the default session.
      services.xserver.displayManager.defaultSession = "none+dwm";
      environment.systemPackages = with pkgs; [
        brightnessctl
        dmenu
        st
        slock
        xwallpaper
        picom
        xidlehook
        maim
        rofi
        rofimoji
        (import ../pkgs/hstatus.nix)
      ];

      # NixOS 22.05 feature
      #services.autorandr = {
      #  enable = true;
      #  profiles = {
      #    "tv" = {
      #      fingerprint = {
      #        eDP1 = "00ffffffffffff0030aeba4000000000001c0104a5221378e238d5975e598e271c5054000000010101010101010101010101010101012e3680a070381f403020350058c210000019582b80a070381f403020350058c2100000190000000f00d10930d10930190a0030e40706000000fe004c503135365746432d535044310072";
      #        HDMI2 = "00ffffffffffff001e6d010001010101011a010380a05a780aee91a3544c99260f5054a108003140454061407140818001010101010108e80030f2705a80b0588a0040846300001e023a801871382d40582c450040846300001e000000fd003a3e1e883c000a202020202020000000fc004c472054560a20202020202020019f02033cf1545d101f0413051403021220212215015e5f626364293d06c01507500957076e030c001000b83c20008001020304e50e60616566e3060501011d8018711c1620582c250040846300009e662150b051001b304070360040846300001e000000000000000000000000000000000000000000000000000000000000007b";
      #      };
      #      config = {
      #        eDP1.enable = false;
      #        HDMI2 = {
      #          enable = true;
      #          primary = true;
      #          position = "0x0";
      #          mode = "4096x2160";
      #          rate = "30";
      #        };
      #      };
      #    };

      #  };
      #};

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

