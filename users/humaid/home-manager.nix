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
      extraConfig = "set shell sh";
      commands = {
        open = ''
          ''${{
        case $(file --mime-type "$(readlink -f $f)" -b) in
          text/*|application/json|inode/x-empty) $EDITOR $fx ;;
          application/*) nvim $fx ;;
          *) for f in $fx; do setsid $OPENER $f > /dev/null 2> /dev/null & done ;;
        esac
        }}
        '';
      };
      cmdKeybindings = {
        "<enter>" = "open";
      };
    };
  };

  # creating this empty file enables redshift for this user
  xdg.configFile."systemd/user/default.target.wants/redshift.service".text = "";
}
