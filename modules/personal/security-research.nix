{
  config,
  lib,
  vars,
  pkgs,
  ...
}:
{
  options.sifr.personal.securityResearch.enable = lib.mkEnableOption "security research tools";

  config = lib.mkIf config.sifr.personal.securityResearch.enable {
    environment.systemPackages = with pkgs; [
      wireshark
      burpsuite
      hashcat
      gobuster
      qemu_full
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
