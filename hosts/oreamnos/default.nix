{
  inputs,
  lib,
  self,
  config,
  pkgs,
  vars,
  ...
}:
{
  imports = [
    self.nixosModules.sifrOS
    inputs.impermanence.nixosModules.impermanence
    inputs.disko.nixosModules.disko
    (import ./hardware.nix)
    (import ./disk.nix)
  ];
  networking.hostName = "oreamnos";
  networking.hostId = "0a65726f"; # echo ore | od -A none -t x4

  # My configuration specific settings
  sifr = {
    profiles = {
      basePlus = true;
      work = true;
    };
    v12n.emulation = {
      enable = true;
      systems = [
        "aarch64-linux"
        "riscv64-linux"
      ];
    };
    security = {
      encryptDNS = true;
    };
    development.enable = true;
    ntp.useNTS = true;
    applications.emacs.enable = true;

    o11y = {
      server.enable = true;
      client.enable = true;
    };

    home-server.enable = true;

    tailscale = {
      enable = true;
      exitNode = true;
      ssh = true;
      auth = false;
    };
  };

  environment.systemPackages = with pkgs; [ cifs-utils ];

  sops.secrets."nas/humaid" = {
    sopsFile = ../../secrets/home-server.yaml;
  };
  #fileSystems."/mnt/synology-nas" = {
  #  device = "//192.168.1.44/homes";
  #  fsType = "cifs";
  #  options = [
  #    "credentials=${config.sops.secrets."nas/humaid".path}"
  #    "dir_mode=0777,file_mode=0777,iocharset=utf8,auto"
  #  ];
  #};

  # Doing riscv64 xcomp, manually gc
  nix.gc.automatic = lib.mkForce false;

  security.sudo.wheelNeedsPassword = false;

  boot.loader = {
    systemd-boot = {
      enable = true;
      consoleMode = "auto";
    };

    efi.canTouchEfiVariables = true;
  };

  hardware = {
    graphics = {
      enable = true;
      enable32Bit = true;
    };
    nvidia = {
      open = false;
      modesetting.enable = true;
    };
  };
  services.xserver.videoDrivers = [ "nvidia" ];

  users.users.${vars.user} = {
    isNormalUser = true;
    openssh.authorizedKeys.keys = [
      "ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBP6h78HwApxcrPEothfFY1m0kLwroeQWpskYGsEVrxnXtohd+FBiWmer9zN37FtMyUI8b3y3LVouuKciYTlPKGs= ipadpro"
      "ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBD5+afJhtncZlx5HfXcrqqEDjNAmo7ZtatgM46ao+EcBg/vh8m0+aNb/ZdrBKqiCnkHOkN6R4gacWpoALgZ9BmA="
    ];
  };

  networking.firewall.allowedTCPPorts = [
    5000
    22
    80
    443
    53
  ];
  networking.firewall.allowedUDPPorts = [
    123
    22
    53
  ];

  services.chrony.extraConfig = lib.mkAfter ''
    allow all
  '';

  systemd.enableEmergencyMode = false;

  # impermanence setup
  environment.persistence."/persist" = {
    hideMounts = true;
    directories = [
      "/var/log"
      "/var/lib/nixos"
      "/var/lib/systemd/coredump"
      "/var/lib/sops-nix"
      #"/var/lib/ollama"
      "/var/lib/chrony"
      "/var/lib/tailscale"
      "/var/lib/grafana"
      {
        directory = "/var/lib/hydra";
        user = "hydra";
        mode = "0700";
      }
      "/var/lib/loki"
      "/var/lib/prometheus2"
      #"/var/lib/private/AdGuardHome"
      #"/var/lib/private/jellyseerr"
      #"/var/lib/private/lldap"
      #"/var/lib/private/mealie"
      #"/var/lib/private/prowlarr"

      {
        directory = "/var/lib/private";
        mode = "0700";
      }
      "/var/lib/radarr"
      "/var/lib/sonarr"
      {
        directory = "/var/lib/nextcloud";
        user = "nextcloud";
        mode = "0700";
      }
      "/var/lib/postgresql"
      {
        directory = "/var/lib/kavita";
        user = "kavita";
        mode = "0700";
      }
      {
        directory = "/var/lib/jellyfin";
        user = "jellyfin";
        mode = "0700";
      }
      "/var/lib/deluge"
      "/var/lib/caddy"
      "/var/lib/audiobookshelf"
      "/var/lib/uptimed"
      {
        directory = "/var/lib/bitwarden_rs";
        mode = "0700";
        user = "vaultwarden";
      }
      "/etc/NetworkManager/system-connections"
    ];
    files = [
      "/etc/machine-id"
      "/etc/ssh/ssh_host_rsa_key"
      "/etc/ssh/ssh_host_rsa_key.pub"
      "/etc/ssh/ssh_host_ed25519_key"
      "/etc/ssh/ssh_host_ed25519_key.pub"
    ];
    users."${vars.user}" = {
      directories = [
        "inbox"
        "repos"
        "tii"
        "docs"
        {
          directory = ".ssh";
          mode = "0700";
        }
        ".mozilla"
        ".local/share/direnv"
        ".config/sops"
        ".config/emacs"
        ".config/doom"
        # zsh keeps moving new file to $HISTFILE, which would break if we
        # persist only the file.
        ".config/zsh_history"
      ];
    };
  };
  # sops loads before impermanence mounts are
  sops.age.keyFile = lib.mkForce "/persist/var/lib/sops-nix/key.txt";

  fileSystems."/persist".neededForBoot = true;
  boot.kernelPackages = config.boot.zfs.package.latestCompatibleLinuxPackages;

  # Reset root on every boot
  boot.supportedFilesystems = [ "zfs" ];
  #boot.initrd.postDeviceCommands = lib.mkAfter ''
  #  zfs rollback -r rpool/root@blank
  #'';
  boot.initrd.systemd.enable = true;
  boot.initrd.systemd.services."zfs-import-rpool".after = [ "cryptsetup.target" ];

  boot.initrd.systemd.services.impermanence-root = {
    wantedBy = [ "initrd.target" ];
    after = [ "zfs-import-rpool.service" ];
    before = [ "sysroot.mount" ];
    unitConfig.DefaultDependencies = "no";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${pkgs.zfs}/bin/zfs rollback -r rpool/root@blank";
    };
  };

  services.zfs.autoScrub = {
    enable = true;
    interval = "weekly";
    pools = [ "dpool" ];
  };

  nixpkgs.hostPlatform = "x86_64-linux";
  system.stateVersion = "24.05";
}
