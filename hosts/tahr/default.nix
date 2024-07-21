{
  inputs,
  self,
  ...
}: {
  imports = [
    self.nixosModules.sifrOS
    inputs.nixos-hardware.nixosModules.lenovo-thinkpad-p1-gen3
    (import ./hardware.nix)
  ];

  networking.hostName = "tahr";

  # My configuration specific settings
  sifr = {
    graphics = {
      gnome.enable = true;
      apps = true;
    };
    v18n.emulation = {
      enable = true;
      systems = ["aarch64-linux"];
    };
    profiles = {
      basePlus = true;
      work = true;
      laptop = true;
    };
    development.enable = true;

    tailscale = {
      enable = true;
      exitNode = true;
      ssh = true;
    };
  };

  nixpkgs.hostPlatform = "x86_64-linux";
  system.stateVersion = "23.11";

  boot.loader = {
    systemd-boot.enable = true;
    efi.canTouchEfiVariables = true;
  };

  # Fix touchpad click not working
  # Kenel bug since 6.1+. See: https://nixos.wiki/wiki/Touchpad
  boot.kernelParams = ["psmouse.synaptics_intertouch=0"];
}
