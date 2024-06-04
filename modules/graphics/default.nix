{
  config,
  pkgs,
  lib,
  vars,
  ...
}: let
  cfg = config.sifr.graphics;
  inherit (lib) mkOption types mkMerge mkIf;
in {
  imports = [
    ./gnome.nix
    ./sway.nix
    ./apps.nix
  ];
  options.sifr.graphics.enable = mkOption {
    description = "Sets up the graphical user environment with X11";
    type = types.bool;
    default = cfg.gnome.enable || cfg.sway.enable;
  };
  options.sifr.graphics.hidpi = mkOption {
    description = "Configures the system for HiDPI screens";
    type = types.bool;
    default = false;
  };
  options.sifr.graphics.enableSound = mkOption {
    description = "Enables sound server and configurations";
    type = types.bool;
    default = cfg.enable;
  };
  config = mkMerge [
    # All HiDPI graphical systems
    (mkIf (cfg.enable && cfg.hidpi) {
      hardware.opengl.enable = true;
      services.xserver.dpi = 180;
    })
    (mkIf cfg.enableSound {
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
    })
    (mkIf cfg.enable {
      # home-manager can get angry if dconf is not enabled.
      programs.dconf.enable = true;

      services.xserver.enable = true;
      services.xserver.excludePackages = [pkgs.xterm];
      services.xserver.displayManager.gdm.enable = true;

      # We need to make system look better overall when we have a graphical system
      boot.plymouth = {
        enable = true;
        logo = ../../assets/sifr-icon-blue.png;
      };

      home-manager.users."${vars.user}" = {
        # Default themeing for GTK and Qt
        qt = {
          enable = true;
          #platformTheme.name = "gtk";
          #style.package = pkgs.adwaita-qt;
          #style.name = "adwaita-dark";
        };

        gtk = {
          enable = true;
          #theme.name = "Adwaita-dark";
          #gtk3.extraConfig = {
          #  gtk-application-prefer-dark-theme = true;
          #  gtk-cursor-theme-name = "Adwaita";
          #};
          gtk3.bookmarks = [
            "file:///home/${vars.user}/docs"
            "file:///home/${vars.user}/repos"
            "file:///home/${vars.user}/inbox"
            "file:///home/${vars.user}/inbox/web"
          ];
        };

        xsession.enable = true;
        xsession.profileExtra = "export PATH=$PATH:$HOME/.bin";
      };
    })
  ];
}
