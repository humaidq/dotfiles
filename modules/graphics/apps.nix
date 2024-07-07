{
  config,
  pkgs,
  lib,
  ...
}: let
  cfg = config.sifr.graphics;
in {
  options.sifr.graphics.apps = lib.mkOption {
    description = "Enables workstation graphical applications";
    type = lib.types.bool;
    default = false;
  };
  config = lib.mkMerge [
    (lib.mkIf cfg.apps {
      # Fonts
      fonts = {
        enableDefaultPackages = true;
        enableGhostscriptFonts = true;
        packages = with pkgs; [
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
          fira-code-nerdfont
          cantarell-fonts
          freefont_ttf
          inconsolata
          liberation_ttf
          lmodern
          ttf_bitstream_vera
          inter
          ibm-plex
          merriweather
          # Bitmap fonts
          terminus_font
        ];
      };
    })
    (lib.mkIf (cfg.apps && !config.sifr.hardware.vm) {
      # On VMs, these applications would reside on the host.
      environment.systemPackages = with pkgs; [
        gimp
        pinta
        inkscape
        libreoffice
        rpi-imager
        prusa-slicer
        gnome-firmware

        # Re-add GNOME apps that are needed
        evince
        gnome.gnome-system-monitor
        gnome-text-editor
        loupe

        # GNOME circle apps
        curtail
        eyedropper
        #gaphor
        fragments

        khronos
        hieroglyphic
        impression
        junction
        #letterpress
        lorem
        gnome-obfuscate
        paper-clip
        solanum
        textpieces
        forge-sparks
      ];
      services.fwupd.enable = true;
      services.power-profiles-daemon.enable = true;
    })
  ];
}
