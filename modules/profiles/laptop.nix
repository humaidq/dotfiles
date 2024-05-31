{
  config,
  lib,
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

    # Also assuming all laptops are ThinkPads for now...
    # Fix Thinkpad specific issue of throttling
    services.throttled.enable = true;
  };
}
