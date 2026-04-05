{
  config,
  pkgs,
  lib,
  ...
}:
let
  cfg = config.sifr.desktop;
in
{
  options.sifr.desktop = {
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
          noto-fonts-color-emoji
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
          symbola
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
        bitwarden-desktop
        ghostty
        xournalpp
        vlc
        pdfpc
        localsend
        alsa-utils
      ];
      services.fwupd.enable = true;
      #services.power-profiles-daemon.enable = true;

      # for localsend
      networking.firewall.allowedTCPPorts = [ 53317 ];
      networking.firewall.allowedUDPPorts = [ 53317 ];
    })
  ];
}
