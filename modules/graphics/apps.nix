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
in {
  options.sifr.graphics.apps = mkOption {
    description = "Enables workstation graphical applications";
    type = types.bool;
    default = false;
  };
  config = mkMerge [
    (mkIf cfg.apps {
      boot.plymouth = {
        #font = "${pkgs.inter}/share/fonts/opentype/Inter-Regular.otf";
      };
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
        zathura
        firefox
      ];

      # 1password setup
      programs._1password.enable = true;
      programs._1password-gui = {
        enable = true;
        polkitPolicyOwners = ["${vars.user}"];
      };
      services.gnome.gnome-keyring.enable = true;

      environment.variables = {
        "SSH_AUTH_SOCK" = "~/.1password/agent.sock";
      };
    })
    (mkIf (cfg.apps && !config.sifr.hardware.vm) {
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
        unstable.ollama
      ];
    })
  ];
}
