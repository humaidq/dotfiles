{ lib, ... }:
let
  inherit (lib) mkOption types;
in
{
  options.sifr = {
    timezone = mkOption {
      description = "Sets the timezone";
      type = types.nullOr types.str;
      default = null;
    };
    username = mkOption {
      description = "Short username of the system user";
      type = types.nullOr types.str;
      default = null;
    };
    fullname = mkOption {
      description = "Full name of the system user";
      type = types.nullOr types.str;
      default = null;
    };
    gitEmail = mkOption {
      description = "Default git email for the main user";
      type = types.nullOr types.str;
      default = null;
    };
    projectFlake = mkOption {
      description = "Base flake reference used for system automation";
      type = types.nullOr types.str;
      default = null;
    };
    banner = mkOption {
      description = "System use banner";
      type = types.str;
      default = ''
        You are accessing a private computer system.
        Unauthorised use of the system is prohibited and subject to criminal and civil penalties.
      '';
    };
    hasGadgetSecrets = lib.mkEnableOption "gadget secrets";
  };
}
