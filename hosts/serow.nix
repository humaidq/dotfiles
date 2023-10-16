{ config, pkgs, nixpkgs-unstable, ... }: {
  imports = [
    ../common
  ];

  boot.loader = {
    systemd-boot = {
      enable = true;
      memtest86.enable = true;
      consoleMode = "auto";
    };

    efi.canTouchEfiVariables = true;
  };

  # My configuration specific settings
  sifr = {
    enablei3 = true;
    enableGnome = true;
    getDevTools = true;
    laptop = true;
    enableYubikey = true;
    #virtualisation = true;
    tailscale = {
      enable = true;
      exitNode = true;
      ssh = true;
    };
  };

  # enable qemu virtualisation
  environment.systemPackages = with pkgs; [
    qemu_kvm
    OVMF
  ];
  boot.binfmt.emulatedSystems = [ "aarch64-linux" ];
  hardware.flipperzero.enable = true;

  system.stateVersion = "23.0521.11";
}
