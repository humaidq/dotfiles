{
  self,
  inputs,
  pkgs,
  vars,
  config,
  ...
}:
{
  imports = [
    self.nixosModules.sifrOS
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
      work = true;
    };
    security = {
      yubikey = true;
      # encryptDNS = true;
    };
    hasGadgetSecrets = true;
    development.enable = true;
    ntp.useNTS = true;
    o11y.client.enable = true;
    applications.emacs.enable = true;
    applications.amateur.enable = true;
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
    };
  };

  # Extra programs
  environment.systemPackages = with pkgs; [
    texliveFull
    fractal
    tuba
  ];

  boot.loader = {
    systemd-boot = {
      enable = true;
      consoleMode = "auto";
    };

    efi.canTouchEfiVariables = true;
  };
  topology.self = {
    hardware.info = "Lenovo ThinkPad T590";
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
        maxJobs = 8;
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
  hardware.keyboard.zsa.enable = true;
  boot.kernelPackages = pkgs.linuxKernel.packages.linux_6_13;
  #environment.memoryAllocator.provider = "graphene-hardened";

  home-manager.users."${vars.user}" = {
    services.kanshi = {
      enable = false;

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

  nixpkgs.hostPlatform = "x86_64-linux";
  system.stateVersion = "23.11";
}
