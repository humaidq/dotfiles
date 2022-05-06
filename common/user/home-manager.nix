{ pkgs, lib, ... }:

let
  #nur = import (builtins.fetchTarball "https://github.com/nix-community/NUR/archive/master.tar.gz") {
  #  inherit pkgs;
  #};
in
{
  imports = [
    ./firefox.nix
    ./gnome.nix
    ./nvim.nix
    ./shell.nix
    ./scripts.nix
    ./git.nix
    ./xdg.nix
  ];

  home.stateVersion = "21.11";
  home.sessionPath = [ "$HOME/.bin" ];

  nixpkgs.config.allowUnfree = true;

  qt = {
    enable = true;
    platformTheme = "gtk";
    style.package = pkgs.adwaita-qt;
    style.name = "adwaita-dark";
  };

  gtk = {
    enable = true;
    theme.name = "Adwaita-dark";
    gtk3.extraConfig = {
      gtk-application-prefer-dark-theme = true;
      gtk-cursor-theme-name = "Adwaita";
    };
    gtk3.bookmarks = [
      "file:///home/humaid/docs"
      "file:///home/humaid/repos"
      "file:///home/humaid/inbox"
      "file:///home/humaid/inbox/web"
    ];
  };

#  xdg.configFile."vlc/vlcrc".text = ''
#[qt]
## Do not ask for network policy at start
#qt-privacy-ask=0
  #'';

  programs = {
    #go = {
    #  enable = true;
    #  package = unstable.go_1_18;
    #  goPath = "repos/go";
    #};
    ssh = {
      enable = true;
      matchBlocks."huma.id".user = "root";
      matchBlocks."rs" = {
        hostname = "zh2137.rsync.net";
        user = "zh2137";
      };
    };
    gpg = {
      enable = true;
      #homedir = "${config.home.homeDirectory}/.config/gnupg";
    };
    tmux = {
      enable = true;
      # This fixes esc delay issue with vim
      escapeTime = 0;
      # Use vi-like keys to move in scroll mode
      keyMode = "vi";
      clock24 = false;
      extraConfig = "set -g default-terminal \"xterm-256color\"";
    };
    lf = {
      enable = true;
    };
  };
}
