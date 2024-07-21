{
  self,
  inputs,
  ...
}: {
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
      apps = true;
    };
    profiles = {
      basePlus = true;
      laptop = true;
    };
    development.enable = true;
    security.yubikey = true;
    v18n.emulation.enable = true;
    v18n.emulation.systems = ["aarch64-linux" "riscv64-linux"];
    homelab.log-server.enable = true;

    tailscale = {
      enable = true;
      exitNode = true;
      ssh = true;
      auth = true;
    };
  };

  boot.loader = {
    systemd-boot = {
      enable = true;
      consoleMode = "auto";
    };

    efi.canTouchEfiVariables = true;
  };

  nixpkgs.hostPlatform = "x86_64-linux";
  system.stateVersion = "23.11";
}
