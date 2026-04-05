{
  config,
  lib,
  vars,
  ...
}:
{
  options.sifr.personal.receipt.enable = lib.mkEnableOption "receipt printer settings";

  config = lib.mkIf config.sifr.personal.receipt.enable {
    users.groups.escpos = { };
    users.users.${vars.user}.extraGroups = [ "escpos" ];
    services.udev.extraRules = ''
      SUBSYSTEM=="usb", ATTRS{idVendor}=="0fe6", ATTRS{idProduct}=="811e", \
          MODE="0664", GROUP="escpos"
    '';
  };
}
