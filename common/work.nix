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
      # TODO work printer
      hardware.printers.ensurePrinters = [{
        name = "Home_Printer";
        model = "epson-inkjet-printer-escpr/Epson-L4150_Series-epson-escpr-en.ppd";
        location = "Home Office (Abu Dhabi)";
        deviceUri = "lpd://192.168.0.189:515/PASSTHRU";
        ppdOptions = { PageSize = "A4"; };
      }];
      hardware.printers.ensureDefaultPrinter = "Home_Printer";

      # Default applications for graphical systems
      environment.systemPackages = with pkgs; [
        tailscale
        stlink

      ];
   };
}


