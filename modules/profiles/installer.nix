{
  config,
  pkgs,
  unstable,
  home-manager,
  lib,
  vars,
  ...
}:
with lib; let
  cfg = config.sifr.profiles;
in {
  options.sifr.profiles.installer = mkOption {
    description = "Installer profile";
    type = types.bool;
    default = false;
  };
  config = mkIf cfg.installer {
    #config.sifr.graphics.i3.enable = mkDefault true;

    home-manager.users."${vars.user}" = {
      home.file.".bin/sifr-install" = {
        executable = true;
        text = builtins.readFile ../../lib/installer.sh;
      };
      xsession.windowManager.i3.config.startup = [
        {command = "alacritty -e 'sifr-install'";}
      ];
    };
  };
}
