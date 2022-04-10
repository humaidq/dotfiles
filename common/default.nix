# This is the commons files, which is attributes that spans different
# system types (e.g. graphical, server, RPi, etc).
{ config, pkgs, lib, ... }:
{

  imports =
    [
      ./user
      ./security.nix
      ./apps.nix
      ./graphical.nix
      ./v12n.nix
      ./backup.nix
    ];

  time.timeZone = "Asia/Dubai";
  i18n.defaultLocale = "en_GB.UTF-8";

  documentation = {
    enable = true;
    nixos.enable = true;
    man.enable = true;
    man.generateCaches = true;
    info.enable = true;
    doc.enable = true;
  };

  # Some programs need SUID wrappers, can be configured further or are
  # started in user sessions.
  programs = {
    mtr.enable = true;
    gnupg.agent = {
      enable = true;
      enableSSHSupport = true;
    };
  };

  # This allows updating intel microcode
  hardware.enableRedistributableFirmware = true;

  services.fwupd.enable = true;
  services.timesyncd.enable = true;
  services.timesyncd.servers = [
    "0.asia.pool.ntp.org"
    "1.asia.pool.ntp.org"
    "2.asia.pool.ntp.org"
    "3.asia.pool.ntp.org"
  ];

  nixpkgs.config.allowUnfree = true;
  nixpkgs.config.allowBroken = true;
  nix.allowedUsers = [ "humaid" ];

  nixpkgs.overlays = [
    (self: super: {
      tor-browser-bundle-bin = super.tor-browser-bundle-bin.overrideAttrs (old: rec  {
        src = super.fetchurl {
          url = "https://huma.id/tor-browser-linux64-11.0.6_en-US.tar.xz";
          sha256 = "dfb1d238e2bf19002f2f141178c3af80775dd8d5d83b53b0ab86910ec4a1830d";
        };
      });
      st = super.st.overrideAttrs (old: rec {
        src = /home/humaid/repos/system/st;
      });
      dwm = super.dwm.overrideAttrs (old: rec {
        src = /home/humaid/repos/system/dwm;
        #src = builtins.fetchGit {
        #  url = "https://git.sr.ht/~humaid/dwm";
        #  rev = "f2943ca1b20fb5069d5383380f9a98a66eb466aa";
        #};
      });
    })
  ];
}
