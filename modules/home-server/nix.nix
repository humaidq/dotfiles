{ lib, config, ... }:
let
  cfg = config.sifr.home-server;
in
{
  config = lib.mkIf cfg.enable {
    services.postgresql = {
      settings = {
        max_connections = 200;
      };
    };

    services.hydra = {
      enable = true;
      hydraURL = "https://cache.alq.ae";
      port = 3300;
      notificationSender = "hydra@localhost"; # e-mail of hydra service
      useSubstitutes = true;
    };

    nix.settings.allowed-uris = [
      "github:"
      "git+https://github.com/"
      "git+ssh://github.com/"
      "https://github.com/"
      "https://clients2.google.com/"
    ];

    nix.settings.trusted-users = [
      "root"
      "hydra"
      "hydra-www"
    ];

    sops.secrets."nix-cache/privkey" = {
      sopsFile = ../../secrets/home-server.yaml;
      owner = "harmonia";
      mode = "600";
    };
    nix = {
      buildMachines = [
        {
          hostName = "localhost";
          systems = [
            "x86_64-linux"
            "aarch64-linux"
            "riscv64-linux"
          ];
          supportedFeatures = [
            "kvm"
            "nixos-test"
            "big-parallel"
            "benchmark"
            "local"
          ];
          maxJobs = 1;
        }
      ];
    };

    services.harmonia = {
      enable = true;
      signKeyPaths = [ config.sops.secrets."nix-cache/privkey".path ];
      settings = {
        bind = "0.0.0.0:5000";
        priority = 50;
      };
    };
  };
}
