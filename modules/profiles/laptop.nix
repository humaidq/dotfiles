{
  config,
  lib,
  pkgs,
  vars,
  ...
}: let
  cfg = config.sifr.profiles;
in {
  options.sifr.profiles.laptop = lib.mkOption {
    description = "Laptop profile";
    type = lib.types.bool;
    default = false;
  };
  config = lib.mkIf cfg.laptop {
    # Assumption: all laptops use SSDs
    services.fstrim.enable = true;

    boot.kernelParams = [
      "workqueue.power_efficient=y"
      # Disable vendor OEM logo (BGRT)
      "video=efifb:nobgrt"
      "bgrt_disable"
    ];
    services.logind.lidSwitch = "suspend";
    hardware.bluetooth.enable = true;
    users.users.${vars.user}.extraGroups = ["bluetooth" "lp"];

    services.printing = {
      enable = true;
      drivers = with pkgs; [
        gutenprint
        # Epson L4150
        epson-escpr
      ];
    };
    hardware.printers.ensurePrinters = [
      {
        name = "L4150";
        description = "Epson L4150";
        deviceUri = "dnssd://EPSON%20L4150%20Series._pdl-datastream._tcp.local/";
        location = "Office";
        model = "epson-inkjet-printer-escpr/Epson-L4150_Series-epson-escpr-en.ppd";
        ppdOptions.PageSize = "A4";
      }
    ];
    services.avahi = {
      enable = true;
      nssmdns4 = true;
      nssmdns6 = true;
      publish = {
        enable = true;
        addresses = true;
      };
    };

    specialisation.server-mode.configuration = {
      services.getty.helpLine = lib.mkOverride 10 ''
          _____                            __  __           _
         / ____|                          |  \/  |         | |
        | (___   ___ _ ____   _____ _ __  | \  / | ___   __| | ___
         \___ \ / _ \ '__\ \ / / _ \ '__| | |\/| |/ _ \ / _` |/ _ \
         ____) |  __/ |   \ V /  __/ |    | |  | | (_) | (_| |  __/
        |_____/ \___|_|    \_/ \___|_|    |_|  |_|\___/ \__,_|\___|


             Server-mode enabled. No desktop environment available.

             You may close the lid, laptop will not suspend.
      '';

      # Don't suspend
      services.logind.lidSwitch = lib.mkForce "ignore";
      services.logind.lidSwitchExternalPower = lib.mkForce "ignore";

      # We don't want GUI
      services.xserver.displayManager.gdm.autoSuspend = lib.mkForce false;
      sifr.graphics.gnome.enable = lib.mkForce false;
      sifr.graphics.apps = lib.mkForce false;

      # Make sure network manager is enabled
      networking.networkmanager.enable = true;
    };
  };
}
