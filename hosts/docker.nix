{
  config,
  pkgs,
  lib,
  ...
}: {
  imports = [
    ../common
  ];

  # My configuration specific settings
  sifr = {
    enablei3 = false;
    getDevTools = false;
    getCliTools = true;
    minimal = true;
    hardenSystem = false;
  };

  users.users.humaid = {
    # Allow passwordless login
    initialHashedPassword = "";
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
