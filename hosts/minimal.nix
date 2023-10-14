{ config, pkgs, lib, ... }:
{
  imports = [
    ../common
  ];

  # My configuration specific settings
  sifr = {
    enablei3 = true;
    getDevTools = false;
    getCliTools = false;
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


  system.stateVersion = "23.05";
}
