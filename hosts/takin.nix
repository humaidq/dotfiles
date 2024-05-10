{vars, ...}: {
  networking = {
    computerName = "takin";
    hostName = "takin";
  };
  home-manager.users.${vars.user} = {
    home.stateVersion = "23.05";
  };

  users.users.${vars.user} = {
    home = "/Users/humaid";
  };

  nix = {
    settings.experimental-features = ["nix-command" "flakes"];
    extraOptions = ''
      auto-optimise-store = true
    '';
  };

  system = {
    defaults = {
      NSGlobalDomain = {
        KeyRepeat = 1;
        NSAutomaticCapitalizationEnabled = false;
        NSAutomaticSpellingCorrectionEnabled = false;
      };
      dock = {
        orientation = "bottom";
        tilesize = 40;
      };
    };

    stateVersion = 4;
  };

  programs = {
    zsh.enable = true;
  };
  services = {
    nix-daemon.enable = true;
  };
  homebrew = {
    enable = true;
    onActivation = {
      autoUpdate = true;
      upgrade = true;
      cleanup = "zap";
    };
    taps = [
      "homebrew/cask-fonts"
    ];
    brews = [
      "jython"
      "python@3.11"
      "tmux"
      "gnupg"
      "go"
      "mosquitto"
      "openjdk"
      "tmux"
      "pinentry-mac"
      "direnv"
      "ffmpeg"
      "neovim"
    ];
    casks = [
      "vlc"
      "rectangle-pro"
      "slack"
      "stats"
      "transmission"
      "firefox"
      "coconutbattery"
      "docker"
      "eloston-chromium" # ungoogled-chromium
      "logi-options-plus"
      "diffusionbee"
      "bartender"
      "tailscale"
      "font-monaspace"
      "figma"
      "inkscape"
      "eqmac"
      "iterm2"
      "raycast"
      "slack"
    ];
  };
}
