{
  config,
  pkgs,
  lib,
  vars,
  inputs,
  ...
}:
let
  cfg = config.sifr;
in
{
  imports = [
    inputs.sops-nix.nixosModules.sops
    inputs.home-manager.nixosModules.home-manager
    inputs.nix-topology.nixosModules.default
  ] ++ (import ./modules-list.nix);

  config = {
    # Setup home-manager
    home-manager.useGlobalPkgs = true;
    home-manager.useUserPackages = true;
    home-manager.sharedModules =
      [
        inputs.sops-nix.homeManagerModules.sops
        inputs.nixvim.homeManagerModules.nixvim
      ]
      ++ lib.optionals (pkgs.hostPlatform.system != "riscv64-linux") [
        inputs.nix-index-database.hmModules.nix-index
      ];
    topology.self.name = config.networking.hostName;

    topology.networks.tailscale0 = {
      name = "Tailscale";
      cidrv4 = "100.64.0.0/10";
    };

    topology.networks.home = {
      name = "Home LAN";
      cidrv4 = "192.168.1.0/24";
    };

    # Setup sops-nix
    sops = {
      defaultSopsFile = ../secrets/all.yaml;
      defaultSopsFormat = "yaml";
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
    users.groups.plugdev = { };

    users.users.root.openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPx68Wz04/MkfKaptXlvghLjwnW3sTUXgZgiDD3Nytii humaid@goral"
    ];

    home-manager.users.${vars.user} = {
      home.stateVersion = "23.05";
      home.sessionPath = [ "$HOME/.bin" ];

      nixpkgs.config.allowUnfree = true;
    };

    time.timeZone = cfg.timezone;
    i18n.defaultLocale = "en_GB.UTF-8";

    # We enable DHCP for all network interfaces by default.
    networking.useDHCP = lib.mkDefault true;

    nix = {
      settings = rec {
        allowed-users = [ cfg.username ];
        builders-use-substitutes = true;
        trusted-users = [
          "root"
          cfg.username
        ];
        auto-optimise-store = true;

        trusted-substituters = substituters ++ [
          "https://dev-cache.vedenemo.dev"
          "https://cache.ssrcdevops.tii.ae"
          "https://ghaf-dev.cachix.org"
        ];

        substituters = lib.optional (
          config.networking.hostName != "oreamnos"
        ) "https://cache.huma.id?priority=51";

        trusted-public-keys = [
          "cache.huma.id:YJG69WGZ8iUFwrZFrXbLY50m9jXNmJUas1vwtksUFFM="
          "ghaf-infra-dev:EdgcUJsErufZitluMOYmoJDMQE+HFyveI/D270Cr84I="
          "cache.ssrcdevops.tii.ae:oOrzj9iCppf+me5/3sN/BxEkp5SaFkHfKTPPZ97xXQk="
          "ghaf-dev.cachix.org-1:S3M8x3no8LFQPBfHw1jl6nmP8A7cVWKntoMKN3IsEQY="
        ];
        # Enable flakes
        experimental-features = [
          "nix-command"
          "flakes"
        ];
      };
      gc = {
        automatic = true;
        dates = "weekly";
        options = "--delete-older-than 30d";
      };

      channel.enable = false;

      # API Rate limit for GitHub
      extraOptions = ''
        !include ${config.sops.secrets.github-token.path}
      '';
    };

    # Use spleen font for console (tty)
    fonts.packages = [ pkgs.spleen ];
    console.font = "${pkgs.spleen}/share/consolefonts/spleen-12x24.psfu";

    services.getty = {
      greetingLine = lib.mkOverride 50 ''<<< Welcome to ${config.networking.hostName} (\l) >>>'';
      helpLine = lib.mkOverride 50 ''Help: https://github.com/humaidq/dotfiles'';
    };

    hardware.enableAllFirmware = true;
    nixpkgs = {
      # Allow proprietary packages and packages marked as broken
      config = {
        allowUnfree = true;
        #allowBroken = true;
        #allowUnsupportedSystem = true;
        permittedInsecurePackages = [
          #  "nix-2.24.5"

          # For Sonarr
          "aspnetcore-runtime-wrapped-6.0.36"
          "aspnetcore-runtime-6.0.36"
          "dotnet-sdk-wrapped-6.0.428"
          "dotnet-sdk-6.0.428"
        ];
      };
      overlays = [

        (_final: prev: {
          #unstable = import inputs.nixpkgs-unstable {
          #  inherit (final) system;
          #  config.allowUnfree = true;
          #};
          liquidctl = import ../overlays/liquidctl { inherit prev; };
        })
      ];

    };
  };
}
