{
  config,
  pkgs,
  home-manager,
  unstable,
  lib,
  ...
}:
with lib; let
  cfg = config.sifr.hardware;
in {
  options.sifr.hardware.vm = mkOption {
    description = "Enables VM hardware specific configurations.";
    type = types.bool;
    default = false;
  };
}

