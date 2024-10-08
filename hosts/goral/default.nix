{ self, lib, ... }:
{
  imports = [
    self.nixosModules.sifrOS
    (import ./hardware.nix)
    ../../lib/vmware-guest.nix
  ];
  networking.hostName = "goral";

  # My configuration specific settings
  sifr = {
    graphics = {
      gnome.enable = true;
      sway.enable = true;
      hidpi = true;
      enableSound = false;
      apps = true;
    };
    v12n.docker.enable = true;
    v12n.emulation.systems = [ "x86_64-linux" ];
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

  boot.loader = {
    systemd-boot = {
      enable = true;
      consoleMode = "auto";
    };

    efi.canTouchEfiVariables = true;
  };

  # We have our own module that works with aarch64.
  disabledModules = [ "virtualisation/vmware-guest.nix" ];
  virtualisation.vmware.guest.enable = true;
  networking.firewall.enable = lib.mkForce false;

  nixpkgs.hostPlatform = "aarch64-linux";
  system.stateVersion = "23.11";
}
