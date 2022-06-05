# Edit this configuration file to define what should be installed on
# your system.  Help is available in the configuration.nix(5) man page
# and in the NixOS manual (accessible by running ‘nixos-help’).

{ config, pkgs, ... }:

{
  imports =
    [
      # Include the results of the hardware scan.
      ./hardware-configuration.nix
      ../../common
      ./caddy.nix
    ];

  boot.loader.grub = {
    enable = true;
    version = 2;
    device = "/dev/vda"; # or "nodev" for efi only
  };

  networking.hostName = "duisk"; # Define your hostname.
  networking.useDHCP = false;
  networking.interfaces.enp1s0.useDHCP = true;

  # Define a user account. Don't forget to set a password with ‘passwd’.
  users.users.humaid = {
    isNormalUser = true;
    hashedPassword = "$6$67sQfb8Pm3Jyvdvo$OPXnLbgHCdoRfhlhhz/pygvJ32ZA.L0HifV.fBSVW47SsfKK6xiroi/Xx.hcB6YJ94XXaiUH5zqDvnAmKq6gE1";
    openssh.authorizedKeys.keys = [ "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQDCvhQODfyynX4upf8dGPlSBtkdT9Gd0+adYWzdPWitgZjoUrjShsWkfqeo9/XgdzlA3DeJZuG3EhITpG3LH6UQUR75UtlCRZ7n7b8/pyHCHuqnO64PFJ/EuLINj4bmMjaTqUuaEkqL9SeDfdZpPkdvr8HIt62DPG3MVsQETQEGD2oyAymjJw07L5GjmlSk50pCfCgFgAJgiB1Rhrp6ao6fpxB94Gfcw0CS/lvl8F1qh8doqfpdzHj7tABOGFD6AvRxIBX7L8xVimWDOZimec9fnllrOkciS1Tbf+MxNOYxwcxdkQbSc9gvHt1XeGKTXJ+4HosXCpoMtKcpSiyw0GNllcCsayuHEhMZrI2PmiQ87i4mytCMsHDvrGcJbtxwshtu3CzlRyQLsR8dIhZszsROUADKDfJDMCEwGlybcXgFf+/XGDyjHI0bFK1GiXVua0L2zWvFmIxF5dfGOPakKl15zVXv/1zSOeuMFlsbgPYhQsF3STAs/+0wBv3QIB5czj0= humaid@serow" ];

    extraGroups = [ "caddy" ]; # Enable ‘sudo’ for the user.
  };

  hsys = {
    tailscale = {
      enable = true;
      exitNode = true;
      ssh = true;

      # temp
      auth = true;
      tsKey = "tskey-kHFEoZ4CNTRL-S3MVf9QjreJ5pzY8A26bd";
    };
  };


  # Enable the OpenSSH daemon.
  services.openssh = {
    enable = true;
    passwordAuthentication = false;
    permitRootLogin = "no";
  };

  # Gopher server
  services.spacecookie = {
    enable = true;
    settings = {
      root = "/srv/gopher";
    };
  };

  #services.molly-brown = {
  #  enable = true;
  #  hostName = "huma.id";
  #  # Here we have to use caddy.
  #  certPath = 
  #  docBase = "/srv/gemini";
  #};


  # Open ports in the firewall.
  networking.firewall.allowedTCPPorts = [ 443 80 70 ];

  # This value determines the NixOS release from which the default
  # settings for stateful data, like file locations and database versions
  # on your system were taken. It‘s perfectly fine and recommended to leave
  # this value at the release version of the first install of this system.
  # Before changing this value read the documentation for this option
  # (e.g. man configuration.nix or on https://nixos.org/nixos/options.html).
  system.stateVersion = "21.11"; # Did you read the comment?

}

