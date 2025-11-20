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
        packages = with pkgs; [
          noto-fonts
          noto-fonts-cjk-sans
          noto-fonts-emoji
          noto-fonts-extra
          source-code-pro
          source-sans-pro
          source-serif-pro
          amiri
          roboto
          fira-code
          cantarell-fonts
          freefont_ttf
          inconsolata
          liberation_ttf
          ttf_bitstream_vera
          inter
          ibm-plex
          merriweather
          jetbrains-mono
          # Bitmap fonts
          terminus_font
          cherry
          spleen
          nerd-fonts.fira-code
          nerd-fonts.jetbrains-mono
          nerd-fonts.symbols-only
        ];
      };
    })
    (lib.mkIf cfg.apps {
      environment.systemPackages = with pkgs; [
        gimp
        pinta
        inkscape
        libreoffice
        # rpi-imager # broken
        prusa-slicer
        gnome-firmware
        bitwarden-desktop
        ghostty
        calibre
        xournalpp
        vlc
        papers # replacing evince
        showtime # replacing totem

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
      ];
      services.fwupd.enable = true;
      #services.power-profiles-daemon.enable = true;

      # for localsend
      networking.firewall.allowedTCPPorts = [ 53317 ];
      networking.firewall.allowedUDPPorts = [ 53317 ];
    })
  ];
}
