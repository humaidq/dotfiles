{
  config,
  pkgs,
  vars,
  ...
}: {
  boot.loader.grub = {
    enable = true;
    device = "/dev/vda";
  };

  users.users."${vars.user}" = {
    isNormalUser = true;
    hashedPassword = "$6$67sQfb8Pm3Jyvdvo$OPXnLbgHCdoRfhlhhz/pygvJ32ZA.L0HifV.fBSVW47SsfKK6xiroi/Xx.hcB6YJ94XXaiUH5zqDvnAmKq6gE1";
    extraGroups = ["caddy"];
  };
  services.tailscale.useRoutingFeatures = "both";

  sifr = {
    profiles.basePlus = true;
    caddy.enable = true;

    tailscale = {
      enable = true;
      exitNode = true;
      ssh = true;

      # temp
      #auth = true;
      #tsKey = "tskey-kHFEoZ4CNTRL-S3MVf9QjreJ5pzY8A26bd";
    };
  };
}
