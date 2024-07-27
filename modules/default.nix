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
      defaultSopsFile = ../secrets/all.yaml;
      defaultSopsFormat = "yaml";
      #age.keyFile = "/home/${vars.user}/.config/sops/age/keys.txt";
      age.keyFile = "/var/lib/sops-nix/key.txt";
      age.generateKey = true;
      secrets = {
        user-passwd = {
          sopsFile = ../secrets/all.yaml;
          neededForUsers = true;
        };
        tskey = {
          sopsFile = ../secrets/gadgets.yaml;
        };
        wifi-2g = {
          sopsFile = ../secrets/gadgets.yaml;
        };
        wifi-5g = {
          sopsFile = ../secrets/gadgets.yaml;
        };
        nm-5g = {
          sopsFile = ../secrets/gadgets.yaml;
          path = "/etc/NetworkManager/system-connections/5g.nmconnection";
          owner = "root";
          mode = "600";
        };
        lldap-env = {
          sopsFile = ../secrets/gadgets.yaml;
        };
        github-token = {
          sopsFile = ../secrets/gadgets.yaml;
          owner = vars.user;
        };
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
        "disk"
        "networkmanager"
        "wheel"
        "kvm"
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

    # Use chrony as timeserver. Although chrony is more heavy (includes server
    # implementation), but it implements full NTP protocol.
    services.timesyncd.enable = true;
    # Don't let Nix add timeservers in chrony config, we want to manually add
    # multiple options.
    networking.timeServers = [];
    services.chrony = {
      enable = true;
      extraConfig = ''
        server time.cloudflare.com iburst maxsources 5 xleave nts
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
        automatic = true;
        dates = "weekly";
        options = "--delete-older-than 30d";
      };

      # API Rate limit for GitHub
      extraOptions = ''
        !include ${config.sops.secrets.github-token.path}
      '';
    };

    # Use spleen font for console (tty)
    fonts.packages = [pkgs.spleen];
    console.font = "${pkgs.spleen}/share/consolefonts/spleen-12x24.psfu";

    services.getty = {
      greetingLine = lib.mkOverride 50 ''<<< Welcome to ${config.networking.hostName} (\l) >>>'';
      helpLine = lib.mkOverride 50 ''\nHelp: https://github.com/humaidq/dotfiles'';
    };

    systemd.services.NetworkManager-wait-online.enable = false;
    systemd.network.wait-online.enable = false;

    hardware.enableAllFirmware = true;
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
