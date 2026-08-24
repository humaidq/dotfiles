{
  config,
  lib,
  inputs,
  vars,
  ...
}:
let
  cfg = config.sifr.persist;
  desktopEnabled = lib.attrByPath [ "sifr" "desktop" "enable" ] false config;
  tailscaleEnabled = lib.attrByPath [ "sifr" "personal" "tailscale" "enable" ] false config;
  o11yClientEnabled = lib.attrByPath [ "sifr" "personal" "o11y" "client" "enable" ] false config;
  o11yServerEnabled = lib.attrByPath [ "sifr" "personal" "o11y" "server" "enable" ] false config;
  unifiEnabled = lib.attrByPath [ "services" "unifi-os-server" "enable" ] false config;
  fullRebootEnabled = lib.attrByPath [ "sifr" "router" "fullReboot" "enable" ] false config;
  extraDirs =
    lib.optionals desktopEnabled [
      "/var/lib/bluetooth"
      "/etc/NetworkManager/system-connections"
    ]
    ++ lib.optionals tailscaleEnabled [
      "/var/lib/tailscale"
    ]
    ++ lib.optionals config.services.chrony.enable [ "/var/lib/chrony" ]
    ++ lib.optionals config.services.uptimed.enable [ "/var/lib/uptimed" ]
    ++ lib.optionals (o11yClientEnabled || o11yServerEnabled) [
      "/var/lib/grafana"
      "/var/lib/loki"
    ]
    ++ lib.optionals o11yServerEnabled [
      "/var/lib/prometheus2"
    ]
    # UniFi OS Server keeps the site, the adopted devices and their mongodb
    # under its state directory; losing it means re-adopting every AP by hand.
    # /var/lib/containers goes with it because the appliance image is several
    # gigabytes and podman would otherwise re-import it from the store on every
    # boot.
    # The full-reboot sequence reboots this machine in the middle of itself and
    # has to remember, on the far side, that the access points still have to be
    # done. That memory is a marker file, so it has to outlive the reboot.
    ++ lib.optionals fullRebootEnabled [
      "/var/lib/router-fullreboot"
    ]
    ++ lib.optionals unifiEnabled [
      config.services.unifi-os-server.stateDir
      "/var/lib/containers"
    ];
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
        default = [ ];
      };
      files = lib.mkOption {
        description = "User files to persist";
        type = lib.types.listOf lib.types.anything;
        default = [ ];
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
      default = [ ];
    };
  };

  config = lib.mkIf cfg.enable {
    environment.persistence.${cfg.persistPath} = {
      hideMounts = true;
      directories =
        cfg.dirs
        ++ extraDirs
        ++ [
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
        files = cfg.user.files;
      };
    };

    # sops loads before impermanence mounts are
    sops.age.keyFile = lib.mkForce "${cfg.persistPath}/var/lib/sops-nix/key.txt";

    fileSystems."${cfg.persistPath}".neededForBoot = true;

  };
}
