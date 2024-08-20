{
  self,
  lib,
  pkgs,
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
    ntp.useNTS = false;

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
  nix.package = pkgs.nixVersions.git;

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

  services.nix-serve = {
    enable = true;
    package = pkgs.nix-serve-ng;
    secretKeyFile = "/var/cache-priv-key.pem";
  };
  users.users.nix-serve = {
    isSystemUser = true;
    group = "nix-serve";
  };
  users.groups.nix-serve = { };

  nixpkgs.hostPlatform = "x86_64-linux";
  system.stateVersion = "23.11";
}
