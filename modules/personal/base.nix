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
    ./development.nix
    ./secrets.nix
    ./ssh.nix
    ./amateur.nix
    ./dns.nix
    ./focus-mode
    ./moshi.nix
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

    i18n = {
      supportedLocales = [
        "en_GB.UTF-8/UTF-8"
        "en_US.UTF-8/UTF-8"
        "ar_AE.UTF-8/UTF-8"
      ];
      # LC_TIME stays en_GB so week starts on Monday; ar_AE has
      # first_weekday=1 (Sunday), wrong since the 2022 UAE workweek change.
      extraLocaleSettings = {
        LC_TIME = "en_GB.UTF-8";
        LC_MONETARY = "ar_AE.UTF-8";
        LC_PAPER = "ar_AE.UTF-8";
        LC_MEASUREMENT = "ar_AE.UTF-8";
        LC_ADDRESS = "ar_AE.UTF-8";
        LC_TELEPHONE = "ar_AE.UTF-8";
      };
    };

    home-manager.users.${vars.user} = {
      xdg = {
        enable = true;
        mimeApps.enable = true;
        mimeApps.defaultApplications = { };
        userDirs = {
          enable = true;
          createDirectories = false;
          desktop = "$HOME";
          documents = "$HOME/docs";
          download = "$HOME/inbox/web";
          pictures = "$HOME/docs/pics";
          videos = "$HOME/docs/vids";
          music = "";
          publicShare = "";
          templates = "";
        };
        configFile."user-dirs.locale".text = "en_GB";
        configFile."mimeapps.list".force = true;
        configFile."user-dirs.locale".force = true;
        configFile."user-dirs.dirs".force = true;
      };

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
