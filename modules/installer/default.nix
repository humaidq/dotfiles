{
  config,
  lib,
  vars,
  ...
}:
let
  cfg = config.sifr.installer;
in
{
  options.sifr.installer.enable = lib.mkEnableOption "installer profile";

  config = lib.mkIf cfg.enable {
    environment.variables.NIX_CONFIG = "tarball-ttl = 0";

    home-manager.users.${vars.user} = {
      programs.swaylock.enable = lib.mkForce false;
      services.swayidle.enable = lib.mkForce false;
      wayland.windowManager.sway.config.keybindings."Mod4+l" = lib.mkForce "nop";
    };
  };
}
