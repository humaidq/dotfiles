{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.sifr.personal.netwatch;
  netwatch = import ./package.nix { inherit pkgs; };
in
{
  options.sifr.personal.netwatch.enable =
    lib.mkEnableOption "periodic LAN capture and local traffic analysis";

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ netwatch ];
  };
}
