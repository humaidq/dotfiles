{
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
      gnome.enable = true;
      hidpi = true;
      enableSound = false;
      apps = true;
    };
    v18n.docker.enable = true;
    v18n.emulation.systems = ["x86_64-linux"];
    hardware.vm = true;
    profiles.basePlus = true;
    development.enable = true;
    security.yubikey = true;

    tailscale = {
      enable = true;
      exitNode = false;
      ssh = true;
    };
  };
}
