{ config, lib, ... }:
let
  cfg = config.sifr.profiles;
in
{
  options.sifr.profiles.server = lib.mkOption {
    description = "Server profile";
    type = lib.types.bool;
    default = false;
  };
  config = lib.mkIf cfg.server {
    services.logind.settings.Login.HandleLidSwitch = lib.mkForce "ignore";
    services.logind.settings.Login.HandleLidSwitchExternalPower = lib.mkForce "ignore";
    fonts.fontconfig.enable = lib.mkDefault false;

    # https://github.com/nix-community/srvos/blob/main/nixos/server/default.nix#L62
    systemd = {
      enableEmergencyMode = false;
      settings.Manager = {
        RuntimeWatchdogSec = lib.mkDefault "15s";
        RebootWatchdogSec = lib.mkDefault "30s";
        KExecWatchdogSec = lib.mkDefault "1m";
      };

      sleep.extraConfig = ''
        AllowSuspend=no
        AllowHibernation=no
      '';
    };
  };
}
