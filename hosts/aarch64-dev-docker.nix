{
  config,
  pkgs,
  lib,
  vars,
  ...
}: {
  sifr = {
    profiles.basePlus = false;
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
