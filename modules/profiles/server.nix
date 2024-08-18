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
    services.logind.lidSwitch = lib.mkForce "ignore";
    services.logind.lidSwitchExternalPower = lib.mkForce "ignore";

    fonts.fontconfig.enable = lib.mkDefault false;

    # https://github.com/nix-community/srvos/blob/main/nixos/server/default.nix#L62
    systemd = {
      enableEmergencyMode = false;

      watchdog = {
        runtimeTime = "20s";
        rebootTime = "30s";
      };

      sleep.extraConfig = ''
        AllowSuspend=no
        AllowHibernation=no
      '';
    };
  };
}
