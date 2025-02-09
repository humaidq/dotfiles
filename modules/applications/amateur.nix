{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.sifr.applications;
in
{

  options.sifr.applications.amateur.enable = lib.mkEnableOption "amateur radio tools";
  config = lib.mkIf cfg.amateur.enable {
    environment.systemPackages = with pkgs; [
      # digital modes
      wsjtx
      js8call
      flrig
      fldigi
      # mapping
      gridtracker
      gpredict
      # logging
      qlog
      cqrlog
      # sdr
      gnuradio
    ];
  };

}
