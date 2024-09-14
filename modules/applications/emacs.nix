{
  config,
  lib,
  vars,
  pkgs,
  ...
}:
let
  cfg = config.sifr.applications;
in
{
  options.sifr.applications.emacs.enable = lib.mkOption {
    description = "Enable emacs configuration";
    type = lib.types.bool;
    default = false;
  };
  config = lib.mkIf cfg.emacs.enable {
    home-manager.users."${vars.user}" = {
      services.emacs.enable = true;
    };
    environment.systemPackages = with pkgs; [
      emacs
      emacsPackages.vterm
    ];
  };
}
