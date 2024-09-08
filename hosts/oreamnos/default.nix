{
  inputs,
  lib,
  self,
  config,
  pkgs,
  vars,
  ...
}:
{
  imports = [
    self.nixosModules.sifrOS
    inputs.impermanence.nixosModules.impermanence
    inputs.disko.nixosModules.disko
    (import ./hardware.nix)
    (import ./disk.nix)
  ];
  networking.hostName = "oreamnos";
  networking.hostId = "0a65726f"; # echo ore | od -A none -t x4

  # My configuration specific settings
  sifr = {
    profiles = {
      basePlus = true;
      work = true;
    };
    v12n.emulation = {
      enable = true;
      systems = [
        "aarch64-linux"
        "riscv64-linux"
      ];
    };
    security = {
      encryptDNS = true;
    };
    development.enable = true;
    ntp.useNTS = true;

    o11y = {
      server.enable = true;
      client.enable = true;
    };

    home-server.enable = true;

    tailscale = {
      enable = true;
      exitNode = true;
      ssh = true;
      auth = false;
    };
  };

  services.ollama = {
    enable = true;
    # this is enabled by default, which sets dynamicuesr to true in systemd,
    # seems to be broken by impermanence?
    sandbox = false;
    package = pkgs.unstable.ollama-cuda;
    acceleration = "cuda";
    # loadModels = [
    #   "gemma2"
    #   "falcon2"
  };

  home-manager.users."${vars.user}" = {
    services.emacs.enable = true;
  };

  environment.systemPackages = with pkgs; [
    cifs-utils
    emacs
  ];

  sops.secrets."nas/humaid" = {
    sopsFile = ../../secrets/home-server.yaml;
  };
  fileSystems."/mnt/synology-nas" = {
    device = "//192.168.1.44/homes";
    fsType = "cifs";
    options = [
      "credentials=${config.sops.secrets."nas/humaid".path}"
      "dir_mode=0777,file_mode=0777,iocharset=utf8,auto"
    ];
  };

  # Doing riscv64 xcomp, manually gc
  nix.gc.automatic = lib.mkForce false;

  security.sudo.wheelNeedsPassword = false;

  boot.loader = {
    systemd-boot = {
      enable = true;
      consoleMode = "auto";
    };

    efi.canTouchEfiVariables = true;
  };

  hardware = {
    # TODO 24.11
    #graphics = {
    #  enable = true;
    #  enable32Bit = true;
    #};
    nvidia = {
      modesetting.enable = true;
    };
    opengl.enable = true;
  };
  services.xserver.videoDrivers = [ "nvidia" ];

  users.users.${vars.user} = {
    isNormalUser = true;
    openssh.authorizedKeys.keys = [
      "ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBP6h78HwApxcrPEothfFY1m0kLwroeQWpskYGsEVrxnXtohd+FBiWmer9zN37FtMyUI8b3y3LVouuKciYTlPKGs= ipadpro"
      "ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBD5+afJhtncZlx5HfXcrqqEDjNAmo7ZtatgM46ao+EcBg/vh8m0+aNb/ZdrBKqiCnkHOkN6R4gacWpoALgZ9BmA="
    ];
  };

  networking.firewall.allowedTCPPorts = [
    5000
    22
    80
    443
    53
  ];
  networking.firewall.allowedUDPPorts = [
    123
    22
    53
  ];

  services.chrony.extraConfig = lib.mkAfter ''
    allow all
  '';

  systemd.enableEmergencyMode = false;

  # impermanence setup
  environment.persistence."/persist" = {
    hideMounts = true;
    directories = [
      "/var/log"
      "/var/lib/nixos"
      "/var/lib/systemd/coredump"
      "/var/lib/sops-nix"
      "/var/lib/ollama"
      "/var/lib/chrony"
      "/var/lib/tailscale"
      "/var/lib/grafana"
      {
        directory = "/var/lib/hydra";
        user = "hydra";
        mode = "0700";
      }
      "/var/lib/loki"
      "/var/lib/prometheus2"
      #"/var/lib/private/AdGuardHome"
      #"/var/lib/private/jellyseerr"
      #"/var/lib/private/lldap"
      #"/var/lib/private/mealie"
      #"/var/lib/private/prowlarr"

      {
        directory = "/var/lib/private";
        mode = "0700";
      }
      "/var/lib/radarr"
      "/var/lib/postgresql"
      {
        directory = "/var/lib/kavita";
        user = "kavita";
        mode = "0700";
      }
      {
        directory = "/var/lib/jellyfin";
        user = "jellyfin";
        mode = "0700";
      }
      "/var/lib/deluge"
      "/var/lib/caddy"
      "/var/lib/audiobookshelf"
      "/var/lib/uptimed"
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
        ".local/share/direnv"
        ".config/sops"
        ".config/emacs"
        ".config/doom"
      ];
      files = [ ".config/zsh/.zsh_history" ];
    };
  };
  # sops loads before impermanence mounts are
  sops.age.keyFile = lib.mkForce "/persist/var/lib/sops-nix/key.txt";

  fileSystems."/persist".neededForBoot = true;

  # Reset root on every boot
  boot.initrd.postDeviceCommands = lib.mkAfter ''
    zfs rollback -r rpool/root@blank
  '';

  nixpkgs.hostPlatform = "x86_64-linux";
  system.stateVersion = "24.05";
}
