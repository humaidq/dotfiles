{ pkgs, lib, ... }:

{
  # Custom neovim setup
  # We use paq for managing neovim packages.
  xdg.dataFile."nvim/site/pack/paqs/start/paq-nvim".source = fetchGit {
    url = "https://github.com/savq/paq-nvim";
    rev = "6caab059bc15cc61afc7aa7e0515ee06eb550bcf";
  };

  # Symlink our neovim configuration files
  xdg.configFile."nvim/init.lua".source = ./nvim/init.lua;
  xdg.configFile."nvim/lua".source = ./nvim/lua;
}
