{ pkgs, lib, ... }:

{
  # Symlink our neovim configuration files
  xdg.configFile."nvim/init.lua".source = ./nvim/init.lua;
  xdg.configFile."nvim/lua".source = ./nvim/lua;
}
