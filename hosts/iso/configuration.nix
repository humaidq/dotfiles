{ lib, config, pkgs, ... }:

{
  imports =
    [
      <nixpkgs/nixos/modules/installer/cd-dvd/installation-cd-minimal.nix>
      <nixpkgs/nixos/modules/installer/cd-dvd/channel.nix>
      <nixpkgs/nixos/modules/profiles/qemu-guest.nix>
      ../../common
      ../../common/laptop.nix
    ];

  networking = {
    hostName = "humaid-iso-installer"; # Define your hostname.
  };

  # installation-cd-minimal enables this, we use NetworkManager so we disable
  # it again.
  networking.wireless.enable = false;

  # My configuration specific settings
  hsys.enableGnome = true;
  hsys.enableDwm = true;
  hsys.getDevTools = true;
  hsys.laptop = true;
  hsys.virtualisation = false;

  # Installation user stuff
  users.users.humaid.initialHashedPassword = lib.mkForce "";
  security.doas.wheelNeedsPassword = false;
  services.getty.autologinUser = lib.mkForce "humaid";
  services.getty.helpLine = ''
    This is Humaid's special NixOS installation disk.

    You should login to the 'humaid' user, which you can login to
    without password.

    SSH daemon is also running.
  '';

  system.build.isoImage = {
    compressImage = true;
    isoBaseName = "hsys";
    #efiSplashImage = ./efi-background.png;
    splashScreen = ./bios-boot.png;
  };
  services.timesyncd.enable = lib.mkForce true; #config with qemu settings


  # This value determines the NixOS release from which the default
  # settings for stateful data, like file locations and database versions
  # on your system were taken. It‘s perfectly fine and recommended to leave
  # this value at the release version of the first install of this system.
  # Before changing this value read the documentation for this option
  # (e.g. man configuration.nix or on https://nixos.org/nixos/options.html).
  system.stateVersion = "21.11"; # Did you read the comment?

}

