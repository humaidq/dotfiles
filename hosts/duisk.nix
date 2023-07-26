{ config, pkgs, ... }: {
  imports = [
    ../../common
    ../../common/caddy.nix
  ];

  boot.loader.grub = {
    enable = true;
    version = 2;
    device = "/dev/vda";
  };

  users.users.humaid = {
    isNormalUser = true;
    hashedPassword = "$6$67sQfb8Pm3Jyvdvo$OPXnLbgHCdoRfhlhhz/pygvJ32ZA.L0HifV.fBSVW47SsfKK6xiroi/Xx.hcB6YJ94XXaiUH5zqDvnAmKq6gE1";
    openssh.authorizedKeys.keys = [ "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQDCvhQODfyynX4upf8dGPlSBtkdT9Gd0+adYWzdPWitgZjoUrjShsWkfqeo9/XgdzlA3DeJZuG3EhITpG3LH6UQUR75UtlCRZ7n7b8/pyHCHuqnO64PFJ/EuLINj4bmMjaTqUuaEkqL9SeDfdZpPkdvr8HIt62DPG3MVsQETQEGD2oyAymjJw07L5GjmlSk50pCfCgFgAJgiB1Rhrp6ao6fpxB94Gfcw0CS/lvl8F1qh8doqfpdzHj7tABOGFD6AvRxIBX7L8xVimWDOZimec9fnllrOkciS1Tbf+MxNOYxwcxdkQbSc9gvHt1XeGKTXJ+4HosXCpoMtKcpSiyw0GNllcCsayuHEhMZrI2PmiQ87i4mytCMsHDvrGcJbtxwshtu3CzlRyQLsR8dIhZszsROUADKDfJDMCEwGlybcXgFf+/XGDyjHI0bFK1GiXVua0L2zWvFmIxF5dfGOPakKl15zVXv/1zSOeuMFlsbgPYhQsF3STAs/+0wBv3QIB5czj0= humaid@serow" ];

    extraGroups = [ "caddy" ];
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

  system.stateVersion = "21.11";
}

