{
  config,
  pkgs,
  lib,
  ...
}:
let
  cfg = config.sifr.desktop.brightness;

  sifrBrightness = pkgs.writeShellApplication {
    name = "sifr-brightness";
    runtimeInputs =
      with pkgs;
      [
        brightnessctl
        coreutils # cut, head, tr
        gnugrep
        libnotify
      ]
      ++ lib.optional cfg.appleStudioDisplay pkgs.asdbctl;
    text = builtins.readFile ./brightness.sh;
  };
in
{
  options.sifr.desktop.brightness = {
    enable = lib.mkEnableOption "brightness key handling" // {
      default = config.sifr.desktop.enable;
    };
    appleStudioDisplay = lib.mkEnableOption "Apple Studio Display backlight control via asdbctl" // {
      default = true;
    };
    # So the window managers can bind the keys without rebuilding the wrapper.
    package = lib.mkOption {
      description = "The resolved brightness wrapper, for use in keybindings";
      type = lib.types.package;
      readOnly = true;
      default = sifrBrightness;
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ sifrBrightness ];

    # asdbctl ships a rule that uaccess-tags the display's hidraw node, so the
    # seat's user can drive the backlight without root. Without it every call
    # fails with EACCES on /dev/hidraw*.
    services.udev.packages = lib.mkIf cfg.appleStudioDisplay [ pkgs.asdbctl ];
  };
}
