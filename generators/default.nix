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
  packages.x86_64-linux = (
    import ./x86.nix {
      inherit (nixpkgs) lib;
      inherit inputs nixpkgs nixpkgs-unstable home-manager sops-nix alejandra;
    }
  );
  packages.aarch64-linux = (
    import ./aarch64.nix {
      inherit (nixpkgs) lib;
      inherit inputs nixpkgs nixpkgs-unstable home-manager sops-nix alejandra;
    }
  );
}
