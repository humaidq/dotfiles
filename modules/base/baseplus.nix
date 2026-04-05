{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.sifr.basePlus;
in
{
  options.sifr.basePlus.enable = lib.mkEnableOption "additional general productivity tools";

  config = lib.mkIf cfg.enable {
    environment.systemPackages = with pkgs; [
      btop
      glances
      jpegoptim
      optipng
      yt-dlp
      strace
      netcat
      nmap
      pwgen
      dust
      gping
      traceroute
      borgbackup
      qrencode
      gnupatch
      ripgrep
      sshfs
      jq
      ouch
      hexyl
      poppler-utils
      ufetch
      e2fsprogs
      exiftool
      resvg
      lm_sensors
    ];

    services.uptimed.enable = true;
  };
}
