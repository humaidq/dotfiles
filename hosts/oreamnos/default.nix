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
  sops.secrets."smtp/oreamnos_pass" = {
    sopsFile = ../../secrets/oreamnos.yaml;
    owner = "grafana"; # used also by zfs/smartd but those are root
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
    autoupgrade.enable = true;

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
    nvme-cli
    liquidctl
    restic
  ];

  nix.settings = {
    cores = 32;
    #max-jobs = 6;
  };

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

  security.sudo-rs.wheelNeedsPassword = false;
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
      # anoa borg ssh
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIATG8oK3/+6po+IHhKj/Dx++qUNEPSnLNY5mj+hvmtrE humaid@caprini"
    ];
  };

  networking.firewall.allowedTCPPorts = [
    5000
    22
    2222
    3300
    80
    443
    53
    # dns over https
    3333
  ];
  networking.firewall.allowedUDPPorts = [
    123
    22
    2222
    53
  ];

  services.chrony.extraConfig = lib.mkAfter ''
    server 192.168.1.146 iburst
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
      {
        directory = "/var/lib/immich";
        user = "immich";
        mode = "0700";
      }
      "/var/lib/chrony"
      "/var/lib/tailscale"
      "/var/lib/grafana"
      "/var/lib/dokuwiki"
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
        directory = "/var/lib/redis-immich";
        user = "immich";
        mode = "0740";
      }
      {
        directory = "/var/lib/private";
        mode = "0700";
      }
      "/var/lib/radarr"
      "/var/lib/sonarr"
      {
        directory = "/var/lib/forgejo";
        user = "forgejo";
        group = "forgejo";
        mode = "0770";
      }
      "/var/lib/postgresql"
      {
        directory = "/var/lib/jellyfin";
        user = "jellyfin";
        mode = "0700";
      }
      "/var/lib/deluge"
      "/var/lib/caddy"
      "/var/lib/uptimed"
      "/var/lib/unifi"
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
        ".config/zsh_history"
        ".local/share/fish"
        ".local/share/zsh"
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

  # Full performance for this system
  powerManagement.cpuFreqGovernor = "performance";
  # Fix ATA errors caused by power management policy "med_power_with_dipm"
  powerManagement.scsiLinkPolicy = "max_performance";
  boot.kernelParams = [
    # belts & braces for the ATA errors
    "ahci.mobile_lpm_policy=1"
    # Disable kernel-managed PCIe power management
    "pcie_aspm=off"
    # Disable USB auto suspend
    "usbcore.autosuspend=-1"
  ];

  programs.msmtp = {
    enable = true;
    setSendmail = true;
    defaults = {
      auth = true;
      tls = true;
      tls_starttls = true;
    };
    accounts.default = {
      host = "smtp.migadu.com";
      port = 587;
      from = "oreamnos@alq.ae";
      user = "oreamnos@alq.ae";
      passwordeval = "${lib.getExe' pkgs.coreutils "cat"} ${
        config.sops.secrets."smtp/oreamnos_pass".path
      }";
    };
  };
  services.zfs.zed = {
    enableMail = true;
    settings = {
      ZED_EMAIL_ADDR = [ "me.alerts@huma.id" ];
      ZED_EMAIL_PROG = "${pkgs.msmtp}/bin/msmtp";
      ZED_EMAIL_OPTS = "@ADDRESS@";

      ZED_NOTIFY_INTERVAL_SECS = 3600;
      ZED_NOTIFY_VERBOSE = true;
    };
  };
  services.smartd = {
    enable = true;
    autodetect = true;

    notifications = {
      mail = {
        enable = true;
        recipient = "me.alerts@huma.id";
        sender = "oreamnos@alq.ae";
        mailer = lib.getExe pkgs.msmtp;
      };
      wall.enable = false;
      x11.enable = false;
    };
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
      # DNS over https
      {
        host = "any";
        port = "3333";
        proto = "any";
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
      {
        host = "any";
        port = "80";
        proto = "tcp";
      }
      {
        host = "serow";
        port = "3389";
        proto = "tcp";
      }
      {
        host = "serow";
        port = "3389";
        proto = "udp";
      }
      # Allow duisk access
      {
        host = "duisk";
        port = "5000"; # nix cache
        proto = "tcp";
      }
    ];
  };

  nixpkgs.hostPlatform = "x86_64-linux";
  system.stateVersion = "24.05";
}
