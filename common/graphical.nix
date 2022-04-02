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
      boot.plymouth.enable = true;

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
          google-fonts
          corefonts
          roboto
          ubuntu_font_family
          fira-code
          cantarell-fonts
          freefont_ttf
          inconsolata
          liberation_ttf
          lmodern
          terminus_font
          ttf_bitstream_vera
        ];
      };

      # Firefox with custom policies

      # Default applications for graphical systems
      environment.systemPackages = with pkgs; [
        tor-browser-bundle-bin
        gimp
        keepassxc
        thunderbird
        wike
        signal-desktop
        libreoffice
        vlc
        obs-studio
        sxiv
        zathura
        spotify
        ksnip
        blanket

        # Productivity
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
      services.xserver.displayManager.gdm.enable = true;

      environment.gnome.excludePackages = [
        pkgs.gnome.geary
        pkgs.gnome.gnome-music
        pkgs.epiphany
      ];
      environment.systemPackages = with pkgs; [
        gnome.dconf-editor
      ];
    })
  ];
}

