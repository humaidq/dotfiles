{
  config,
  lib,
  ...
}:
let
  cfg = config.sifr.basePlus;
in
{
  config = lib.mkIf cfg.enable {

  };
}
