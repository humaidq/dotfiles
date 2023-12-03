{
  config,
  pkgs,
  lib,
  vars,
  ...
}: {
  sifr = {
    profiles.basePlus = true;
    #development.enable = true;
    security.harden = false;
  };

  # Allow passwordless login
  users.users = {
    ${vars.user}.initialHashedPassword = "";
    root.initialHashedPassword = "";
  };
  home-manager.users."${vars.user}".services.gpg-agent.pinentryFlavor = "curses";
}
