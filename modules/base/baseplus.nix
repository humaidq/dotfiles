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
      borgbackup
      btop
      dust
      e2fsprogs
      exiftool
      glances
      gnupatch
      gping
      hexyl
      jpegoptim
      jq
      lm_sensors
      netcat
      nmap
      optipng
      ouch
      poppler-utils
      pwgen
      qrencode
      resvg
      ripgrep
      sshfs
      strace
      traceroute
      ufetch
      yt-dlp
    ];

    # keep track of uptime!
    services.uptimed.enable = true;
  };
}
