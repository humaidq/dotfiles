{
  config,
  pkgs,
  home-manager,
  unstable,
  lib,
  ...
}:
with lib; let
  cfg = config.sifr.applications;
in {
  options.sifr.applications.neovim.enable = mkOption {
    description = "Enables neovim configurations";
    type = types.bool;
    default = true;
  };
  config = mkMerge [
    (mkIf cfg.neovim.enable {
      home-manager.users.humaid.xdg.configFile = {
        "nvim/init.lua".source = ./nvim/init.lua;
        "nvim/lua/options.lua".source = ./nvim/lua/options.lua;
      };
    })
    (mkIf (cfg.neovim.enable && config.sifr.development.enable) {
      home-manager.users.humaid.xdg.configFile."nvim/lua/packages.lua".source = ./nvim/lua/packages.lua;
    })
  ];
}
