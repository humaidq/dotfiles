{
  config,
  lib,
  vars,
  pkgs,
  inputs,
  ...
}:
let
  cfg = config.sifr.installer;
in
{
  options.sifr.installer.enable = lib.mkEnableOption "installer profile";

  config = lib.mkIf cfg.enable {
    environment.variables.NIX_CONFIG = "tarball-ttl = 0";

    services.greetd.settings.initial_session = {
      command = lib.getExe pkgs.sway;
      inherit (vars) user;
    };
    boot.supportedFilesystems = {
      zfs = lib.mkForce true;
    };
    hardware.enableRedistributableFirmware = true;
    services.openssh.enable = true;
    networking.firewall.enable = false;
    services.getty.autologinUser = lib.mkForce vars.user;
    security.sudo-rs.enable = lib.mkForce false;
    security.sudo.wheelNeedsPassword = false;
    environment.systemPackages = [ inputs.disko.packages.${pkgs.stdenv.hostPlatform.system}.default ];

    users.users.${vars.user} = {
      isNormalUser = true;
      extraGroups = [ "wheel" ];
      hashedPassword = "$6$67sQfb8Pm3Jyvdvo$OPXnLbgHCdoRfhlhhz/pygvJ32ZA.L0HifV.fBSVW47SsfKK6xiroi/Xx.hcB6YJ94XXaiUH5zqDvnAmKq6gE1";
      hashedPasswordFile = lib.mkForce null;
    };
    home-manager.users.${vars.user} = {
      programs.swaylock.enable = lib.mkForce false;
      services.swayidle.enable = lib.mkForce false;
      wayland.windowManager.sway.config.keybindings."Mod4+l" = lib.mkForce "nop";
    };
  };
}
