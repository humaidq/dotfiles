# Contains laptop (Thinkpad) settings.
{ config, pkgs, lib, ... }:
with lib;
let
  cfg = config.hsys;
in
{
  options.hsys.laptop = mkOption {
    description = "Configures laptop-specific settings";
    type = types.bool;
    default = false;
  };

  config = mkIf cfg.laptop {
    services.power-profiles-daemon.enable = false;
    services.tlp = {
      enable = true;
      settings = {
        START_CHARGE_THRESH_BAT0 = 80;
        STOP_CHARGE_THRESH_BAT0 = 85;
        USB_AUTOSUSPEND = 0; # Mouse disconnecting issue
        USB_AUTOSUSPEND_ON_AC = 0;
        USB_AUTOSUSPEND_ON_BAT = 0;
      };
    };
    boot.kernelParams = [
      "workqueue.power_efficient=y"
    ];
    powerManagement = {
      enable = true;
      powertop.enable = true;
    };
    networking.networkmanager.wifi.powersave = true;
    services.xserver.libinput = {
      enable = true;
      touchpad = {
        disableWhileTyping = true;
        tapping = true;
        naturalScrolling = true;
      };
    };
    hardware.bluetooth = {
      enable = true;
      package = pkgs.bluezFull;
      powerOnBoot = false;
    };
    environment.systemPackages = with pkgs; [
      powertop
    ];
    #services.thinkfan.enable = true; # thinkpad_acpi doesn't seem to support fan_control


    # Fix Thinkpad specific issue of throttling
    services.throttled.enable = true;
  };
}
      
