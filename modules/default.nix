{
  config,
  pkgs,
  lib,
  vars,
  inputs,
  ...
}: let
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
      inputs.nixvim.homeManagerModules.nixvim
    ];

    # Setup sops-nix
    sops = {
      defaultSopsFile = ../secrets/secrets.yaml;
      defaultSopsFormat = "yaml";
      #age.keyFile = "/home/${vars.user}/.config/sops/age/keys.txt";
      age.keyFile = "/var/lib/sops-nix/key.txt";
      age.generateKey = true;
      secrets = {
        tskey = {};
        wifi-2g = {};
        wifi-5g = {};
        lldap-env = {};
        github-token = {
          owner = vars.user;
        };
        user-passwd.neededForUsers = true;
      };
    };

    # Define default system user.
    users.mutableUsers = false;
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
      openssh.authorizedKeys.keys = config.users.users.root.openssh.authorizedKeys.keys;
      hashedPasswordFile = config.sops.secrets.user-passwd.path;
    };

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

    # Use chrony as timeserver. Although chrony is more heavy (includs server
    # implementation), but it implements full NTP protocol.
    services.timesyncd.enable = true;
    # Don't let Nix add timeservers in chrony config, we want to do them
    # manually to add multiple options.
    networking.timeServers = [];
    services.chrony = {
      enable = true;
      extraConfig = ''
        server time.cloudflare.com iburst maxsources 5 xleave nts trust
        server 0.pool.ntp.org iburst maxsources 5 xleave
        server 1.pool.ntp.org iburst maxsources 5 xleave
        server 2.pool.ntp.org iburst maxsources 5 xleave

        makestep 1.0 3
      '';
      enableNTS = true;
    };

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
    fonts.packages = [pkgs.spleen];
    console.font = "${pkgs.spleen}/share/consolefonts/spleen-12x24.psfu";

    nixpkgs = {
      # Allow proprietary packages and packages marked as broken
      config = {
        allowUnfree = true;
        allowBroken = true;
        allowUnsupportedSystem = true;
      };
    };
  };
}
