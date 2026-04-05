{
  config,
  lib,
  vars,
  ...
}:
let
  substituters = lib.optionals (config.networking.hostName != "oreamnos") [
    "https://cache.huma.id?priority=20"
  ];
in
{
  imports = [
    ./baseplus.nix
    ./development.nix
    ./secrets.nix
    ./ssh.nix
    ./amateur.nix
    ./dns.nix
    ./focus-mode
    ./networking
    ./o11y
    ./receipt.nix
    ./research.nix
    ./security-research.nix
    ./university.nix
    ./work.nix
  ];

  config = {
    sifr = {
      timezone = lib.mkDefault "Asia/Dubai";
      username = lib.mkDefault "humaid";
      fullname = lib.mkDefault "Humaid Alqasimi";
      gitEmail = lib.mkDefault "git@huma.id";
      projectFlake = lib.mkDefault "github:humaidq/dotfiles";
      scripts.enable = lib.mkDefault true;
      backups.repo = lib.mkDefault "humaid@oreamnos:/mnt/humaid/files/backups/${config.networking.hostName}";
    };

    security.pki.certificateFiles = [ ../alqasimi-ca.pem ];

    home-manager.users.${vars.user} = {
      programs = {
        rbw.settings = {
          email = "me@huma.id";
          base_url = "https://vault.alq.ae";
        };
      };
    };
    services.getty.helpLine = lib.mkOverride 50 "Help: https://github.com/humaidq/dotfiles";

    nix = {
      settings = {
        inherit substituters;
        trusted-substituters = substituters ++ [
          "https://dev-cache.vedenemo.dev"
          "https://ghaf-dev.cachix.org"
        ];
        trusted-public-keys = [
          "cache.huma.id:YJG69WGZ8iUFwrZFrXbLY50m9jXNmJUas1vwtksUFFM="
          "ghaf-dev.cachix.org-1:S3M8x3no8LFQPBfHw1jl6nmP8A7cVWKntoMKN3IsEQY="
        ];
      };

      extraOptions = lib.mkIf config.sifr.hasGadgetSecrets ''
        !include ${config.sops.secrets.github-token.path}
      '';
    };
  };
}
