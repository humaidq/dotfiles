{ config, pkgs, lib, ... }: {
  imports = [
    ../common
  ];

  # My configuration specific settings
  sifr = {
    installer = true;
	enablei3 = true;
    getDevTools = false;
    getCliTools = true;
    minimal = true;
    hardenSystem = true;
  };

  users.users.humaid = {
    # Allow passwordless login
    initialHashedPassword = "";
  };
  services.xserver.displayManager.autoLogin = {
    enable = true;
    user = "humaid";
  };
  # Allow login to root with no password
  users.users.root.initialHashedPassword = "";

  documentation.enable = lib.mkForce false;
  documentation.nixos.enable = lib.mkForce false;
  security.polkit.enable = lib.mkForce false;
  security.rtkit.enable = lib.mkForce false;
  security.apparmor.enable = lib.mkForce false;

  #boot.loader.grub.memtest86.enable = true;
  boot.supportedFilesystems = [ "btrfs" "ntfs" "xfs" ];

  environment.systemPackages = with pkgs; [
    parted
    nvme-cli
    pciutils
    usbutils
    git
    zip unzip
    cryptsetup
  ];

  system.stateVersion = "23.05";
}
