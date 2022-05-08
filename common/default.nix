# This is the commons files, which is attributes that spans different
# system types (e.g. graphical, server, RPi, etc).
{ config, pkgs, lib, ... }:
let
  unstableTarball =
    fetchTarball
      https://github.com/NixOS/nixpkgs/archive/nixos-unstable.tar.gz;
in
{
  imports =
    [
      ./user
      ./security.nix
      ./apps.nix
      ./graphical.nix
      ./v12n.nix
      ./backup.nix
      ./work.nix
      ./laptop.nix
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
      pinentryFlavor = "tty";
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

  nix = {
    allowedUsers = [ "humaid" ];
    autoOptimiseStore = true;
    gc.automatic = true;
    gc.dates = "19:00";
  };

  nixpkgs.config.packageOverrides = pkgs: {
    unstable = import unstableTarball {
      config = config.nixpkgs.config;
    };
  };

  # Use spleen font for console (tty)
  fonts.fonts = with pkgs; [
    spleen
  ];
  console.font = "${pkgs.spleen}/share/consolefonts/spleen-16x32.psfu";

  nixpkgs.config.allowUnfree = true;
  nixpkgs.config.allowBroken = true;
  nixpkgs.overlays = [
    (self: super: {
      tor-browser-bundle-bin = super.tor-browser-bundle-bin.overrideAttrs (old: rec  {
        src = super.fetchurl {
          url = "https://huma.id/tor.tar.xz";
          sha256 = "sha256:0pz1v5ig031wgnq3191ja08a4brdrbzziqnkpcrlra1wcdnzv985";
        };
      });
      st = super.st.overrideAttrs (old: rec {
        src = /home/humaid/repos/system/st;
      });
      # Overlaying a package inside a scope is a bit awkward
      #gnome = super.gnome.overrideScope' (gself: gsuper: {
      #  gdm = gsuper.gdm.overrideAttrs (old: {
      #    icon = ./hsys-white.svg;
      #  });
      #});
      dwm = super.dwm.overrideAttrs (old: rec {
        src = /home/humaid/repos/system/dwm;
        #src = builtins.fetchGit {
        #  url = "https://git.sr.ht/~humaid/dwm";
        #  rev = "2c41d2c22d3f363669f916ab4820b0783b442277";
        #};
      });
    })
  ];
}
