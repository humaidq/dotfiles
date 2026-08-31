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
    self.nixosModules.sifrOS.base
    self.nixosModules.sifrOS.personal.base
    self.nixosModules.sifrOS.security
    self.nixosModules.sifrOS.persist
    self.nixosModules.sifrOS.server
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
  # ntfy's publish token for the `grafana` account, read back out of this path
  # by the ntfy contact point in modules/personal/o11y/alerting/contactPoints.yaml
  # with Grafana's $__file{} expander. It is declared here rather than beside
  # the server's own secret in modules/home-server/ntfy.nix because it is the
  # only one of the pair that has to be owned by grafana, and this is the host
  # where sifr.home-server and sifr.personal.o11y.server are both on — a host
  # with one and not the other has no user of that name to give it to.
  #
  # The token itself lives in secrets/home-server.yaml next to NTFY_AUTH_TOKENS,
  # so the two halves are edited together and cannot drift apart.
  sops.secrets."ntfy/grafana-token" = {
    sopsFile = ../../secrets/home-server.yaml;
    owner = "grafana";
    mode = "600";
  };

  # My configuration specific settings
  sifr = {
    basePlus.enable = true;
    personal = {
      ssh.acceptDevKeys = true;
      ntp.useNTS = false;
      o11y = {
        server.enable = true;
        client.enable = true;
      };
      # This is the host nginx already proxies sdr.alq.ae from, so it is the one
      # that can reach the receiver on the LAN without leaving the building.
      sdrNoise.enable = true;
      net = {
        sifr0 = true;
        node-crt = config.sops.secrets."nebula/crt".path;
        node-key = config.sops.secrets."nebula/key".path;
      };
      work.enable = true;
      moshi.enable = true;
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
    applications.emacs.enable = true;
    autoupgrade.enable = true;

    hasGadgetSecrets = true;
    home-server.enable = true;
    home-server.unifi = {
      enable = true;
      # This host's address on bongo's LAN, which is where the access points
      # are. Same address bongo hands out for alq.ae.
      informAddress = "10.20.0.250";
    };

    v12n.docker.enable = true;
    persist = {
      enable = true;
      zfs = {
        enable = true;
        root = "rpool/root";
      };
      dirs = [
        {
          directory = "/var/lib/immich";
          user = "immich";
          mode = "0700";
        }
        {
          directory = "/var/lib/groundwave";
          user = "groundwave";
          mode = "0700";
        }
        {
          directory = "/var/lib/fleeti";
          user = "fleeti-service";
          mode = "0700";
        }
        # Holds the SQLite database: accounts, per-user progress and the
        # leaderboard. Nothing reconstructs it, so it does not survive a
        # rollback without being named here.
        {
          directory = "/var/lib/debug-platform";
          user = "debug-platform";
          mode = "0700";
        }
        # The SQLite index of every page hister has seen, plus .secret_key,
        # which every session cookie is signed with. Rebuilding the index
        # means re-crawling the lot, and there is nothing to re-crawl from
        # once the history is gone.
        {
          directory = "/var/lib/hister";
          user = "hister";
          group = "hister";
          mode = "0750";
        }
        # ntfy's message cache and its user database. The accounts are
        # provisioned from a secret and come back on their own, but the cache
        # is the 48h of published messages a phone that has been away asks for
        # when it reconnects — wiped on a rollback, those alerts are never
        # delivered and nothing says so.
        {
          directory = "/var/lib/ntfy-sh";
          user = "ntfy-sh";
          group = "ntfy-sh";
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
        {
          directory = "/var/lib/redis-immich";
          user = "immich";
          mode = "0740";
        }
        {
          directory = "/var/lib/forgejo";
          user = "forgejo";
          group = "forgejo";
          mode = "0770";
        }
        # Matomo's data directory, which holds config.ini.php — the database
        # credentials and, more importantly, the instance salt. Losing it means
        # a database full of visits that the new install cannot read.
        #
        # 0770 rather than 0700 because the module deliberately runs the data
        # directory as a user-private group: everything is group-writable and
        # setgid so that a member of `matomo` can administer or back it up
        # without being root. It sets the setgid bit itself on every start.
        {
          directory = "/var/lib/matomo";
          user = "matomo";
          group = "matomo";
          mode = "0770";
        }
        # MariaDB, here only because Matomo supports no other backend. 0755 is
        # what the mysql module's own tmpfiles rule sets, and a narrower mode
        # here would just be widened again on activation.
        {
          directory = "/var/lib/mysql";
          user = "mysql";
          group = "mysql";
          mode = "0755";
        }
        "/var/lib/postgresql"
        "/var/lib/caddy"
        {
          directory = "/var/lib/bitwarden_rs";
          mode = "0700";
          user = "vaultwarden";
        }
      ];
      user = {
        enable = true;
        files = [
          ".claude.json"
        ];
        dirs = [
          ".local/share/direnv"
          ".config/emacs"
          ".config/doom"
          ".local/share/zsh"
          ".claude"
          ".codex"
          ".local/state/moshi"
        ];
      };
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
      # moshi
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMfg4FZDzoq/6FKX2PP6ye7QHKVxQWjUqTcQQvpsjyyi moshi"
    ];
  };

  networking.firewall.allowedTCPPorts = [
    5000
    22
    2222
    3300
    80
    443
  ];
  networking.firewall.allowedUDPPorts = [
    123
    22
    2222
  ];

  services.chrony.extraConfig = lib.mkAfter ''
    server 10.20.0.146 iburst
    allow all
  '';

  systemd.enableEmergencyMode = false;

  fileSystems."/persist-svc".neededForBoot = true;

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
      # Allow hisn access. These match on the name in the peer's Nebula
      # certificate, not on an address, so taking over the overlay role of the
      # host hisn replaced is not enough — without these four its reverse
      # proxy reaches this host and is refused, and cache.huma.id, the
      # groundwave vhosts, admin.fleeti.ae and tii-debug-platform.huma.id all
      # return 502.
      {
        host = "hisn";
        port = "5000"; # nix cache
        proto = "tcp";
      }
      {
        host = "hisn";
        port = "4232"; # groundwave
        proto = "tcp";
      }
      {
        host = "hisn";
        port = "4231"; # fleeti
        proto = "tcp";
      }
      {
        host = "hisn";
        port = "4233"; # debug-platform
        proto = "tcp";
      }
    ];
  };

  nixpkgs.hostPlatform = "x86_64-linux";
  system.stateVersion = "24.05";
}
