{
  config,
  lib,
  vars,
  ...
}:
let
  cfg = config.sifr.profiles;
in
{
  options.sifr.profiles = {
    work = lib.mkEnableOption "work profile";
  };
  config = lib.mkIf cfg.work {
    #environment.systemPackages = with pkgs; [ slack ];

    # TODO
    # see cups-kyodialog, and:
    # https://github.com/NixOS/nixpkgs/blob/nixos-unstable/pkgs/by-name/cu/cups-kyocera-3500-4500/package.nix
    #hardware.printers.ensurePrinters = [
    #  {
    #    name = "TII_Secure";
    #    #model = "${./assets/taskalfa4053ci-driverless-cupsfilters.ppd}";
    #    location = "TII Any Printer";
    #    deviceUri = "lpd://10.161.10.41";
    #    ppdOptions = {PageSize = "A4";};
    #  }
    #];

    # SSH config for Ghaf development
    home-manager.users."${vars.user}" = {
      programs.ssh.matchBlocks = {
        "ghafa-orin" = {
          hostname = "192.168.1.32";
          user = "root";
          identityFile = "/home/humaid/.ssh/id_ed25519_ghaf";
          checkHostIP = false;
          extraOptions = {
            StrictHostKeyChecking = "no";
            UserKnownHostsFile = "/dev/null";
          };
        };
        "groot" = {
          user = "root";
          hostname = "192.168.1.68";
          checkHostIP = false;
          identityFile = "/home/humaid/.ssh/id_ed25519_ghaf";
          extraOptions = {
            StrictHostKeyChecking = "no";
            UserKnownHostsFile = "/dev/null";
          };
        };
        "ghafa" = {
          user = "root";
          hostname = "192.168.100.2";
          proxyJump = "ghafajump";
          checkHostIP = false;
          identityFile = "/home/humaid/.ssh/id_ed25519_ghaf";
          extraOptions = {
            StrictHostKeyChecking = "no";
            UserKnownHostsFile = "/dev/null";
          };
        };
        "ghafajump" = {
          hostname = "192.168.1.254";
          identityFile = "/home/humaid/.ssh/id_ed25519_ghaf";
          extraOptions = {
            StrictHostKeyChecking = "no";
            UserKnownHostsFile = "/dev/null";
          };
          user = "ghaf";
          checkHostIP = false;
        };
      };
    };

    # Remote builders
    #nix = {
    #  buildMachines = [
    #    {
    #      hostName = "hetzarm";
    #      system = "aarch64-linux";
    #      maxJobs = 8;
    #      speedFactor = 1;
    #      supportedFeatures = [
    #        "nixos-test"
    #        "benchmark"
    #        "big-parallel"
    #        "kvm"
    #      ];
    #      mandatoryFeatures = [ ];
    #      sshUser = "humaid";
    #      sshKey = "/home/humaid/.ssh/id_ed25519";
    #    }
    #    {
    #      hostName = "vedenemo-builder";
    #      system = "x86_64-linux";
    #      maxJobs = 8;
    #      speedFactor = 1;
    #      supportedFeatures = [
    #        "nixos-test"
    #        "benchmark"
    #        "big-parallel"
    #        "kvm"
    #      ];
    #      mandatoryFeatures = [ ];
    #      sshUser = "humaid";
    #      sshKey = "/home/humaid/.ssh/id_ed25519";
    #    }
    #  ];

    #  distributedBuilds = true;
    #};
    programs.ssh = {
      extraConfig = ''
        Host awsarm
             HostName awsarm.vedenemo.dev
             Port 20220
             user humaid
             IdentityFile /home/humaid/.ssh/id_ed25519_ghaf
        Host hetzarm
             user humaid
             HostName 65.21.20.242
             IdentityFile /home/humaid/.ssh/id_ed25519_ghaf
        Host vedenemo-builder
             user humaid
             hostname builder.vedenemo.dev
             IdentityFile /home/humaid/.ssh/id_ed25519_ghaf
      '';

      knownHosts = {
        vedenemo-builder = {
          hostNames = [ "builder.vedenemodev" ];
          publicKey = "builder.vedenemo.dev ssh-ed25519 AAAAC3NzaC1    lZDI1NTE5AAAAIHSI8s/wefXiD2h3I3mIRdK+d9yDGMn0qS5fpKDnSGqj";
        };
        hetzarm-ed25519 = {
          hostNames = [ "65.21.20.242" ];
          publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILx4zU4gIkTY/1oKEOkf9gTJChdx/jR3lDgZ7p/c7LEK";
        };
        awsarm = {
          hostNames = [ "awsarm.vedenemo.dev" ];
          publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIL3f7tAAO3Fc+8BqemsBQc/Yl/NmRfyhzr5SFOSKqrv0";
        };
      };
    };
  };
}
