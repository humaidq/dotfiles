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
        user-passwd = {
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

    users.users.${vars.user}.hashedPasswordFile = config.sops.secrets.user-passwd.path;

    sifr.personal.tailscale.authKeyPath = lib.mkIf config.sifr.hasGadgetSecrets config.sops.secrets.tskey.path;
  };
}
