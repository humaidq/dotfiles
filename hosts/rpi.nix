{ config, pkgs, lib, ... }:
{
  imports = [
    ../common
  ];

  # My configuration specific settings
  sifr = {
    tailscale = {
      enable = true;
      exitNode = true;
      ssh = true;

      # temp
      auth = true;
      tsKey = "tskey-auth-knws1K7CNTRL-EzBQvwQeW3UpdN4cxq7c1UdJYq67vSSM";
    };
  };

  documentation.enable = lib.mkForce false;
  documentation.nixos.enable = lib.mkForce false;
  security.polkit.enable = lib.mkForce false;
  security.rtkit.enable = lib.mkForce false;
  security.apparmor.enable = lib.mkForce false;


  users.users.humaid = {
    isNormalUser = true;
    hashedPassword = "$6$67sQfb8Pm3Jyvdvo$OPXnLbgHCdoRfhlhhz/pygvJ32ZA.L0HifV.fBSVW47SsfKK6xiroi/Xx.hcB6YJ94XXaiUH5zqDvnAmKq6gE1";
    openssh.authorizedKeys.keys = [ "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIB/iv9RWMN6D9zmEU85XkaU8fAWJreWkv3znan87uqTW" ];
  
    extraGroups = [ "caddy" ];
  };

  system.stateVersion = "23.05";
}
