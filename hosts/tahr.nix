{
  lib,
  config,
  pkgs,
  vars,
  ...
}: {
  boot.loader = {
    systemd-boot.enable = true;
    efi.canTouchEfiVariables = true;
  };

  # Annoying Nvidia configurations
  services.xserver.videoDrivers = lib.mkForce ["nvidia"];
  hardware.opengl = {
    enable = true;
    driSupport32Bit = true;
    driSupport = true;
    extraPackages = with pkgs; [vaapiVdpau];
  };
  hardware.nvidia = {
    package = config.boot.kernelPackages.nvidiaPackages.stable;
    modesetting.enable = true;
    #nvidiaPersistenced = true;
    nvidiaSettings = true;
    prime = {
      #offload.enable = true;
      sync.enable = true;
      intelBusId = lib.mkDefault "PCI:0:2:0";
      nvidiaBusId = lib.mkDefault "PCI:1:0:0";
    };
  };

  # Most of the time the system has lid closed
  services.logind.lidSwitchExternalPower = "ignore";
  services.logind.lidSwitch = "ignore";

  # My configuration specific settings
  sifr = {
    graphics = {
      gnome.enable = true;
      apps = true;
    };

    v18n.emulation.enable = true;
    v18n.emulation.systems = ["aarch64-linux"];
    profiles.basePlus = true;
    development.enable = true;
    security.yubikey = true;

    tailscale = {
      enable = true;
      exitNode = true;
      ssh = true;
    };
  };

  # TODO Move all this to separate module, maybe way to abstract
  home-manager.users."${vars.user}" = {
    programs.ssh.matchBlocks = {
      "ghafa-orin" = {
        hostname = "192.168.1.55";
        user = "root";
        identityFile = "/home/humaid/.ssh/id_ed25519";
        checkHostIP = false;
        extraOptions = {
          StrictHostKeyChecking = "no";
          UserKnownHostsFile = "/dev/null";
        };
      };
      "ghafa" = {
        user = "root";
        hostname = "192.168.101.2";
        proxyJump = "ghafajump";
        checkHostIP = false;
        identityFile = "/home/humaid/.ssh/id_ed25519";
        extraOptions = {
          StrictHostKeyChecking = "no";
          UserKnownHostsFile = "/dev/null";
        };
      };
      "ghafajump" = {
        hostname = "192.168.1.35";
        identityFile = "/home/humaid/.ssh/id_ed25519";
        extraOptions = {
          StrictHostKeyChecking = "no";
          UserKnownHostsFile = "/dev/null";
        };
        user = "ghaf";
        checkHostIP = false;
      };
    };
  };

  nix = {
    buildMachines = [
      {
        hostName = "awsarm";
        system = "aarch64-linux";
        maxJobs = 8;
        speedFactor = 1;
        supportedFeatures = ["nixos-test" "benchmark" "big-parallel" "kvm"];
        mandatoryFeatures = [];
        sshUser = "humaid";
        sshKey = "/home/humaid/.ssh/id_ed25519";
      }
      {
        hostName = "vedenemo-builder";
        system = "x86_64-linux";
        maxJobs = 8;
        speedFactor = 1;
        supportedFeatures = ["nixos-test" "benchmark" "big-parallel" "kvm"];
        mandatoryFeatures = [];
        sshUser = "humaid";
        sshKey = "/home/humaid/.ssh/id_ed25519";
      }
    ];

    distributedBuilds = true;
  };
  programs.ssh = {
    startAgent = true;
    extraConfig = ''
      Host awsarm
           HostName awsarm.vedenemo.dev
           Port 20220
           user humaid
      Host vedenemo-builder
           user humaid
           hostname builder.vedenemo.dev
    '';

    knownHosts = {
      vedenemo-builder = {
        hostNames = ["builder.vedenemodev"];
        publicKey = "builder.vedenemo.dev ssh-ed25519 AAAAC3NzaC1    lZDI1NTE5AAAAIHSI8s/wefXiD2h3I3mIRdK+d9yDGMn0qS5fpKDnSGqj";
      };
      awsarm = {
        hostNames = ["awsarm.vedenemo.dev"];
        publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIL3f7tAAO3Fc+8BqemsBQc/Yl/NmRfyhzr5SFOSKqrv0";
      };
    };
  };
}
