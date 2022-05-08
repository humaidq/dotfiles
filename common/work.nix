# This contains work-specific settings.
{ config, pkgs, lib, ... }:
with lib;
let
  cfg = config.hsys;
in
{
  options.hsys.workProfile = mkOption {
    description = "Enable work profile settings";
    type = types.bool;
    default = false;
  };

  config = mkIf cfg.workProfile {
    #hardware.printers.ensurePrinters = [{
    #  name = "TII_Secure";
    #  model = "${./assets/taskalfa4053ci-driverless-cupsfilters.ppd}";
    #  location = "TII Any Printer";
    #  deviceUri = "lpd://10.161.10.41";
    #  ppdOptions = { PageSize = "A4"; };
    #}];
    #hardware.printers.ensureDefaultPrinter = lib.mkForce "TII_Secure";

    # Default applications for graphical systems
    environment.systemPackages = with pkgs; [
      tailscale
      stlink
      qgroundcontrol
      nodejs
      yarn
    ];
  };
}

