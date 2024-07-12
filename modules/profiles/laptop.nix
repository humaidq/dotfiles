{
  config,
  lib,
  pkgs,
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

    services.printing = {
      enable = true;
      drivers = with pkgs; [
        gutenprint
        # Epson L4150
        epson-escpr
      ];
    };

    specialisation.server-mode.configuration = {
      #system.nixos.tags = ["ServerMode"];
      services.getty.helpLine = ''
          _____                            __  __           _
         / ____|                          |  \/  |         | |
        | (___   ___ _ ____   _____ _ __  | \  / | ___   __| | ___
         \___ \ / _ \ '__\ \ / / _ \ '__| | |\/| |/ _ \ / _` |/ _ \
         ____) |  __/ |   \ V /  __/ |    | |  | | (_) | (_| |  __/
        |_____/ \___|_|    \_/ \___|_|    |_|  |_|\___/ \__,_|\___|


             Server-mode enabled. No desktop environment available.

             You may close the lid, laptop will not suspend.
      '';
      services.logind.lidSwitch = lib.mkForce "ignore";
      services.logind.lidSwitchExternalPower = lib.mkForce "ignore";
      services.xserver.displayManager.gdm.autoSuspend = lib.mkForce false;
      sifr.graphics.gnome.enable = lib.mkForce false;
      sifr.graphics.apps = lib.mkForce false;

      # Make sure network manager is enabled
      networking.networkmanager.enable = true;
    };
  };
}
