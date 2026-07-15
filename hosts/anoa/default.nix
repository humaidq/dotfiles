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
  networking.hostId = "616e6f61";

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
  sops.secrets."netrc" = {
    sopsFile = ../../secrets/anoa.yaml;
    path = "/home/humaid/.netrc";
    owner = "humaid";
    mode = "0400";
  };

  services.upower.ignoreLid = true;

  users.users.${vars.user}.openssh.authorizedKeys.keys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMYrVNuxuD0F8VJr5AYlhMYEHZui4ANt3AfFJIYejRK4 moshi"
  ];

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
      moshi.enable = true;
      amateur.enable = true;
      dns.enable = true;
      research.enable = true;
      securityResearch.enable = true;
      work.enable = true;
      university.enable = true;
      tailscale.enable = true;
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
        files = [
          ".claude.json"
        ];
        dirs = [
          ".claude"
          ".xwechat"
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
          ".local/state/moshi"
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
        systems = [
          "x86_64-linux"
          "aarch64-linux"
        ];
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

  hardware.keyboard.zsa.enable = true;

  boot.kernelParams = [
    # Cap ZFS ARC at 4 GiB (was 8). On a 30 GiB interactive laptop running
    # browsers, postgres and qemu emulation, a smaller ARC leaves more baseline
    # headroom and reduces how often we reach for swap at all. ARC reclaim under
    # pressure is laggy, so a lower cap is worth the slightly smaller file cache.
    "zfs.zfs_arc_max=4294967296"
  ];

  # will do manually, too resource intensive.
  services.zfs.trim.enable = false;

  # Memory-pressure handling. anoa used to freeze under load (load avg >20, Sway
  # unresponsive, sometimes needing a hard reset). Root cause was memory thrash,
  # NOT the CPU scheduler: swap lived on a ZFS zvol, and swapping to a zvol under
  # pressure is a known OpenZFS deadlock (ZFS must allocate memory to service the
  # swap I/O). Processes pile up in D state, so load spikes from I/O stall rather
  # than CPU demand.
  #
  # Fix: zram (compressed RAM) becomes primary swap, the ZFS zvol is demoted to a
  # last-resort overflow, and systemd-oomd kills a runaway app before lockup.
  zramSwap = {
    enable = true;
    algorithm = "zstd";
    memoryPercent = 50;
    priority = 100;
  };

  swapDevices = [
    {
      device = "/dev/zvol/rpool/enc/swap";
      # Below zram (100); only touched when zram is exhausted.
      priority = -2;
    }
  ];

  # zram is cheap, so lean on it instead of evicting page cache, and disable swap
  # read-ahead (pointless for RAM-backed swap).
  boot.kernel.sysctl = {
    "vm.swappiness" = 180;
    "vm.page-cluster" = 0;
    "vm.watermark_boost_factor" = 0;
    "vm.watermark_scale_factor" = 125;
  };

  # Kill the heaviest cgroup (e.g. a runaway browser tab in the user session)
  # before memory pressure stalls the whole machine. enableUserSlices is the key
  # bit: that's where the desktop apps live.
  systemd.oomd = {
    enable = true;
    enableUserSlices = true;
    enableRootSlice = true;
    settings.OOM = {
      DefaultMemoryPressureLimit = "50%";
      DefaultMemoryPressureDurationSec = "10s";
    };
  };

  boot.lanzaboote = {
    enable = true;
    pkiBundle = "/persist/var/lib/sbctl";
  };
  environment.systemPackages = with pkgs; [
    sbctl # for lanzaboote
    asdbctl # apple studio display
    intel-gpu-tools
  ];

  # Intel VAAPI hardware video decode (iHD/intel-media-driver) so browsers
  # and mpv offload video off the CPU, saving battery and heat.
  hardware.graphics.extraPackages = with pkgs; [ intel-media-driver ];
  environment.sessionVariables.LIBVA_DRIVER_NAME = "iHD";
  boot.loader.systemd-boot.enable = lib.mkForce false;
  boot.loader.efi.canTouchEfiVariables = false;
  services.hardware.bolt.enable = true;

  services.postgresql = {
    enable = true;
    extensions =
      ps: with ps; [
        postgis
        pgvector
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

  networking.firewall.allowedTCPPorts = [
    8081
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
            # Both Studio Display ports share the identical description
            # "Apple Computer Inc StudioDisplay 0x6EBF361E", so kanshi can only
            # tell DP-1 (the real 5K panel) from DP-2 by connector name. Match
            # every output by connector here, otherwise no profile matches and
            # the internal panel stays on.
            outputs = [
              {
                criteria = "eDP-1";
                status = "disable";
              }
              {
                criteria = "DP-1";
                status = "enable";
                mode = "5120x2880";
                scale = 2.0;
                position = "0,0";
              }
              {
                criteria = "DP-2";
                status = "disable";
              }
            ];
            exec = [
              ''${pkgs.sway}/bin/swaymsg "workspace 1, move workspace to output DP-1"''
              ''${pkgs.sway}/bin/swaymsg "workspace 2, move workspace to output DP-1"''
              ''${pkgs.sway}/bin/swaymsg "workspace 3, move workspace to output DP-1"''
              ''${pkgs.sway}/bin/swaymsg "workspace 4, move workspace to output DP-1"''
              ''${pkgs.sway}/bin/swaymsg "workspace 5, move workspace to output DP-1"''
              ''${pkgs.sway}/bin/swaymsg "workspace 6, move workspace to output DP-1"''
              ''${pkgs.sway}/bin/swaymsg "workspace 7, move workspace to output DP-1"''
              ''${pkgs.sway}/bin/swaymsg "workspace 8, move workspace to output DP-1"''
              ''${pkgs.sway}/bin/swaymsg "workspace 9, move workspace to output DP-1"''
              ''${pkgs.sway}/bin/swaymsg "workspace 10, move workspace to output DP-1"''
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
        {
          profile = {
            name = "tii-crc-desk";
            outputs = [
              {
                criteria = "Dell Inc. DELL U3423WE DYQKMP3";
                status = "enable";
                mode = "3440x1440@60Hz";
                scale = 2.0;
                position = "0,0";
              }
              {
                criteria = "Samsung Display Corp. 0x419F Unknown";
                status = "enable";
                mode = "2880x1800@120Hz";
                scale = 2.0;
                position = "140,720";
              }
            ];
          };
        }
      ];
    };
  };

  system.stateVersion = "25.04";
}
