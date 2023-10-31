{
  config,
  pkgs,
  lib,
  ...
}: {
  imports = [
    ../lib/vmware-guest.nix
  ];

  boot.loader = {
    systemd-boot = {
      enable = true;
      consoleMode = "auto";
    };

    efi.canTouchEfiVariables = true;
  };

  # We have our own module that works with aarch64.
  disabledModules = ["virtualisation/vmware-guest.nix"];
  virtualisation.vmware.guest.enable = true;
  networking.firewall.enable = lib.mkForce false;

  # My configuration specific settings
  sifr = {
    graphics = {
      i3.enable = true;
      gnome.enable = true;
      hidpi = true;
      enableSound = false;
      apps = true;
    };
    v18n.docker.enable = true;
    hardware.vm = true;
    profiles.basePlus = true;
    development.enable = true;
    security.yubikey = true;

    tailscale = {
      enable = true;
      exitNode = false;
      ssh = false;

      auth = true;
      tsKey = "tskey-auth-kJy3Zg2CNTRL-C2KHKDFpXUWioAwiSPs8bWPAuG346L6uM";
    };
  };
}
