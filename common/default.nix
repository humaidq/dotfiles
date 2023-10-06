# This is the commons files, which is attributes that spans different
# system types (e.g. graphical, server, RPi, etc).
{ config, pkgs, unstable, lib, ... }:
with lib;
let
  cfg = config.hsys;
in
{
  imports =
    [
      ./security.nix
      ./apps.nix
      ./graphical.nix
      ./work.nix
      ./laptop.nix
      ./tailscale.nix
    ];


  options.hsys.git.sshkey = mkOption {
    description = "Set Git SSH signing key";
    type = types.str;
    default = "";
  };
  options.hsys.minimal = mkOption {
    description = "Keep the system minimal and small";
    type = types.bool;
    default = false;
  };

  config = mkMerge [
    ({
      time.timeZone = "Asia/Dubai";
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
          allowed-users = [ "humaid" ];
          auto-optimise-store = true;

          # Enable flakes
          experimental-features = [ "nix-command" "flakes" ];

          # Ghaf development
          trusted-substituters = [
            "https://cache.vedenemo.dev"
          ];

          substituters = [
            "https://cache.vedenemo.dev"
          ];

          trusted-public-keys = [
            "cache.vedenemo.dev:RGHheQnb6rXGK5v9gexJZ8iWTPX6OcSeS56YeXYzOcg="
          ];
        };
        gc = {
          automatic = true;
          dates = "weekly";
          options = "--delete-older-than 60d";
        };
      };


      # Use spleen font for console (tty)
      fonts.fonts = with pkgs; [
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
    (mkIf (!cfg.minimal) {
      # Enable all documentation.
      documentation = {
        enable = true;
        nixos.enable = true;
        man.enable = true;
        man.generateCaches = true;
        info.enable = true;
        doc.enable = true;
      };

      programs = {
        ssh.startAgent = true;
        mtr.enable = true;
      };

      # This allows updating intel microcode
      hardware.enableRedistributableFirmware = true;
      services.fwupd.enable = true;
    })
  ];
}
