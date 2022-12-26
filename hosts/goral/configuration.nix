{ config, pkgs, lib, ... }:
{
  imports =
    [
      ./hardware-configuration.nix
      ../../common
	  ./vmware-guest.nix
    ];

  # Use the systemd-boot EFI boot loader.
  boot.loader = {
    systemd-boot = {
      enable = true;
      consoleMode = "auto";
    };

    efi.canTouchEfiVariables = true;
  };

  # We have our own module that works with aarch64.
  disabledModules = [ "virtualisation/vmware-guest.nix" ];
  virtualisation.vmware.guest.enable = true;

  networking.hostName = "goral";

  # My configuration specific settings
  hsys = {
	enablei3 = true;
    hidpi = true;
    getDevTools = true;

    isVM = true;

    tailscale = {
      enable = true;
      exitNode = false;
      ssh = true;

      auth = true;
      tsKey = "tskey-auth-kdikPt1CNTRL-X8pKxKkb9mLMBtoWy5h6uLfH6qdAuwhH";
    };
  };

  system.stateVersion = "21.11";
}
