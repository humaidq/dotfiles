{
  config,
  lib,
  vars,
  ...
}:
let
  cfg = config.sifr.profiles;
in
{
  options.sifr.profiles = {
    receipt = lib.mkEnableOption "receipt printer profile";
  };
  config = lib.mkIf cfg.receipt {
    # receipt printer
    users.groups.escpos = { };
    users.users.${vars.user}.extraGroups = [ "escpos" ];
    services.udev.extraRules = ''
      # Rongta receipt printer via ICS Advent Parallel Adapter
      # Vendor 0xfe6  Product 0x811e
      SUBSYSTEM=="usb", ATTRS{idVendor}=="0fe6", ATTRS{idProduct}=="811e", \
          MODE="0664", GROUP="escpos"
    '';
  };
}
