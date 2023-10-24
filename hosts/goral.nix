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

  virtualisation.docker.enable = true;
  networking.firewall.enable = lib.mkForce false;

  # My configuration specific settings
  sifr = {
    graphics = {
      i3.enable = true;
      hidpi = true;
      enableSound = false;
      apps = true;
    };
    hardware.vm = true;
    profiles.basePlus = true;
    development.enable = true;
    security.yubikey = true;

    tailscale = {
      enable = false;
      exitNode = false;
      ssh = false;

      auth = false;
      tsKey = "tskey-auth-kqgVE14CNTRL-ik7eAL6b338aaXZxJeqrA8weWYNtUgwb";
    };
  };

  system.stateVersion = "23.05";
}
