{
  self,
  lib,
  inputs,
  pkgs,
  ...
}:
{
  imports = [
    self.nixosModules.sifrOS
    inputs.nixos-hardware.nixosModules.lenovo-thinkpad-t590
    (import ./hardware.nix)
  ];
  networking.hostName = "serow";

  # My configuration specific settings
  sifr = {
    graphics = {
      gnome.enable = true;
      sway.enable = true;
      apps = true;
    };
    profiles = {
      basePlus = true;
      laptop = true;
    };
    v12n.emulation = {
      enable = true;
      systems = [
        "aarch64-linux"
        "riscv64-linux"
      ];
    };
    security = {
      yubikey = true;
      # encryptDNS = true;
    };
    development.enable = true;
    ntp.useNTS = true;
    o11y.client.enable = true;
    applications.emacs.enable = true;

    tailscale = {
      enable = true;
      exitNode = true;
      ssh = true;
      auth = true;
    };
    net.sifr0 = true;
  };

  # Doing riscv64 xcomp, manually gc
  nix.gc.automatic = lib.mkForce false;

  boot.loader = {
    systemd-boot = {
      enable = true;
      consoleMode = "auto";
    };

    efi.canTouchEfiVariables = true;
  };
  topology.self = {
    hardware.info = "Lenovo ThinkPad T590";
  };

  swapDevices = [
    {
      device = "/swap";
      size = 32 * 1024;
    }
  ];

  boot.kernelPackages = pkgs.linuxPackages.packages.linux_6_11;

  nixpkgs.hostPlatform = "x86_64-linux";
  system.stateVersion = "23.11";
}
