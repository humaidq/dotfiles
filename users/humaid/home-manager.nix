{ nixosConfig, config, pkgs, lib, ... }:

{
  imports = [
    ./firefox.nix
    ./nvim.nix
    ./emacs.nix
    ./shell.nix
    ./scripts.nix
    ./git.nix
    ./xdg.nix
    ./graphical.nix
  ];

  home.stateVersion = "21.11";
  home.sessionPath = [ "$HOME/.bin" ];

  nixpkgs.config.allowUnfree = true;

  programs = {
    ssh = {
      enable = true;
      matchBlocks."huma.id".user = "root";
      matchBlocks."rs" = {
        hostname = "zh2137.rsync.net";
        user = "zh2137";
      };
      matchBlocks."*" = {
        extraOptions.IdentityAgent = "~/.1password/agent.sock";
      };
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
