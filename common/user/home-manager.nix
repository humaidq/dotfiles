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
  ];

  home.stateVersion = "21.11";
  xdg = {
    enable = true;
    mimeApps.enable = true;
    #portal = {
    #  enable = true;
    #  extraPortals = with pkgs; [
    #    xdg-desktop-portal-wlr
    #    xdg-desktop-portal-gtk
    #  ];
    #  gtkUsePortal = true;
    #};
    #mime.defaultApplications = {
    #  image/png = [
    #    "img.desktop"
    #  ];

    #};
    userDirs = {
      enable = true;
      createDirectories = false;
      desktop = "$HOME";
      documents = "$HOME/docs";
      download = "$HOME/inbox/web";
      music = "$HOME/docs/music";
      pictures = "$HOME/docs/pics";
      videos = "$HOME/docs/vids";
      publicShare = "";
      templates = "";
    };
    configFile."user-dirs.locale".text = "en_GB";
  };


  gtk = {
    enable = true;
    theme.name = "Adwaita-dark";
    gtk3.extraConfig = {
      gtk-application-prefer-dark-theme = true;
      gtk-cursor-theme-name = "Adwaita";
    };
  };

  programs = {
    go = {
      enable = true;
      goPath = "repos/go";
    };
    ssh = {
      enable = true;
      matchBlocks."huma.id".user = "root";
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
  };
}
