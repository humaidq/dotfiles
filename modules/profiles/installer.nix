{
  config,
  lib,
  ...
}: let
  cfg = config.sifr.profiles;
in {
  options.sifr.profiles.installer = lib.mkOption {
    description = "Installer profile";
    type = lib.types.bool;
    default = false;
  };
  config =
    lib.mkIf cfg.installer {
    };
}
