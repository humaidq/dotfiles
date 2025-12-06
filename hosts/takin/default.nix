{ pkgs, ... }:
{
  environment.systemPackages = with pkgs; [
    neovim
    emacs
    tmux
    bitwarden-desktop
    nixfmt-rfc-style
    texliveFull
    ripgrep

    # Development
    bat
    ffmpeg
    gdb

    nix-output-monitor
    nix-tree
    nixfmt-rfc-style
    nixd

    # other tools
    pnpm
    nodejs
    tree-sitter

    # emacs
    # :term vterm
    gnumake
    cmake

    # :tools editorconfig
    editorconfig-core-c

    # :tools docker
    dockerfile-language-server-nodejs

    # :lang cc
    clang
    clang-tools
    # :lang data
    libxml2 # xmllint
    # :lang go
    go
    gomodifytags
    gotests
    gore
    # :lang javascript
    nodejs
    # :lang latex requires texlive (defined somewhere else)
    # :lang markdown
    pandoc
    discount
    # :lang python
    black
    pipenv
    python312Packages.pyflakes
    python312Packages.isort
    python312Packages.pytest
    # :lang org (texlive +...)
    gnuplot
    sqlite # +roam2
    # :lang plantuml
    plantuml
    graphviz
    jdk
    # :lang rust
    rustc
    cargo
    rust-analyzer
    # :lang sh
    shfmt
    shellcheck
    nodePackages.bash-language-server
    # :lang yaml
    nodePackages.yaml-language-server
    # :lang web
    nodePackages.js-beautify
    stylelint
    html-tidy
    # :lang zig
    zig
    zls

    binutils
    zstd

    # :checkers grammar
    languagetool
    # :cherkers spell
    (aspellWithDicts (
      ds: with ds; [
        ar
        en
        en-computers
        en-science
      ]
    ))

    claude-code

    # lookup
    python312Full
    python312Packages.pip

    # lsp
    nodePackages.typescript-language-server
    nodePackages.vscode-langservers-extracted
  ];

  homebrew = {
    enable = true;
    onActivation = {
      autoUpdate = true;
      upgrade = true;
      cleanup = "zap";
    };
    brews = [
      "openssh"
    ];
    casks = [
      "ollama"
      "tailscale-app"
      "zotero"
      "ghostty"
      "font-dejavu"
      "font-jetbrains-mono"
      "font-fira-code"
      "font-fira-code-nerd-font"
    ];
  };

  nixpkgs.config.allowUnfree = true;
  nix = {
    settings = {
      allowed-users = [ "humaid.alqasimi" ];
      trusted-users = [
        "root"
        "humaid.alqasimi"
      ];
    };
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
  };

  system.primaryUser = "humaid.alqasimi";

  # Necessary for using flakes on this system.
  nix.settings.experimental-features = "nix-command flakes";

  # Enable alternative shell support in nix-darwin.
  programs.fish.enable = true;
  environment.shells = [ pkgs.fish ];
  users.users."humaid.alqasimi" = {
    shell = pkgs.fish;
  };

  environment.systemPath = [
    "/opt/homebrew/bin"
  ];

  # Use deteminate nix
  nix.enable = false;

  # Set Git commit hash for darwin-version.
  system.configurationRevision = null;

  # Used for backwards compatibility, please read the changelog before changing.
  # $ darwin-rebuild changelog
  system.stateVersion = 6;

  nixpkgs.hostPlatform = "aarch64-darwin";
}
