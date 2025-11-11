{
  config,
  lib,
  pkgs,
  vars,
  ...
}:
let
  cfg = config.sifr.profiles;
in
{
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
    services.logind.lidSwitchExternalPower = lib.mkForce "ignore";

    hardware.bluetooth.enable = true;
    users.users.${vars.user}.extraGroups = [
      "bluetooth"
      "lp"
    ];
    # Allow setting cpupower
    environment.systemPackages = [
      config.boot.kernelPackages.cpupower
      pkgs.powertop
    ];

    services.printing = {
      enable = true;
      drivers = with pkgs; [
        gutenprint
        # Epson L4150
        epson-escpr
      ];
    };
    hardware.printers.ensureDefaultPrinter = "L4150";
    hardware.printers.ensurePrinters = [
      {
        name = "L4150";
        description = "Epson L4150";
        deviceUri = "lpd://192.168.1.188:515/PASSTHRU";
        location = "Office";
        model = "epson-inkjet-printer-escpr/Epson-L4150_Series-epson-escpr-en.ppd";
        ppdOptions = {
          PageSize = "A4";
          DefaultOutputOrder = "Reverse";
        };
      }
    ];

    # disable due to security
    services.avahi = {
      #enable = true;
      #nssmdns4 = true;
      #nssmdns6 = true;
      #publish = {
      #  enable = false;
      #  addresses = true;
      #};
    };

    location.provider = "geoclue2";

    services.geoclue2 = {
      enable = true;
      geoProviderUrl = "https://api.beacondb.net/v1/geolocate";
      submissionUrl = "https://api.beacondb.net/v2/geosubmit";
      submitData = true;
      appConfig = {
        "org.gnome.Maps" = {
          isAllowed = true;
          isSystem = false;
        };
        "geoclue-demo-agent" = {
          isAllowed = true;
          isSystem = false;
        };
        "geoclue-where-am-i" = {
          isAllowed = true;
          isSystem = false;
        };
        "where-am-i" = {
          isAllowed = true;
          isSystem = false;
        };
      };

      #appConfig.gammastep = {
      #  isAllowed = true;
      #  isSystem = false;
      #};
    };

    #services.automatic-timezoned.enable = true;

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
      sifr.graphics.sway.enable = lib.mkForce false;
      sifr.graphics.apps = lib.mkForce false;
      sifr.graphics.enableSound = true;

      # Make sure network manager is enabled
      networking.networkmanager.enable = true;
    };
  };
}
