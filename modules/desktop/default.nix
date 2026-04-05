{
  config,
  pkgs,
  lib,
  vars,
  ...
}:
let
  cfg = config.sifr.desktop;
  inherit (lib)
    mkOption
    types
    mkMerge
    mkIf
    mkEnableOption
    ;
in
{
  imports = [
    ./sway
    ./labwc
    ./apps.nix
  ];
  options.sifr.desktop = {
    enable = mkOption {
      description = "Sets up the graphical user environment";
      type = types.bool;
      default = cfg.sway.enable || cfg.labwc.enable;
    };
    hidpi = mkEnableOption "HIDPI screen configuration";
    # Have separate option as we want the ability to disable for VMs with GUI
    enableSound = mkOption {
      description = "Enables sound server and configurations";
      type = types.bool;
      default = cfg.enable;
    };
    berkeley = {
      enable = mkEnableOption "Berkeley Mono font across applications";
    };
  };
  config = mkMerge [
    # All HiDPI graphical systems
    (mkIf (cfg.enable && cfg.hidpi) {
      hardware.opengl.enable = true;
      services.xserver.dpi = 180;
    })
    (mkIf cfg.enableSound {
      services.pipewire = {
        enable = true;
        alsa.enable = true;
        alsa.support32Bit = true;
        pulse.enable = true;
        wireplumber.enable = true;
      };
      services.pulseaudio.enable = false; # replaced with pipewire above
    })
    (mkIf cfg.enable {
      # home-manager can get angry if dconf is not enabled.
      programs.dconf.enable = true;

      services.xserver = {
        enable = true;
        excludePackages = [ pkgs.xterm ];
      };

      environment.systemPackages = with pkgs; [
        networkmanager-openconnect
      ];
      systemd.network.enable = false;

      networking = {
        networkmanager = {
          enable = true;
          wifi.backend = "wpa_supplicant";
        };
        useNetworkd = false;
      };
      # Make system look better overall when we have a graphical system
      boot.plymouth = {
        enable = false;
        logo = ../../assets/sifr-icon-blue.png;
      };
      home-manager.backupFileExtension = "hm-bak";
      home-manager.users."${vars.user}" = {
        # Default themeing for GTK and Qt
        qt = {
          enable = true;
          platformTheme.name = "gtk";
          style.name = "breeze";
        };

        gtk = {
          enable = true;
          theme = {
            name = "TraditionalOk";
            package = pkgs.mate.mate-themes;
          };
          iconTheme = {
            name = "mate";
            package = pkgs.mate.mate-icon-theme;
          };
          cursorTheme = {
            name = "DMZ-White";
            package = pkgs.vanilla-dmz;
          };
          gtk3.extraConfig = {
            gtk-application-prefer-dark-theme = false;
            gtk-cursor-theme-name = "DMZ-White";
          };
          gtk3.bookmarks = [
            "file:///home/${vars.user}/docs"
            "file:///home/${vars.user}/repos"
            "file:///home/${vars.user}/inbox"
            "file:///home/${vars.user}/inbox/web"
          ];
        };

        xsession.enable = true;
        xsession.profileExtra = "export PATH=$PATH:$HOME/.bin";

        programs.ghostty = {
          enable = true;
          settings = {
            theme = "Dracula";
            font-family = if cfg.berkeley.enable then "Berkeley Mono" else "Fira Code";
            font-size = "12";

            # For ssh
            shell-integration-features = "ssh-terminfo,ssh-env";

            # Don't inherit working dir
            working-directory = "home";
            window-inherit-working-directory = false;
            tab-inherit-working-directory = false;
            split-inherit-working-directory = false;
            confirm-close-surface = false;

            # No "are you sure" dialog
            window-save-state = "never";
          };
        };
      };
    })
  ];
}
