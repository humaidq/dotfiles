{
  self,
  lib,
  inputs,
  ...
}:
{
  imports = [
    self.nixosModules.sifrOS
    inputs.nixos-hardware.nixosModules.lenovo-thinkpad-t590
    (import ./hardware.nix)
  ];
  networking.hostName = "serow";

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
    };
    v12n.emulation = {
      enable = true;
      systems = [
        "aarch64-linux"
        "riscv64-linux"
      ];
    };
    security = {
      yubikey = true;
      encryptDNS = true;
    };
    development.enable = true;
    ntp.useNTS = true;

    o11y = {
      server.enable = true;
      client.enable = true;
    };

    tailscale = {
      enable = true;
      exitNode = true;
      ssh = true;
      auth = true;
    };
  };

  # Doing riscv64 xcomp, manually gc
  nix.gc.automatic = lib.mkForce false;

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

  services.harmonia = {
    enable = true;
    signKeyPath = "/var/cache-priv-key.pem";
    settings = {
      bind = "0.0.0.0:5000";
      priority = 50;
    };
  };

  networking.firewall.allowedTCPPorts = [ 5000 ];

  networking.firewall.allowedUDPPorts = [ 123 ];

  services.chrony.extraConfig = lib.mkAfter ''
    allow all
    peer 100.75.159.21
  '';

  services.hydra = {
    enable = true;
    hydraURL = "http://serow:3300";
    port = 3300;
    notificationSender = "hydra@localhost"; # e-mail of hydra service
    buildMachinesFiles = [ ];
    # you will probably also want, otherwise *everything* will be built from scratch
    useSubstitutes = true;
  };
  nix.settings.allowed-uris = [
    "github:"
    "git+https://github.com/"
    "git+ssh://github.com/"
    "https://github.com/"
  ];
  nix.settings.trusted-users = [
    "root"
    "hydra"
    "hydra-www"
  ];

  swapDevices = [
    {
      device = "/swap";
      size = 32 * 1024;
    }
  ];

  nixpkgs.hostPlatform = "x86_64-linux";
  system.stateVersion = "23.11";
}
