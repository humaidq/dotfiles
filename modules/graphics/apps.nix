{
  config,
  pkgs,
  lib,
  ...
}:
let
  cfg = config.sifr.graphics;
in
{
  options.sifr.graphics = {
    apps = lib.mkEnableOption "workstation graphical applications";
  };
  config = lib.mkMerge [
    (lib.mkIf cfg.apps {
      # Fonts
      fonts = {
        enableDefaultPackages = true;
        enableGhostscriptFonts = true;
        packages =
          with pkgs;
          [
            noto-fonts
            noto-fonts-cjk-sans
            noto-fonts-emoji
            noto-fonts-extra
            #source-code-pro
            #source-sans-pro
            #source-serif-pro
            amiri
            #corefonts
            roboto
            #ubuntu_font_family
            fira-code
            cantarell-fonts
            freefont_ttf
            inconsolata
            liberation_ttf
            #lmodern
            ttf_bitstream_vera
            inter
            #ibm-plex
            merriweather
            #jetbrains-mono
            # Bitmap fonts
            #terminus_font
            cherry
            spleen
          ]
          ++ [
            (nerdfonts.override {
              # Anything included here must be included above too
              fonts = [
                "FiraCode"
                "JetBrainsMono"
              ];
            })
          ];
      };
    })
    (lib.mkIf (cfg.apps && !config.sifr.hardware.vm) {
      # On VMs, these applications would reside on the host.
      environment.systemPackages = with pkgs; [
        gimp
        #pinta
        inkscape
        libreoffice
        rpi-imager
        prusa-slicer
        gnome-firmware
        bitwarden-desktop
        ghostty
        calibre

        decibels # audio, soon in gnome 48
        gnome-calendar
        gnome-contacts
        errands
        zed-editor

        # GNOME circle apps
        #curtail
        eyedropper
        gaphor
        fragments
        localsend
        fractal
        tuba

        alsa-utils

        #khronos
        #hieroglyphic
        #impression
        #junction
        #letterpress
        #lorem
        #gnome-obfuscate
        #paper-clip
        #solanum
        textpieces
        forge-sparks
      ];
      services.fwupd.enable = true;
      #services.power-profiles-daemon.enable = true;

      networking.firewall.allowedTCPPorts = [ 53317 ];
      networking.firewall.allowedUDPPorts = [ 53317 ];
    })
  ];
}
