{ config, lib, ... }:
let
  cfg = config.sifr;
in
{
  options.sifr.autoupgrade.enable = lib.mkEnableOption "autoupgrades";
  config = lib.mkIf cfg.autoupgrade.enable {
    assertions = [
      {
        assertion = cfg.projectFlake != null;
        message = "sifr.projectFlake must be set when sifr.autoupgrade.enable is true";
      }
    ];

    system.autoUpgrade = {
      enable = true;
      allowReboot = true;
      randomizedDelaySec = "45min";
      rebootWindow = {
        lower = "01:00";
        upper = "05:00";
      };
      dates = "01:30";
      flake = "${cfg.projectFlake}#${config.networking.hostName}";
      flags = [
        "--refresh"
        "-L"
      ];
    };
  };
}
