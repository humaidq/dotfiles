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
      ./work.nix
      ./laptop.nix
      ./tailscale.nix
    ];

  time.timeZone = "Asia/Dubai";
  i18n.defaultLocale = "en_GB.UTF-8";

  # We enable DHCP for all network interfaces by default.
  networking.useDHCP = true;

  # Enable all documentation.
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
    };
    gc.automatic = true;
    gc.dates = "19:00";

    # Enable flakes
    package = pkgs.nixFlakes;
    extraOptions = ''
      experimental-features = nix-command flakes
    '';
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
      packageOverrides = pkgs: {
        unstable = import unstableTarball {
          config = config.nixpkgs.config;
        };
      };
    };

    # Custom overlays
    overlays = [
      (self: super: {
        #st = super.st.overrideAttrs (old: rec {
        #  src = /home/humaid/repos/system/st;
        #});
        #dwm = super.dwm.overrideAttrs (old: rec {
        #  src = /home/humaid/repos/system/dwm;
        #  #src = builtins.fetchGit {
        #  #  url = "https://git.sr.ht/~humaid/dwm";
        #  #  rev = "2c41d2c22d3f363669f916ab4820b0783b442277";
        #  #};
        #});
        # Overlaying a package inside a scope is a bit awkward
        #gnome = super.gnome.overrideScope' (gself: gsuper: {
        #  gdm = gsuper.gdm.overrideAttrs (old: {
        #    icon = ./hsys-white.svg;
        #  });
        #});
      })
    ];
  };
}
