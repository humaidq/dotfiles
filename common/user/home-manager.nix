{ nixosConfig, config, pkgs, lib, ... }:

let
  #nur = import (builtins.fetchTarball "https://github.com/nix-community/NUR/archive/master.tar.gz") {
  #  inherit pkgs;
  #};
in
{
  imports = [
    ./firefox.nix
    ./gnome.nix
    ./mate.nix
    ./nvim.nix
    ./shell.nix
    ./scripts.nix
    ./git.nix
    ./xdg.nix
    ./rofi.nix
    ./graphical.nix
  ];

  home.stateVersion = "21.11";
  home.sessionPath = [ "$HOME/.bin" ];

  nixpkgs.config.allowUnfree = true;

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
