{ pkgs, lib, ... }:

{
  # Custom neovim setup
  # We use paq for managing neovim packages.
  xdg.dataFile."nvim/site/pack/packer/start/packer.nvim".source = fetchGit {
    url = "https://github.com/wbthomason/packer.nvim";
    rev = "4dedd3b08f8c6e3f84afbce0c23b66320cd2a8f2";
  };

  # Symlink our neovim configuration files
  xdg.configFile."nvim/init.lua".source = ./nvim/init.lua;
  xdg.configFile."nvim/lua".source = ./nvim/lua;
}
