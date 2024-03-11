{
  config,
  pkgs,
  lib,
  unstable,
  vars,
  ...
}: {
  imports = [
    ../lib/vmware-guest.nix
  ];

  boot.loader = {
    systemd-boot = {
      enable = true;
      consoleMode = "auto";
    };

    efi.canTouchEfiVariables = true;
  };

  # We have our own module that works with aarch64.
  disabledModules = ["virtualisation/vmware-guest.nix"];
  virtualisation.vmware.guest.enable = true;
  networking.firewall.enable = lib.mkForce false;

  # My configuration specific settings
  sifr = {
    graphics = {
      i3.enable = true;
      gnome.enable = true;
      hidpi = true;
      enableSound = false;
      apps = true;
    };
    v18n.docker.enable = true;
    v18n.emulation.systems = ["x86_64-linux"];
    hardware.vm = true;
    profiles.basePlus = true;
    development.enable = true;
    security.yubikey = true;

    tailscale = {
      enable = true;
      exitNode = false;
      ssh = true;

      auth = true;
      tsKey = "tskey-auth-kJy3Zg2CNTRL-C2KHKDFpXUWioAwiSPs8bWPAuG346L6uM";
    };
  };
  programs.nix-ld.enable = true;

  home-manager.users."${vars.user}" = {
    programs.ssh.matchBlocks = {
      "ghafa" = {
        user = "root";
        hostname = "192.168.101.2";
        proxyJump = "ghafajump";
        checkHostIP = false;
        identityFile = "~/.ssh/id_ed25519";
        extraOptions = {
          StrictHostKeyChecking = "no";
          UserKnownHostsFile = "/dev/null";
        };
      };
      "ghafajump" = {
        hostname = "192.168.1.29";
        identityFile = "~/.ssh/id_ed25519";
        extraOptions = {
          StrictHostKeyChecking = "no";
          UserKnownHostsFile = "/dev/null";
        };
        user = "ghaf";
        checkHostIP = false;
      };
    };
  };
  programs.ssh.knownHosts = {
    "builder.vedenemo.dev".publicKey = "builder.vedenemo.dev ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHSI8s/wefXiD2h3I3mIRdK+d9yDGMn0qS5fpKDnSGqj";
  };
}
