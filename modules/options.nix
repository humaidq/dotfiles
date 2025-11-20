{ lib, ... }:
let
  inherit (lib) mkOption types;
in
{
  options.sifr = {
    timezone = mkOption {
      description = "Sets the timezone";
      type = types.str;
      default = "Asia/Dubai";
    };
    # TODO move for git
    username = mkOption {
      description = "Short username of the system user";
      type = types.str;
      default = "humaid";
    };
    fullname = mkOption {
      description = "Full name of the system user";
      type = types.str;
      default = "Humaid Alqasimi";
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
