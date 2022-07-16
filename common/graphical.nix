# This contains settings to provide a graphical system.
{ config, pkgs, lib, ... }:
with lib;
let
  cfg = config.hsys;
  needDisplayServer = cfg.enableGnome || cfg.enableDwm || cfg.enableMate ||
    cfg.enablei3;
in
{
  options.hsys.enableGnome = mkOption {
    description = "Enable Gnome desktop environment";
    type = types.bool;
    default = false;
  };
  options.hsys.enableMate = mkOption {
    description = "Enable MATE desktop environment";
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

        # Audio (1/2)
        pipewire = {
          enable = true;
          alsa.enable = true;
          alsa.support32Bit = true;
          pulse.enable = true;
          wireplumber.enable = true;
        };

        # Track highest uptimes :)
        uptimed.enable = true;

      };

      # home-manager can get angry if dconf is not enabled.
      programs.dconf.enable = true;

      # Audio (2/2)
      sound.enable = true;
      hardware.pulseaudio.enable = false; # replaced with pipewire above

      # Networking
      # This is enabled with Gnome by default, but when other DE/WMs are
      # used, this is not set -- causing no WiFi connectivity.
      networking.networkmanager.enable = true;

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
    (mkIf cfg.enableMate {
      # These are set when mate is enabled.
      services.xserver.desktopManager.mate.enable = true;
      environment.systemPackages = with pkgs; [
        gnome.dconf-editor
        arc-theme
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
      #    #"work-wuhd-3k-single" = {
      #    #  fingerprint = {
      #    #    "eDP-1-1" = "00ffffffffffff0009e56e0800000000011d0104a52213780358f5a658559d260e505400000001010101010101010101010101010101963b803671383c403020360058c21000001aab2f803671383c403020360058c21000001a000000fe00424f452043510a202020202020000000fe004e5631353646484d2d4e36310a00b9";
      #    #    "DP-1.3" =
      #    #      "00ffffffffffff0010ac06424c333535171f0104b55d27783a52f5b04f42ab250f5054a54b00714f81008180a940b300d1c0d100e1c0cd4600a0a0381f4030203a00a1883100001a000000ff00325257535638330a2020202020000000fc0044454c4c20553430323151570a000000fd001856198c49010a2020202020200266020319f14c101f2005140413121103020123090707830100004dd000a0f0703e8030203500a1883100001a565e00a0a0a0295030203500a1883100001a023a801871382d40582c4500a1883100001e011d007251d01e206e285500a1883100001e000000000000000000000000000000000000000000000000000000000000e8701279030001000c4d24500f0014700810788999030128e6120186ff139f002f801f006f083d00020009008b870006ff139f002f801f006f081e00020009000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000003f90";
      #    #  };
      #    #  config = {
      #    #    "eDP-1-1".enable = false;
      #    #    "DP-1.3" = {
      #    #      enable = true;
      #    #      primary = true;
      #    #      position = "0x0";
      #    #      mode = "3840x2160";
      #    #      rate = "59.94";
      #    #    };
      #    #  };
      #    #};
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

