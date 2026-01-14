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

  # languagetool check for latex files
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

  # Set thinkpad fan speed
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

  # Watch sync buffer size
  watchsync = pkgs.writeShellApplication {
    name = "watchsync";
    runtimeInputs = with pkgs; [
      procps
      gnugrep
    ];
    text = "watch -d grep -e Dirty: -e Writeback: /proc/meminfo";
  };

  # Benchmark zsh start times
  zbench = pkgs.writeShellApplication {
    name = "zbench";
    runtimeInputs = with pkgs; [
      gawk
      zsh
    ];
    text = builtins.readFile ./zbench.bash;
  };

  # Find impermanence orphans
  persist-orphans = pkgs.writeShellApplication {
    name = "persist-orphans";
    runtimeInputs = with pkgs; [
      gnugrep
    ];
    bashOptions = [ ];
    text = builtins.readFile ./persist-orphans.bash;
  };

  # Geolocate using beacondb.net and provide maidenhead
  blocate = pkgs.writers.writePython3Bin "blocate" {
    libraries = [ pkgs.python312Packages.requests ];
  } (builtins.readFile ./blocate.py);

  vcf2nokia = pkgs.writers.writePython3Bin "vcf2nokia" {
  } (builtins.readFile ./vcf2nokia.py);

  # License generators
  bsd3 = pkgs.writeShellApplication {
    name = "bsd3";
    text = builtins.readFile ./bsd3-license.bash;
  };
  apache2 = pkgs.writeShellApplication {
    name = "apache2";
    text = builtins.readFile ./apache2-license.bash;
  };

  # DNS switcher for when Nebula/internal DNS is down
  dns-switch = pkgs.writeShellApplication {
    name = "dns-switch";
    runtimeInputs = with pkgs; [
      networkmanager
      systemd
      gnugrep
      coreutils
    ];
    text = builtins.readFile ./dns-switch.bash;
  };
in
{
  options.sifr.scripts.enable = lib.mkOption {
    description = "Enable custom home scripts";
    type = lib.types.bool;
    default = config.sifr.profiles.basePlus;
  };
  config = lib.mkIf cfg.enable {
    environment.systemPackages = [
      whoseport
      fan
      zbench
      persist-orphans
      dns-switch
    ]
    ++ lib.optionals config.sifr.development.enable [
      lacheck
      watchsync
      blocate
      bsd3
      apache2
      vcf2nokia
    ];
  };
}
