{ config, pkgs, lib, ... }: {
  imports = [
    ../common
    ../lib/vmware-guest.nix
  ];

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

  virtualisation.docker.enable = true;

  # My configuration specific settings
  sifr = {
	enablei3 = true;
    hidpi = true;
    getDevTools = true;
    git.sshkey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDr6WzdDnXBEBok4FGr0609j985aYZ82+wj/Vipp/pdg git@huma.id";

    isVM = true;

    tailscale = {
      enable = true;
      exitNode = false;
      ssh = true;

      auth = true;
      tsKey = "tskey-auth-kqgVE14CNTRL-ik7eAL6b338aaXZxJeqrA8weWYNtUgwb";
    };
  };

  system.stateVersion = "23.05";
}
