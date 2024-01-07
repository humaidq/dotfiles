{
  config,
  pkgs,
  lib,
  vars,
  ...
}: {
  sifr = {
    security.harden = false;
  };

  # Allow passwordless login
  users.users = {
    ${vars.user}.initialHashedPassword = "";
    root.initialHashedPassword = "";
  };


  sifr = {
    profiles.basePlus = true;
  };

  # Reduce size
  documentation.enable = lib.mkForce false;
  documentation.nixos.enable = lib.mkForce false;
  security.polkit.enable = lib.mkForce false;
  security.rtkit.enable = lib.mkForce false;
  security.apparmor.enable = lib.mkForce false;
}
