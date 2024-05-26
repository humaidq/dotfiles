{
  config,
  pkgs,
  lib,
  vars,
  inputs,
  ...
}:
with lib; let
  cfg = config.sifr;
in {
  imports =
    [
      inputs.sops-nix.nixosModules.sops
      inputs.home-manager.nixosModules.home-manager
    ]
    ++ (import ./modules-list.nix);

  config = {
    # Setup home-manager
    home-manager.useGlobalPkgs = true;
    home-manager.useUserPackages = true;
    home-manager.sharedModules = [
      inputs.sops-nix.homeManagerModules.sops
      inputs.nix-index-database.hmModules.nix-index
    ];

    # Setup sops-nix
    sops.defaultSopsFile = ../secrets/secrets.yaml;
    sops.defaultSopsFormat = "yaml";
    sops.age.keyFile = "/home/${vars.user}/.config/sops/age/keys.txt";
    sops.age.generateKey = true;
    sops.secrets = {
      tskey = {};
      wifi-2g = {};
      wifi-5g = {};
      lldap-env = {};
      github-token = {};
    };

    users.users.${vars.user} = {
      isNormalUser = true;
      uid = 1000;
      extraGroups = [
        "plugdev"
        "dialout"
        "video"
        "audio"
        "docker"
        "disk"
        "networkmanager"
        "wheel"
        "lp"
        "kvm"
        "bluetooth"
      ];
      description = cfg.fullname;
      openssh.authorizedKeys.keys = [
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPx68Wz04/MkfKaptXlvghLjwnW3sTUXgZgiDD3Nytii humaid@goral"
      ];
    };
    users.motd = cfg.banner;

    users.users.root.openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPx68Wz04/MkfKaptXlvghLjwnW3sTUXgZgiDD3Nytii humaid@goral"
    ];

    home-manager.users.${vars.user} = {
      home.stateVersion = "23.05";
      home.sessionPath = ["$HOME/.bin"];

      nixpkgs.config.allowUnfree = true;
    };

    time.timeZone = cfg.timezone;
    i18n.defaultLocale = "en_GB.UTF-8";

    # We enable DHCP for all network interfaces by default.
    networking.useDHCP = lib.mkDefault true;

    # Time server stuff
    services.timesyncd.enable = false;
    services.chrony.enable = true;
    services.chrony.extraConfig = ''
      server time.apple.com iburst maxsources 5 xleave
      server 0.pool.ntp.org iburst maxsources 5 xleave
      server 1.pool.ntp.org iburst maxsources 5 xleave
      server 2.pool.ntp.org iburst maxsources 5 xleave
      server 3.pool.ntp.org iburst maxsources 5 xleave
    '';
    networking.timeServers = [];

    # DNS configuration
    services.resolved.enable = true;
    networking.nameservers = [
      # Reliable worldwide
      "8.8.8.8#dns.google"
      "1.0.0.1#cloudflare-dns.com"
    ];

    nix = {
      settings = {
        allowed-users = [cfg.username];
        builders-use-substitutes = true;
        trusted-users = ["root" cfg.username];
        auto-optimise-store = true;

        # Enable flakes
        experimental-features = ["nix-command" "flakes"];
      };
      gc = {
        automatic = false;
        dates = "weekly";
        options = "--delete-older-than 60d";
      };

      # API Rate limit for GitHub
      extraOptions = ''
        !include ${config.sops.secrets.github-token.path}
      '';
    };

    # Use spleen font for console (tty)
    fonts.packages = with pkgs; [
      spleen
    ];
    console.font = "${pkgs.spleen}/share/consolefonts/spleen-12x24.psfu";

    nixpkgs = {
      # Allow proprietary packages and packages marked as broken
      config = {
        allowUnfree = true;
        allowBroken = true;
      };
    };
  };
}
