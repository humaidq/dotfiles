{
  self,
  vars,
  config,
  lib,
  pkgs,
  ...
}: {
  imports = [
    self.nixosModules.sifrOS
    (import ./hardware.nix)
  ];
  networking.hostName = "duisk";

  boot.loader.grub = {
    enable = true;
    device = "/dev/vda";
  };

  users.users."${vars.user}" = {
    hashedPassword = "$6$67sQfb8Pm3Jyvdvo$OPXnLbgHCdoRfhlhhz/pygvJ32ZA.L0HifV.fBSVW47SsfKK6xiroi/Xx.hcB6YJ94XXaiUH5zqDvnAmKq6gE1";
    hashedPasswordFile = lib.mkForce null;
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
    };
  };

  ## START case study
  users.users.casestudy = {
    isSystemUser = true;
    group = "casestudy";
    home = "/var/lib/casestudy";
  };
  users.groups.casestudy = {};
  systemd.services."case-study" = {
    description = "Case Study";
    wantedBy = ["multi-user.target"];
    environment = {
      "OPENAI_KEY_PATH" = "/var/lib/casestudy/key";
    };
    path = [pkgs.chromium pkgs.ibm-plex];
    serviceConfig = let
      case-study = pkgs.buildGoModule {
        name = "case-study";
        src = pkgs.fetchFromGitHub {
          owner = "humaidq";
          repo = "case-study-generator";
          rev = "93a6b281732d3325e800d322048850539e628c84";
          sha256 = "sha256-WL+fczsBqA6QdiYhu/LQxYZTpdC+02tADALRc477M8U=";
        };
        vendorHash = null;
      };
    in {
      Type = "simple";
      ExecStart = "${case-study}/bin/case-study-gen";
      Restart = "always";
      User = "casestudy";
      Group = "casestudy";
      StateDirectory = "casestudy";
      WorkingDirectory = "/var/lib/casestudy";
    };
  };
  ## END case study

  system.autoUpgrade = {
    enable = true;
    allowReboot = true;
    flake = "github:humaidq/dotfiles#${config.networking.hostName}";
    flags = ["--refresh" "-L"];
  };

  nixpkgs.hostPlatform = "x86_64-linux";
  system.stateVersion = "23.11";
}
