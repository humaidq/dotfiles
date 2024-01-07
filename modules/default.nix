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
  cfg = config.sifr;
in {

  config = mkMerge [
    ( {
      users.users.${vars.user} = {
        isNormalUser = true;
        uid = 1000;
        extraGroups = [
          "plugdev"
          "dialout"
          "video"
          "audio"
          "docker"
          "disk"
          "networkmanager"
          "wheel"
          "lp"
          "kvm"
        ];
        description = cfg.fullname;
      };

      home-manager.users.${vars.user} = {
        home.stateVersion = "23.05";
        home.sessionPath = ["$HOME/.bin"];

        nixpkgs.config.allowUnfree = true;
      };

      time.timeZone = cfg.timezone;
      i18n.defaultLocale = "en_GB.UTF-8";

      # We enable DHCP for all network interfaces by default.
      networking.useDHCP = lib.mkDefault true;

      services.timesyncd = {
        enable = true;
        servers = [
          "0.asia.pool.ntp.org"
          "1.asia.pool.ntp.org"
          "2.asia.pool.ntp.org"
          "3.asia.pool.ntp.org"
        ];
      };

      nix = {
        settings = {
          allowed-users = [cfg.username];
          auto-optimise-store = true;

          # Enable flakes
          experimental-features = ["nix-command" "flakes"];

          # Ghaf development
          #trusted-substituters = [
          #  "https://cache.vedenemo.dev"
          #];

          #substituters = [
          #  "https://cache.vedenemo.dev"
          #];

          #trusted-public-keys = [
          #  "cache.vedenemo.dev:RGHheQnb6rXGK5v9gexJZ8iWTPX6OcSeS56YeXYzOcg="
          #];
        };
        gc = {
          automatic = true;
          dates = "weekly";
          options = "--delete-older-than 60d";
        };
      };

      # Use spleen font for console (tty)
      fonts.packages = with pkgs; [
        spleen
      ];
      console.font = "${pkgs.spleen}/share/consolefonts/spleen-12x24.psfu";

      nixpkgs = {
        # Allow proprietary packages and packages marked as broken
        config = {
          allowUnfree = true;
          allowBroken = true;
        };
      };
    })
  ];
}
