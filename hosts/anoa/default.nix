{
  self,
  inputs,
  lib,
  pkgs,
  vars,
  config,
  ...
}:
{
  imports = [
    self.nixosModules.sifrOS.base
    self.nixosModules.sifrOS.personal.base
    self.nixosModules.sifrOS.laptop
    self.nixosModules.sifrOS.desktop
    self.nixosModules.sifrOS.security
    self.nixosModules.sifrOS.persist
    inputs.nixos-hardware.nixosModules.lenovo-thinkpad-x1-13th-gen
    inputs.disko.nixosModules.disko
    # https://github.com/nix-community/lanzaboote/blob/master/docs/QUICK_START.md
    inputs.lanzaboote.nixosModules.lanzaboote
    (import ./hardware.nix)
    (import ./disk.nix)
  ];
  networking.hostName = "anoa";

  # Nebula keys
  sops.secrets."nebula/crt" = {
    sopsFile = ../../secrets/anoa.yaml;
    owner = "nebula-sifr0";
    mode = "600";
  };
  sops.secrets."nebula/key" = {
    sopsFile = ../../secrets/anoa.yaml;
    owner = "nebula-sifr0";
    mode = "600";
  };
  sops.secrets."nebula/ssh_host_key" = {
    sopsFile = ../../secrets/anoa.yaml;
    owner = "nebula-sifr0";
    mode = "600";
  };
  sops.secrets."usbguard/policy" = {
    sopsFile = ../../secrets/anoa.yaml;
  };
  sops.secrets."borg/ssh_key" = {
    sopsFile = ../../secrets/anoa.yaml;
  };

  sops.secrets."migadu/mehumaid-password" = {
    sopsFile = ../../secrets/anoa.yaml;
    owner = "humaid";
  };
  sops.secrets."dav/password" = {
    sopsFile = ../../secrets/anoa.yaml;
    owner = "humaid";
  };
  sops.secrets."mbzuai-calendar" = {
    sopsFile = ../../secrets/anoa.yaml;
    owner = "humaid";
  };

  services.upower.ignoreLid = true;

  sifr = {
    desktop = {
      sway.enable = true;
      enable = true;
      apps = true;
      berkeley.enable = true;
    };
    security = {
      yubikey = true;
    };
    hasGadgetSecrets = true;
    development.enable = true;
    basePlus.enable = true;
    personal = {
      ntp.useNTS = true;
      o11y.client.enable = true;
      focusMode.enable = true;
      amateur.enable = true;
      dns.enable = true;
      research.enable = true;
      securityResearch.enable = true;
      work.enable = true;
      university.enable = true;
      net = {
        sifr0 = true;
        node-crt = config.sops.secrets."nebula/crt".path;
        node-key = config.sops.secrets."nebula/key".path;
        ssh-host-key = config.sops.secrets."nebula/ssh_host_key".path;
      };
      rclone = {
        enable = true;
        remote = "oreamnos";
        remotePath = "/mnt/humaid/files";
        mountPath = "docs/files";
        sshUser = "humaid";
        sshKey = "/home/humaid/.ssh/id_ed25519_build";
      };
    };
    applications = {
      chromium.enable = true;
      emacs.enable = true;
    };
    v12n.emulation = {
      enable = true;
      systems = [
        "aarch64-linux"
        "riscv64-linux"
      ];
    };

    backups = {
      enable = true;
      sshKeyPath = config.sops.secrets."borg/ssh_key".path;
    };
    persist = {
      enable = true;
      zfs = {
        enable = true;
        root = "rpool/enc/root";
      };
      dirs = [
        "/var/lib/sbctl" # lanzaboote pki bundle
        "/etc/secureboot"
      ];
      user = {
        enable = true;
        dirs = [
          ".config/Code"
          ".config/aerc"
          ".config/chromium"
          ".config/doom"
          ".config/emacs"
          ".config/hamradio" # qlog
          ".config/opencode"
          ".config/net.imput.helium"
          ".config/PrusaSlicer"
          ".cache/rclone"
          ".local/share/WSJT-X"
          ".local/share/calendars"
          ".local/share/contacts"
          ".local/share/direnv"
          ".local/share/fonts"
          ".local/share/hamradio/QLog"
          ".local/share/keyrings"
          ".local/share/khal"
          ".local/share/vdirsyncer"
          ".local/share/zoxide"
          ".local/share/zsh"
          ".local/share/opencode"
          ".tqsl"
          ".vscode"
          ".zotero"
        ];
      };
    };
  };

  nix = {
    buildMachines = [
      {
        hostName = "oreamnos";
        system = "x86_64-linux";
        maxJobs = 64;
        speedFactor = 1;
        supportedFeatures = [
          "nixos-test"
          "benchmark"
          "big-parallel"
          "kvm"
        ];
        mandatoryFeatures = [ ];
        sshUser = "humaid";
        # Just use borg ssh key
        sshKey = config.sops.secrets."borg/ssh_key".path;
      }
    ];

    distributedBuilds = true;
  };

  # Due to kernel regressions on the xe driver, pin a known-good kernel.
  boot.kernelPackages = pkgs.linuxPackages_6_12.extend (
    _: super: {
      kernel = super.kernel.override {
        argsOverride = {
          version = "6.12.58";
          modDirVersion = "6.12.58";
          src = pkgs.fetchurl {
            url = "https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-6.12.58.tar.xz";
            sha256 = "1b0k8snqa2hhviv9imn02y6jrbbb62an3ypx8q8ai9k0cra4q72z";
          };
        };
      };
    }
  );

  boot.kernelParams = [
    "zfs.zfs_arc_max=8589934592"
    # remove when kernel is updated
    #"intel_idle.max_cstate=1"
    #"xe.enable_psr=0"
    #"xe.enable_fbc=0"
  ];

  # will do manually, too resource intensive.
  services.zfs.trim.enable = false;

  swapDevices = [
    {
      device = "/dev/zvol/rpool/enc/swap";
    }
  ];

  boot.lanzaboote = {
    enable = true;
    pkiBundle = "/persist/var/lib/sbctl";
  };
  environment.systemPackages = with pkgs; [
    sbctl # for lanzaboote
    usbguard-notifier
    asdbctl # apple studio display
    intel-gpu-tools
  ];
  boot.loader.systemd-boot.enable = lib.mkForce false;
  boot.loader.efi.canTouchEfiVariables = false;
  services.hardware.bolt.enable = true;

  services.usbguard = {
    enable = false;
    dbus.enable = true;
    IPCAllowedGroups = [ "wheel" ];
    ruleFile = config.sops.secrets."usbguard/policy".path;
  };

  #systemd.user.services.usbguard-notifier = {
  #  enable = true;
  #  wantedBy = [ "graphical-session.target" ];
  #  partOf = [ "graphical-session.target" ];
  #  wants = [ "graphical-session.target" ];
  #  after = [ "graphical-session.target" ];
  #};

  services.postgresql = {
    enable = true;
    extensions =
      ps: with ps; [
        postgis
      ];
    ensureUsers = [
      {
        name = "humaid";
        ensureClauses = {
          superuser = true;
          login = true;
          createdb = true;
        };
      }
    ];
  };

  boot.initrd.kernelModules = [
    "udf" # dvds
  ];

  home-manager.users."${vars.user}" = {
    programs = {
      vdirsyncer.enable = true;
      khard.enable = true;
      khal = {
        enable = true;
        settings = {
          default = {
            default_calendar = "06D0D330-6A15-4B40-8D25-40180AD0340A";
          };
        };
      };
      aerc.enable = true;
      aerc.extraConfig = {
        general.unsafe-accounts-conf = true;
        compose.address-book-cmd = "khard email --parsable --remove-first-line --search-in-source-files %s";
        viewer.alternatives = "text/plain,text/html";
        filters = {
          "text/plain" = "colorize";
          "text/html" = "html | colorize";
        };
      };

    };
    services.vdirsyncer = {
      enable = true;
      frequency = "hourly";
    };

    accounts.email.accounts.mehumaid = {
      aerc.enable = true;
      primary = true;
      address = "me@huma.id";
      realName = "Humaid Alqasimi";
      userName = "me@huma.id";

      imap.host = "imap.migadu.com";
      imap.port = 993;
      imap.tls.enable = true;
      imap.authentication = "plain";

      smtp.host = "smtp.migadu.com";
      smtp.port = 465;
      smtp.tls.enable = true;
      smtp.authentication = "plain";

      passwordCommand = "${pkgs.coreutils}/bin/cat ${
        config.sops.secrets."migadu/mehumaid-password".path
      }";

      aerc.extraAccounts = {
        "source-cred-cmd" = "${pkgs.coreutils}/bin/cat ${
          config.sops.secrets."migadu/mehumaid-password".path
        }";
        "outgoing-cred-cmd" = "${pkgs.coreutils}/bin/cat ${
          config.sops.secrets."migadu/mehumaid-password".path
        }";
      };
    };

    accounts.contact = {
      basePath = ".local/share/contacts";

      accounts.alq = {
        remote = {
          type = "carddav";
          url = "https://dav.alq.ae/.well-known/carddav";
          userName = "humaid";
          passwordCommand = [
            "${pkgs.coreutils}/bin/cat"
            "${config.sops.secrets."dav/password".path}"
          ];
        };

        vdirsyncer.enable = true;
        vdirsyncer.collections = [ "80ef269f-cdde-4a2f-e5b8-dd5fff1ca608" ];

        khard = {
          enable = true;
          type = "discover";
          glob = "*";
        };
      };

    };

    accounts.calendar = {
      basePath = ".local/share/calendars";

      accounts = {
        alq = {
          remote = {
            type = "caldav";
            url = "https://dav.alq.ae/.well-known/caldav";
            userName = "humaid";
            passwordCommand = [
              "${pkgs.coreutils}/bin/cat"
              "${config.sops.secrets."dav/password".path}"
            ];
          };

          vdirsyncer.enable = true;
          vdirsyncer.collections = [ "06D0D330-6A15-4B40-8D25-40180AD0340A" ];

          khal = {
            enable = true;
            type = "discover";
            glob = "*";
            addresses = [ "me@huma.id" ];
          };
        };
        uni = {
          remote.type = "http";
          vdirsyncer = {
            enable = true;
            urlCommand = [
              "cat"
              "${config.sops.secrets.mbzuai-calendar.path}"
            ];
          };

          khal = {
            enable = true;
            readOnly = true;
          };
        };
      };
    };

    services.kanshi = {
      inherit (config.sifr.desktop.sway) enable;

      settings = [
        {
          profile = {
            name = "internal";
            outputs = [
              {
                criteria = "Samsung Display Corp. 0x419F Unknown";
                status = "enable";
              }
            ];
          };
        }
        {
          profile = {
            name = "desk";
            outputs = [
              {
                criteria = "Samsung Display Corp. 0x419F Unknown";
                status = "disable";
              }
              {
                criteria = "Apple Computer Inc StudioDisplay 0x6EBF361E";
                status = "enable";
                mode = "5120x2880";
              }
            ];
          };
        }
        {
          profile = {
            name = "desk-mbzuai-a-7-11";
            outputs = [
              {
                criteria = "Samsung Display Corp. 0x419F Unknown";
                status = "disable";
              }
              {
                criteria = "Dell Inc. DELL P2725H 25FCXZ3";
                status = "enable";
                mode = "1920x1080";
              }
            ];
          };
        }
      ];
    };
  };

  system.stateVersion = "25.04";
}
