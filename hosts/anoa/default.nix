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
    self.nixosModules.sifrOS
    inputs.nixos-hardware.nixosModules.lenovo-thinkpad-x1-13th-gen
    inputs.impermanence.nixosModules.impermanence
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

  services.upower.ignoreLid = true;
  sifr = {
    graphics = {
      #gnome.enable = true;
      sway.enable = true;
      labwc.enable = true;
      apps = true;
      berkeley.enable = true;
    };
    profiles = {
      basePlus = true;
      laptop = true;
      work = true;
      security-research = true;
      research = true;
      university = true;
      receipt = true;
    };
    security = {
      yubikey = true;
      encryptDNS = true;
    };
    hasGadgetSecrets = true;
    development.enable = true;
    ntp.useNTS = true;
    o11y.client.enable = true;
    applications.emacs.enable = true;
    applications.amateur.enable = true;
    applications.chromium.enable = true;
    v12n.emulation = {
      enable = true;
      systems = [
        "aarch64-linux"
        "riscv64-linux"
      ];
    };

    tailscale = {
      enable = true;
      ssh = true;
      auth = false;
    };
    net = {
      sifr0 = true;
      node-crt = config.sops.secrets."nebula/crt".path;
      node-key = config.sops.secrets."nebula/key".path;
      ssh-host-key = config.sops.secrets."nebula/ssh_host_key".path;
    };
    backups = {
      enable = true;
      sshKeyPath = config.sops.secrets."borg/ssh_key".path;
    };
  };

  topology.self = {
    hardware.info = "Lenovo ThinkPad X1 Carbon Gen 13";
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

  # impermanence setup
  environment.persistence."/persist" = {
    hideMounts = true;
    directories = [
      "/var/log"
      "/var/lib/nixos"
      "/var/lib/bluetooth"
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
    users."${vars.user}" = {
      files = [
        #".claude.json" #symlink gets overridden :/
      ];
      directories = [
        "inbox"
        "repos"
        "docs"
        {
          directory = ".ssh";
          mode = "0700";
        }
        ".mozilla"
        ".tqsl"
        ".codex"
        ".config/google-chrome"
        ".local/share/direnv"
        ".config/sops"
        ".config/emacs"
        ".config/doom"
        ".config/zsh_history"
        ".config/Code"
        ".config/github-copilot"
        ".config/hamradio" # qlog
        ".local/share/WSJT-X"
        ".local/share/hamradio/QLog"
        ".local/share/fish"
        ".local/share/zsh"
        ".local/share/keyrings"
        ".local/share/fonts"
        ".zotero"
        ".vscode"
        ".claude"
        ".aider"
      ];
    };
  };

  # sops loads before impermanence mounts are
  sops.age.keyFile = lib.mkForce "/persist/var/lib/sops-nix/key.txt";

  fileSystems."/persist".neededForBoot = true;

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
          ExecStart = "${pkgs.zfs}/bin/zfs rollback -r rpool/enc/root@blank";
        };
      };
    };
  };

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
  ];
  boot.loader.systemd-boot.enable = lib.mkForce false;
  boot.loader.efi.canTouchEfiVariables = false;
  services.hardware.bolt.enable = true;

  services.usbguard = {
    enable = false;
    dbus.enable = true; # for gnome
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

  home-manager.users."${vars.user}" = {
    services.kanshi = {
      inherit (config.sifr.graphics.sway) enable;

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
      ];
    };
  };

  system.stateVersion = "25.04";
}
