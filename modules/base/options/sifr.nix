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
    hasGadgetSecrets = lib.mkEnableOption "gadget secrets";
    bootstrap = lib.mkEnableOption ''
      bootstrap mode for new systems without sops keys yet.
      Sets a known placeholder hashedPassword for the primary user
      instead of reading it from sops, so first login works before
      the host's age key has been added to .sops.yaml. Disable once
      sops is configured for the host
    '';
  };
}
