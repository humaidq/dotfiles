{ pkgs, lib, nixosConfig, ... }:

{
  config = lib.mkMerge [
    # All systems have the basic configuration for neovim
    ({
      xdg.configFile."nvim/init.lua".source = ./nvim/init.lua;
      xdg.configFile."nvim/lua/options.lua".source = ./nvim/lua/options.lua;
    })

    # If dev tools are installed, we install packages (for lsp, etc)
    (lib.mkIf nixosConfig.hsys.getDevTools {
      xdg.configFile."nvim/lua/packages.lua".source = ./nvim/lua/packages.lua;
    })
  ];
}
