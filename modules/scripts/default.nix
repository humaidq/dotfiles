{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.sifr.scripts;
  # Simple tool that tells you which process uses a specific port.
  whoseport = pkgs.writeShellApplication {
    name = "whoseport";
    runtimeInputs = with pkgs; [
      gnugrep
      lsof
    ];
    text = ''
      lsof -i ":$1" | grep LISTEN
    '';
  };
  lacheck = pkgs.writeShellApplication {
    name = "lacheck";
    runtimeInputs = with pkgs; [
      pandoc
      languagetool
    ];
    text = ''
      pandoc "$1" -f latex -t plain -o /tmp/lacheck.txt
      languagetool /tmp/lacheck.txt
    '';
  };
  fan = pkgs.writeShellApplication {
    name = "fan";
    runtimeInputs = with pkgs; [ coreutils ];
    text = ''
      if [ $# -eq 0 ]; then
        echo "usage: $0 <level>"
        exit
      fi
      if [ "$EUID" -ne 0 ]; then
        echo "Please run as root"
        exit
      fi

      echo "level $1" | tee /proc/acpi/ibm/fan
    '';
  };
  watchsync = pkgs.writeShellApplication {
    name = "watchsync";
    runtimeInputs = with pkgs; [
      procps
      gnugrep
    ];
    text = "watch -d grep -e Dirty: -e Writeback: /proc/meminfo";
  };
in
{
  options.sifr.scripts.enable = lib.mkOption {
    description = "Enable custom home scripts";
    type = lib.types.bool;
    default = config.sifr.profiles.basePlus;
  };
  config = lib.mkIf cfg.enable {
    environment.systemPackages =
      [
        whoseport
        fan
      ]
      ++ lib.optionals config.sifr.development.enable [
        lacheck
        watchsync
      ];
  };
}
