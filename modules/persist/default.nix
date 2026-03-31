{
  config,
  lib,
  inputs,
  vars,
  ...
}:
let
  cfg = config.sifr.persist;
in
{
  imports = [
    inputs.impermanence.nixosModules.impermanence
    ./btrfs.nix
    ./zfs.nix
  ];

  options.sifr.persist = {
    enable = lib.mkEnableOption "impermanence modules";
    btrfs.enable = lib.mkEnableOption "btrfs impermanence support";
    zfs = {
      enable = lib.mkEnableOption "zfs impermanence support";
      root = lib.mkOption {
        description = "Root pool to be restored to blank on boot.";
        type = lib.types.str;
      };
    };
    user = {
      enable = lib.mkEnableOption "impermanence paths for main user";
      dirs = lib.mkOption {
        description = "User directories to persist";
        type = lib.types.listOf lib.types.anything;
      };
    };
    persistPath = lib.mkOption {
      type = lib.types.str;
      description = "Path of the persistence mount";
      default = "/persist";
    };
    dirs = lib.mkOption {
      description = "Global directories to persist";
      type = lib.types.listOf lib.types.anything;
    };
  };

  config = lib.mkIf cfg.enable {
    environment.persistence.${cfg.persistPath} = {
      hideMounts = true;
      directories = cfg.dirs ++ [
        "/var/log"
        "/var/lib/nixos"
        "/var/lib/systemd/coredump"
        "/var/lib/sops-nix"
        {
          directory = "/var/lib/private";
          mode = "0700";
        }
      ];
      files = [
        "/etc/machine-id"
        "/etc/ssh/ssh_host_rsa_key"
        "/etc/ssh/ssh_host_rsa_key.pub"
        "/etc/ssh/ssh_host_ed25519_key"
        "/etc/ssh/ssh_host_ed25519_key.pub"
      ];
      users."${vars.user}" = lib.mkIf cfg.user.enable {
        directories = cfg.user.dirs ++ [
          "inbox"
          "repos"
          "docs"
          {
            directory = ".ssh";
            mode = "0700";
          }
          ".config/sops"
          ".config/zsh_history"
        ];
      };
    };

    # sops loads before impermanence mounts are
    sops.age.keyFile = lib.mkForce "${cfg.persistPath}/var/lib/sops-nix/key.txt";

    fileSystems."${cfg.persistPath}".neededForBoot = true;

  };
}
