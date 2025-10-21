{
  self,
  inputs,
  pkgs,
  vars,
  lib,
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
  networking.hostName = "caprini";

  # Nebula keys
  #sops.secrets."nebula/crt" = {
  #  sopsFile = ../../secrets/serow.yaml;
  #  owner = "nebula-sifr0";
  #  mode = "600";
  #};
  #sops.secrets."nebula/key" = {
  #  sopsFile = ../../secrets/serow.yaml;
  #  owner = "nebula-sifr0";
  #  mode = "600";
  #};
  #sops.secrets."nebula/ssh_host_key" = {
  #  sopsFile = ../../secrets/serow.yaml;
  #  owner = "nebula-sifr0";
  #  mode = "600";
  #};
  services.upower.ignoreLid = true;
  # My configuration specific settings
  sifr = {
    graphics = {
      gnome.enable = true;
      sway.enable = true;
      apps = true;
    };
    profiles = {
      basePlus = true;
      laptop = true;
      #work = true;
      #security-research = true;
      #research = true;
    };
    security = {
      yubikey = true;
      encryptDNS = false;
    };
    #hasGadgetSecrets = true;
    development.enable = true;
    ntp.useNTS = true;
    o11y.client.enable = true;
    applications.emacs.enable = true;
    #applications.amateur.enable = true;
    #v12n.emulation = {
    #  enable = true;
    #  systems = [
    #    "aarch64-linux"
    #    "riscv64-linux"
    #  ];
    #};

    tailscale = {
      enable = true;
      ssh = true;
      auth = false;
    };
    #net = {
    #  sifr0 = false;
    #  node-crt = config.sops.secrets."nebula/crt".path;
    #  node-key = config.sops.secrets."nebula/key".path;
    #  ssh-host-key = config.sops.secrets."nebula/ssh_host_key".path;
    #};
  };

  #nix.settings = {
  #  trusted-substituters = [
  #    "ssh://humaid@oreamnos"
  #  ];
  #  substituters = [
  #    "ssh://humaid@oreamnos"
  #  ];
  #};

  hardware.keyboard.zsa.enable = true;
  environment.systemPackages = with pkgs; [
    vscode
    sbctl # for lanzaboote
  ];

  nixpkgs.config.android_sdk.accept_license = true;

  boot.loader = {
    systemd-boot = {
      enable = true;
      consoleMode = "auto";
    };

    efi.canTouchEfiVariables = true;
  };
  topology.self = {
    hardware.info = "Lenovo ThinkPad X1 Carbon Gen 13";
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
        ".config/google-chrome"
        ".local/share/direnv"
        ".config/sops"
        ".config/emacs"
        ".config/doom"
        ".config/zsh_history"
        ".config/Code"
        ".local/share/fish"
        ".local/share/zsh"
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
      device = "/dev/zvol/root/swap";
    }
  ];
  #boot.loader.systemd-boot.enable = lib.mkForce false;

  #boot.lanzaboote = {
  #  enable = true;
  #  pkiBundle = "/persist/var/lib/sbctl";
  #};

  users.users.${vars.user} = {
    isNormalUser = true;
    hashedPassword = "$6$67sQfb8Pm3Jyvdvo$OPXnLbgHCdoRfhlhhz/pygvJ32ZA.L0HifV.fBSVW47SsfKK6xiroi/Xx.hcB6YJ94XXaiUH5zqDvnAmKq6gE1";
    hashedPasswordFile = lib.mkForce null;
  };

  nix = {
    buildMachines = [
      {
        hostName = "oreamnos";
        system = "x86_64-linux";
        maxJobs = 32;
        speedFactor = 1;
        supportedFeatures = [
          "nixos-test"
          "benchmark"
          "big-parallel"
          "kvm"
        ];
        mandatoryFeatures = [ ];
        sshUser = "humaid";
        sshKey = "/home/humaid/.ssh/id_ed25519_build";
      }
    ];

    distributedBuilds = true;
  };

  programs.ssh = {
    extraConfig = ''
      Host oreamnos
           user humaid
           IdentityFile /home/humaid/.ssh/id_ed25519_build
    '';

    knownHosts = {
      oreamnos = {
        hostNames = [
          "oreamnos"
          "100.83.164.46"
          "10.10.0.12"
          "oreamnos.barred-banana.ts.net"
        ];
        publicKey = "oreamnos ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHnC2ZPG75+HmEpS6OYpYU4OG6G8rwiEKDNXudtTAr0u";
      };
    };
  };

  # receipt printer
  users.groups.escpos = { };
  users.users.humaid.extraGroups = [ "escpos" ];
  services.udev.extraRules = ''
    # Rongta receipt printer via ICS Advent Parallel Adapter
    # Vendor 0xfe6  Product 0x811e
    SUBSYSTEM=="usb", ATTRS{idVendor}=="0fe6", ATTRS{idProduct}=="811e", \
        MODE="0664", GROUP="escpos"
  '';

  #boot.kernelPackages = pkgs.linuxPackages_6_17;
  nixpkgs.hostPlatform = "x86_64-linux";
  system.stateVersion = "25.05";
}
