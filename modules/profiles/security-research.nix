{
  config,
  lib,
  vars,
  pkgs,
  ...
}:
let
  cfg = config.sifr.profiles;
in
{
  options.sifr.profiles = {
    security-research = lib.mkEnableOption "security research profile";
  };
  config = lib.mkIf cfg.security-research {
    environment.systemPackages = with pkgs; [
      wireshark
      burpsuite
      hashcat
      gobuster

      qemu_full # usermode emulation
      ghidra
      picotool

      binwalk
      aflplusplus
      minicom
    ];
    users.users.${vars.user}.extraGroups = [
      "wireshark"
    ];
  };

}
