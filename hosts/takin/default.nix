{ vars, ... }:
{
  # TODO fix this target
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
    settings.experimental-features = [
      "nix-command"
      "flakes"
    ];
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
      CustomUserPreferences = {
        "com.apple.desktopservices" = {
          # Avoid creating .DS_Store files on network or USB volumes
          DSDontWriteNetworkStores = true;
          DSDontWriteUSBStores = true;
        };
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
    taps = [ "homebrew/cask-fonts" ];
    brews = [
      "direnv"
      "ffmpeg"
      "gnupg"
      "go"
      "jython"
      "neovim"
      "openjdk"
      "pinentry-mac"
      "python@3.11"
      "tmux"
      "tmux"
    ];
    casks = [
      "coconutbattery"
      "eloston-chromium" # ungoogled-chromium
      "figma"
      "firefox"
      "font-monaspace"
      "font-fira-code-nerd-font"
      "inkscape"
      "iterm2"
      "logi-options-plus"
      "slack"
      "stats"
      "tailscale"
      "textmate"
      "transmission"
      "vlc"
    ];
  };
}
