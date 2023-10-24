{
  config,
  pkgs,
  nixpkgs-unstable,
  ...
}: {
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
    graphics = {
      i3.enable = true;
      gnome.enable = true;
    };
    profiles.basePlus = true;
    profiles.laptop = true;
    development.enable = true;
    security.yubikey = true;

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
  boot.binfmt.emulatedSystems = ["aarch64-linux"];
  hardware.flipperzero.enable = true;

  system.stateVersion = "23.0521.11";
}
