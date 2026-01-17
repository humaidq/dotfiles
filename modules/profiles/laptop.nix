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

    services.logind.settings.Login.HandleLidSwitch = "suspend";
    services.logind.settings.Login.HandleLidSwitchExternalPower = lib.mkForce "ignore";

    hardware.bluetooth.enable = true;
    users.users.${vars.user}.extraGroups = [
      "bluetooth"
      "lp"
    ];
    # Allow setting cpupower
    environment.systemPackages = [
      config.boot.kernelPackages.cpupower
      pkgs.powertop
      pkgs.simple-scan
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
          OutputOrder = "Reverse";
        };
      }
    ];

    # Make UI responsive
    services.system76-scheduler = {
      enable = true;
      assignments = {
        nix-builds = {
          nice = 10;
          class = "batch";
          ioClass = "idle";
          matchers = [ "nix-daemon" ];
        };

        desktop = {
          nice = -10;
          class = "other";
          ioClass = "realtime";
          matchers = [
            "sway"
            "ghostty"
          ];
        };

        browser = {
          nice = -10;
          class = "other";
          ioClass = "realtime";
          matchers = [
            "chrome"
            "google-chrome"
            "google-chrome-stable"
            "chromium"
          ];
        };
      };
    };

    # disable due to security
    services.avahi = {
      enable = true;
      nssmdns4 = true;
      nssmdns6 = true;
      publish = {
        enable = false;
        addresses = true;
      };
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

  };
}
