{
  inputs,
  lib,
  self,
  pkgs,
  vars,
  config,
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

  # Nebula keys
  sops.secrets."nebula/crt" = {
    sopsFile = ../../secrets/oreamnos.yaml;
    owner = "nebula-sifr0";
    mode = "600";
  };
  sops.secrets."nebula/key" = {
    sopsFile = ../../secrets/oreamnos.yaml;
    owner = "nebula-sifr0";
    mode = "600";
  };

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
    security.yubikey = true;
    development.enable = true;
    ntp.useNTS = false;
    applications.emacs.enable = true;

    o11y = {
      server.enable = true;
      client.enable = true;
    };

    hasGadgetSecrets = true;
    home-server.enable = true;

    net = {
      sifr0 = true;
      node-crt = config.sops.secrets."nebula/crt".path;
      node-key = config.sops.secrets."nebula/key".path;
    };
    tailscale = {
      enable = true;
      exitNode = true;
      ssh = true;
      auth = false;
    };
  };

  environment.systemPackages = with pkgs; [
    cifs-utils
    liquidctl
    restic
  ];

  systemd.services.liquidctl = {
    enable = true;
    description = "CPU Cooler";
    serviceConfig = {
      Type = "oneshot";
      ExecStart =
        let
          liquidctl = lib.getExe pkgs.liquidctl;
        in
        [
          "${liquidctl} initialize all"
          "${liquidctl} --match Kraken set fan speed 20 45 35 50 40 75 80 90 50 100"
          "${liquidctl} --match Kraken set pump speed 70"
        ];
    };
    wantedBy = [ "multi-user.target" ];
  };

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
  zramSwap.enable = true;

  services.fwupd.enable = true;
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
      # pixel
      "sk-ecdsa-sha2-nistp256@openssh.com AAAAInNrLWVjZHNhLXNoYTItbmlzdHAyNTZAb3BlbnNzaC5jb20AAAAIbmlzdHAyNTYAAABBBFp9iH7iZI8NyYsRr8pV0n7BxYCPMvB1iGSfrVlLieIkRtMZi6T7VfzhNNz9HyppgFEyl2Y1d3RwIbxgFnY7XxwAAAALdGVybWl1cy5jb20="

      # root serow (buildmachine)
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJFhlcX+CiEb8q/NSuy9vOtu5RwFfUGui773wcWWgkf1 root@serow"
    ];
  };

  networking.firewall.allowedTCPPorts = [
    5000
    22
    2222
    80
    443
    53
  ];
  networking.firewall.allowedUDPPorts = [
    123
    22
    2222
    53
  ];

  services.chrony.extraConfig = lib.mkAfter ''
    allow all
  '';

  systemd.enableEmergencyMode = false;

  #environment.persistence."/persist-svc" = {
  #  hideMounts = true;
  #  directories = [
  #    {
  #      directory = "/var/lib/immich";
  #      user = "immich";
  #      mode = "0700";
  #    }
  #  ];
  #};

  # impermanence setup
  environment.persistence."/persist" = {
    hideMounts = true;
    directories = [
      "/var/log"
      "/var/lib/nixos"
      "/var/lib/systemd/coredump"
      "/var/lib/sops-nix"
      #"/var/lib/ollama"
      {
        directory = "/var/lib/immich";
        user = "immich";
        mode = "0700";
      }
      "/var/lib/chrony"
      "/var/lib/tailscale"
      "/var/lib/grafana"
      {
        directory = "/var/lib/seafile";
        user = "seafile";
        mode = "0700";
      }
      {
        directory = "/var/lib/radicale";
        user = "radicale";
        mode = "0700";
      }
      {
        directory = "/var/lib/hydra";
        user = "hydra";
        mode = "0700";
      }
      "/var/lib/loki"
      "/var/lib/prometheus2"
      {
        directory = "/var/lib/redis-authentik";
        user = "redis-authentik";
        mode = "0740";
      }
      {
        directory = "/var/lib/redis-paperless";
        user = "redis-paperless";
        mode = "0740";
      }
      {
        directory = "/var/lib/redis-immich";
        user = "immich";
        mode = "0740";
      }

      "/var/lib/dokuwiki"
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
      {
        directory = "/var/lib/forgejo";
        user = "forgejo";
        group = "forgejo";
        mode = "0770";
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
  fileSystems."/persist-svc".neededForBoot = true;

  # Reset root on every boot
  boot.supportedFilesystems = [ "zfs" ];

  boot.initrd.systemd = {
    enable = true;
    services = {
      "zfs-import-rpool".after = [ "cryptsetup.target" ];
      impermanence-root = {
        wantedBy = [ "initrd.target" ];
        after = [ "zfs-import-rpool.service" ];
        before = [ "sysroot.mount" ];
        unitConfig.DefaultDependencies = "no";
        serviceConfig = {
          Type = "oneshot";
          ExecStart = "${pkgs.zfs}/bin/zfs rollback -r rpool/root@blank";
        };
      };
    };
  };

  swapDevices = [
    {
      device = "/dev/zvol/rpool/swap";
    }
  ];

  security.pam.loginLimits = [
    {
      domain = "*";
      type = "-";
      item = "nofile";
      value = "9192";
    }
  ];

  services.iperf3 = {
    enable = true;
    openFirewall = true;
  };

  services.zfs.autoScrub = {
    enable = true;
    interval = "weekly";
    pools = [ "dpool" ];
  };

  services.nebula.networks.sifr0.firewall = {
    inbound = [
      # Allow SSH from all on this host
      {
        host = "any";
        port = "22";
        proto = "tcp";
      }
      # Time Server
      {
        host = "any";
        port = "123";
        proto = "udp";
      }
      # DNS
      {
        host = "any";
        port = "53";
        proto = "udp";
      }
      # Forgejo SSH
      {
        host = "any";
        port = "2222";
        proto = "any";
      }
      # Grafana
      {
        host = "any";
        port = "9001";
        proto = "any";
      }
      {
        host = "any";
        port = "3100";
        proto = "any";
      }
      {
        host = "any";
        port = "3000";
        proto = "any";
      }
    ];
  };

  nixpkgs.hostPlatform = "x86_64-linux";
  system.stateVersion = "24.05";
}
