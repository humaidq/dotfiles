{
  config,
  inputs,
  lib,
  vars,
  ...
}:
{
  config = {
    home-manager.sharedModules = [ inputs.sops-nix.homeManagerModules.sops ];

    sops = {
      defaultSopsFile = ../../secrets/all.yaml;
      defaultSopsFormat = "yaml";
      age.keyFile = "/var/lib/sops-nix/key.txt";
      age.generateKey = true;
      secrets = {
        user-passwd = lib.mkIf (!config.sifr.bootstrap) {
          sopsFile = ../../secrets/all.yaml;
          neededForUsers = true;
        };
        wifi-2g = lib.mkIf config.sifr.hasGadgetSecrets {
          sopsFile = ../../secrets/gadgets.yaml;
        };
        wifi-5g = lib.mkIf config.sifr.hasGadgetSecrets {
          sopsFile = ../../secrets/gadgets.yaml;
        };
        nm-5g = lib.mkIf config.sifr.hasGadgetSecrets {
          sopsFile = ../../secrets/gadgets.yaml;
          path = "/etc/NetworkManager/system-connections/5g.nmconnection";
          owner = "root";
          mode = "600";
        };
        github-token = lib.mkIf config.sifr.hasGadgetSecrets {
          sopsFile = ../../secrets/gadgets.yaml;
          owner = vars.user;
        };
        tskey = lib.mkIf config.sifr.hasGadgetSecrets {
          sopsFile = ../../secrets/gadgets.yaml;
        };
      };
    };

    users.users.${vars.user} =
      if config.sifr.bootstrap then
        {
          hashedPassword = "$6$67sQfb8Pm3Jyvdvo$OPXnLbgHCdoRfhlhhz/pygvJ32ZA.L0HifV.fBSVW47SsfKK6xiroi/Xx.hcB6YJ94XXaiUH5zqDvnAmKq6gE1";
          hashedPasswordFile = lib.mkForce null;
        }
      else
        {
          hashedPasswordFile = config.sops.secrets.user-passwd.path;
        };

    warnings = lib.optional config.sifr.bootstrap "sifr.bootstrap is enabled: the primary user has a known placeholder password. Disable it once sops is configured for this host.";

    sifr.personal.tailscale.authKeyPath = lib.mkIf config.sifr.hasGadgetSecrets config.sops.secrets.tskey.path;
  };
}
