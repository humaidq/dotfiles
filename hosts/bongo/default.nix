{
  self,
  vars,
  lib,
  inputs,
  pkgs,
  config,
  ...
}:
{
  imports = [
    self.nixosModules.sifrOS
    inputs.impermanence.nixosModules.impermanence
    inputs.disko.nixosModules.disko
    #inputs.lanzaboote.nixosModules.lanzaboote
    (import ./hardware.nix)
    (import ./disk.nix)
    (import ./blocking.nix)
    (import ./router.nix)
  ];
  networking.hostName = "bongo";

  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = false;
      PermitRootLogin = "no";
    };
    openFirewall = false;
  };

  users.users."${vars.user}" = {
    hashedPassword = "$6$67sQfb8Pm3Jyvdvo$OPXnLbgHCdoRfhlhhz/pygvJ32ZA.L0HifV.fBSVW47SsfKK6xiroi/Xx.hcB6YJ94XXaiUH5zqDvnAmKq6gE1";
    hashedPasswordFile = lib.mkForce null;
  };

  #sops.secrets."nebula/crt" = {
  #  sopsFile = ../../secrets/bongo.yaml;
  #  owner = "nebula-sifr0";
  #  mode = "600";
  #};
  #sops.secrets."nebula/key" = {
  #  sopsFile = ../../secrets/bongo.yaml;
  #  owner = "nebula-sifr0";
  #  mode = "600";
  #};

  sifr = {
    #profiles.basePlus = true;
    profiles.server = true;
    autoupgrade.enable = true;
    o11y.client.enable = true;

    net = {
      sifr0 = false;
      cacheOverPublic = true;
      node-crt = config.sops.secrets."nebula/crt".path;
      node-key = config.sops.secrets."nebula/key".path;
    };
  };

  # impermanence setup
  environment.persistence."/persist" = {
    hideMounts = true;
    directories = [
      "/var/log"
      "/var/lib/nixos"
      "/var/lib/systemd/coredump"
      "/var/lib/sops-nix"
      "/var/lib/chrony"
      "/var/lib/tailscale"
      "/var/lib/grafana"
      "/var/lib/loki"
      {
        directory = "/var/lib/private";
        mode = "0700";
      }
      "/var/lib/uptimed"
      "/var/lib/sbctl" # lanzaboote pki bundle
      "/etc/secureboot"
      "/etc/NetworkManager/system-connections"
    ];
    files = [
      "/etc/machine-id"
      "/etc/ssh/ssh_host_rsa_key"
      "/etc/ssh/ssh_host_rsa_key.pub"
      "/etc/ssh/ssh_host_ed25519_key"
      "/etc/ssh/ssh_host_ed25519_key.pub"
    ];
  };

  # sops loads before impermanence mounts are
  sops.age.keyFile = lib.mkForce "/persist/var/lib/sops-nix/key.txt";

  fileSystems."/persist".neededForBoot = true;

  # Reset root on every boot
  boot.supportedFilesystems = [
    "btrfs"
    "udf"
  ];

  boot.initrd.systemd = {
    enable = true;
    services.impermanence-root = {
      wantedBy = [ "initrd.target" ];
      after = [ "systemd-udev-settle.service" ];
      before = [ "sysroot.mount" ];
      unitConfig.DefaultDependencies = "no";
      serviceConfig = {
        Type = "oneshot";
      };
      script = ''
        ${pkgs.coreutils}/bin/mkdir -p /btrfs-root
        ${pkgs.util-linux}/bin/mount -t btrfs -o subvolid=5 /dev/disk/by-partlabel/disk-root-root /btrfs-root

        delete_subvolume_recursively() {
          path="$1"
          subvolumes=$(${pkgs.btrfs-progs}/bin/btrfs subvolume list -o "$path" | ${pkgs.coreutils}/bin/cut -f 9- -d ' ')
          for nested in $subvolumes; do
            delete_subvolume_recursively "/btrfs-root/$nested"
          done
          ${pkgs.btrfs-progs}/bin/btrfs subvolume delete "$path"
        }

        if [ -e /btrfs-root/root ]; then
          delete_subvolume_recursively /btrfs-root/root
        fi

        ${pkgs.btrfs-progs}/bin/btrfs subvolume create /btrfs-root/root
        ${pkgs.util-linux}/bin/umount /btrfs-root
      '';
    };
  };
  boot.initrd.kernelModules = [ "btrfs" ];

  #boot.lanzaboote = {
  #  enable = true;
  #  pkiBundle = "/persist/var/lib/sbctl";
  #};
  environment.systemPackages = with pkgs; [
    sbctl # for lanzaboote
  ];
  #boot.loader.systemd-boot.enable = lib.mkForce false;
  #boot.loader.efi.canTouchEfiVariables = false;
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  nixpkgs.hostPlatform = "x86_64-linux";
  system.stateVersion = "25.11";
}
