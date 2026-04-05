{
  self,
  inputs,
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
    inputs.nixos-hardware.nixosModules.lenovo-thinkpad-t590
    (import ./hardware.nix)
  ];
  networking.hostName = "serow";

  # Nebula keys
  sops.secrets."nebula/crt" = {
    sopsFile = ../../secrets/serow.yaml;
    owner = "nebula-sifr0";
    mode = "600";
  };
  sops.secrets."nebula/key" = {
    sopsFile = ../../secrets/serow.yaml;
    owner = "nebula-sifr0";
    mode = "600";
  };
  #sops.secrets."nebula/ssh_host_key" = {
  #  sopsFile = ../../secrets/serow.yaml;
  #  owner = "nebula-sifr0";
  #  mode = "600";
  #};
  #sops.secrets."usbguard/rules" = {
  #  sopsFile = ../../secrets/serow.yaml;
  #  owner = "root";
  #  mode = "600";
  #};

  services.upower.ignoreLid = true;
  # My configuration specific settings
  sifr = {
    desktop = {
      sway.enable = true;
      apps = true;
    };
    security = {
      yubikey = true;
    };
    hasGadgetSecrets = true;
    development.enable = true;
    basePlus.enable = true;
    personal = {
      amateur.enable = true;
      dns.enable = true;
      ntp.useNTS = true;
      o11y.client.enable = true;
      receipt.enable = true;
      research.enable = true;
      securityResearch.enable = true;
      work.enable = true;
      university.enable = true;
      net = {
        sifr0 = true;
        node-crt = config.sops.secrets."nebula/crt".path;
        node-key = config.sops.secrets."nebula/key".path;
      };
    };
    applications.emacs.enable = true;
    v12n.emulation = {
      enable = true;
      systems = [
        "aarch64-linux"
        "riscv64-linux"
      ];
    };

  };

  #nix.settings = {
  #  trusted-substituters = [
  #    "ssh://humaid@oreamnos"
  #  ];
  #  substituters = [
  #    "ssh://humaid@oreamnos"
  #  ];
  #};

  boot.loader = {
    systemd-boot = {
      enable = true;
      consoleMode = "auto";
    };

    efi.canTouchEfiVariables = true;
  };
  swapDevices = [
    {
      device = "/swap";
      size = 32 * 1024;
    }
  ];

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

  #programs.ssh = {
  #  extraConfig = ''
  #    Host oreamnos
  #         user humaid
  #         IdentityFile /home/humaid/.ssh/id_ed25519_build
  #  '';
  #};

  home-manager.users."${vars.user}" = {
    services.kanshi = {
      inherit (config.sifr.desktop.sway) enable;

      settings = [
        {
          profile = {
            name = "internal";
            outputs = [
              {
                criteria = "Lenovo Group Limited 0x40BA Unknown";
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
                criteria = "Lenovo Group Limited 0x40BA Unknown";
                status = "disable";
              }
              {
                criteria = "Apple Computer Inc StudioDisplay 0x6EBF361E";
                status = "enable";
                mode = "3840x2160";
              }
            ];
          };
        }
      ];
    };
  };

  # Laptop security
  #security.usbguard = {
  #  enable = false;
  #  ruleFile = config.sops.secrets."usbguard/rules".path;
  #};

  nixpkgs.hostPlatform = "x86_64-linux";
  system.stateVersion = "23.11";
}
