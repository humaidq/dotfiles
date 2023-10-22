{
  config,
  pkgs,
  ...
}: {
  imports = [
    ../common
    ../common/caddy.nix
  ];

  boot.loader.grub = {
    enable = true;
    device = "/dev/vda";
  };

  users.users.humaid = {
    isNormalUser = true;
    hashedPassword = "$6$67sQfb8Pm3Jyvdvo$OPXnLbgHCdoRfhlhhz/pygvJ32ZA.L0HifV.fBSVW47SsfKK6xiroi/Xx.hcB6YJ94XXaiUH5zqDvnAmKq6gE1";
    openssh.authorizedKeys.keys = ["ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIB/iv9RWMN6D9zmEU85XkaU8fAWJreWkv3znan87uqTW"];

    extraGroups = ["caddy"];
  };

  sifr = {
    tailscale = {
      enable = true;
      exitNode = true;
      ssh = true;

      # temp
      #auth = true;
      #tsKey = "tskey-kHFEoZ4CNTRL-S3MVf9QjreJ5pzY8A26bd";
    };
  };

  system.stateVersion = "21.11";
}
