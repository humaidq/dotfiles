{
  config,
  lib,
  pkgs,
  ...
}: let
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
    runtimeInputs = with pkgs; [
      coreutils
    ];
    text = ''
      echo "level $1" | doas tee /proc/acpi/ibm/fan
    '';
  };
  mkcd = pkgs.writeShellApplication {
    name = "mkcd";
    runtimeInputs = [pkgs.coreutils];
    text = "mkdir -p \"$@\" && cd \"$@\"";
  };
in {
  options.sifr.scripts.enable = lib.mkOption {
    description = "Enable custom home scripts";
    type = lib.types.bool;
    default = config.sifr.profiles.basePlus;
  };
  config = lib.mkIf cfg.enable {
    environment.systemPackages = [
      whoseport
      lacheck
      fan
      mkcd
    ];
  };
}
