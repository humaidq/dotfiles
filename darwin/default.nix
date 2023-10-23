{
  lib,
  inputs,
  nixpkgs,
  nix-darwin,
  nixpkgs-unstable,
  sops-nix,
  alejandra,
  home-manager,
}: let
  user = "humaid";
in {
  takin = nix-darwin.lib.darwinSystem {
    system = "aarch64-darwin";
    modules = [
      ../hosts/takin.nix
      
      home-manager.darwinModules.home-manager {
        home-manager.useGlobalPkgs = true;
        home-manager.useUserPackages = true;
      }
    ];
  };
}
