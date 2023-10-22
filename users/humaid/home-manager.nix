{
  nixosConfig,
  config,
  pkgs,
  lib,
  ...
}: {
  imports = [
    ./firefox.nix
    ./nvim.nix
    ./emacs.nix
    ./shell.nix
    ./scripts.nix
    ./git.nix
    ./xdg.nix
    ./graphical.nix
    ./misc.nix
  ];

  home.stateVersion = "21.11";
  home.sessionPath = ["$HOME/.bin"];

  nixpkgs.config.allowUnfree = true;
}
