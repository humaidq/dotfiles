{
  lib,
  inputs,
  nixpkgs,
  nixpkgs-unstable,
  sops-nix,
  alejandra,
  home-manager,
}: let
  user = "humaid";
  mkMachine = import ../lib/mkmachine.nix;
  overlays = [];
in {
  # System that runs on a VM on Macbook Pro, my main system
  goral = mkMachine "goral" {
    inherit overlays nixpkgs nixpkgs-unstable home-manager alejandra sops-nix;
    system = "aarch64-linux";
    user = user;
  };

  # Sytem that runs on Thinkpad T590
  serow = mkMachine "serow" {
    inherit overlays nixpkgs nixpkgs-unstable home-manager alejandra sops-nix;
    system = "x86_64-linux";
    user = user;
  };

  # System that runs on Vultr cloud, hosting huma.id
  duisk = mkMachine "duisk" {
    inherit overlays nixpkgs nixpkgs-unstable home-manager alejandra sops-nix;
    system = "x86_64-linux";
    user = user;
  };

  # System that runs on my work laptop
  tahr = mkMachine "tahr" {
    inherit overlays nixpkgs nixpkgs-unstable home-manager alejandra sops-nix;
    system = "x86_64-linux";
    user = user;
  };

  # System that runs on my temporary Dell laptop
  capra = mkMachine "capra" {
    inherit overlays nixpkgs nixpkgs-unstable home-manager alejandra sops-nix;
    system = "x86_64-linux";
    user = user;
  };
}
