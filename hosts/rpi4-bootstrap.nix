{
  pkgs,
  vars,
  self,
  inputs,
  lib,
  ...
}: {
  imports = [
    inputs.nixos-hardware.nixosModules.raspberry-pi-4
    self.nixosModules.sifrOS
  ];
  nixpkgs = {
    hostPlatform = "aarch64-linux";
    # Temporary fix for kernel build fail
    # https://github.com/NixOS/nixpkgs/issues/154163
    overlays = [
      (_final: super: {
        makeModulesClosure = x:
          super.makeModulesClosure (x // {allowMissing = true;});
      })
    ];
  };

  sifr = {
    security.harden = false;
    profiles.base = true;
    profiles.basePlus = true;
  };

  system.stateVersion = "24.05";

  networking = {
    firewall.enable = false;
    hostName = "sifrOS-rpi";
  };

  services.openssh.enable = true;
  environment.systemPackages = with pkgs; [
    libraspberrypi
    raspberrypi-eeprom
  ];

  users.motd = ''
    Welcome to the bootstrap system.
    Steps:
      1. Clone dotfiles
      2. Run nixos-generate-config, copy over hardware-configuration.nix.
      3. Configure your host.
      4. Rebuild.
  '';

  users.users.${vars.user} = {
    isNormalUser = true;
    hashedPassword = "$6$67sQfb8Pm3Jyvdvo$OPXnLbgHCdoRfhlhhz/pygvJ32ZA.L0HifV.fBSVW47SsfKK6xiroi/Xx.hcB6YJ94XXaiUH5zqDvnAmKq6gE1";
    hashedPasswordFile = lib.mkForce null;
  };
}
