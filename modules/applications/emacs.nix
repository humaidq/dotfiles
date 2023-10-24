{
  config,
  pkgs,
  unstable,
  home-manager,
  lib,
  ...
}:
with lib; let
  cfg = config.sifr.applications;
in {
  options.sifr.applications.emacs.enable = mkOption {
    description = "Enable emacs configuration";
    type = types.bool;
    default = false;
  };
  config = mkIf cfg.emacs.enable {
    home-manager.users.humaid = {
      programs.emacs.enable = true;
      home.file.".emacs.d".source = ./emacsconfig;
    };
  };
}
