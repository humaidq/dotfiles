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
      unstable.wsjtx
      js8call
      fldigi
      # rig control
      flrig
      unstable.hamlib_4
      # mapping
      gridtracker
      gpredict
      # logging
      qlog
      cqrlog
      # sdr
      gnuradio
      # ax.25
      ax25-tools
      ax25-apps
      direwolf
    ];

  boot.kernelPatches = lib.singleton {
    name = "ax25-ham";
    patch = null;
    extraStructuredConfig = with lib.kernel; {
      HAMRADIO = yes;
      AX25 = yes;
      AX25_DAMA_SLAVE = yes;
    };
  };
  };
}
