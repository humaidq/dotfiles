{
  lib,
  inputs,
  nixpkgs,
  nixos-generators,
  nixpkgs-unstable,
  sops-nix,
  alejandra,
  home-manager,
}: {
  x86-iso = nixos-generators.nixosGenerate {
    system = "x86_64-linux";
    modules = [
      ../hosts/minimal.nix
      ../users/humaid
      home-manager.nixosModules.home-manager
      {
        home-manager.useGlobalPkgs = true;
        home-manager.useUserPackages = true;
        home-manager.users.humaid = import ../users/humaid/home-manager.nix;
      }
    ];
    customFormats.standalone-iso = import ../lib/standalone-iso.nix {inherit nixpkgs;};
    format = "standalone-iso";
  };
  x86-docker = nixos-generators.nixosGenerate {
    system = "x86_64-linux";
    modules = [
      ../hosts/docker.nix
      ../users/humaid
      home-manager.nixosModules.home-manager
      {
        home-manager.useGlobalPkgs = true;
        home-manager.useUserPackages = true;
        home-manager.users.humaid = import ../users/humaid/home-manager.nix;
      }
    ];
    format = "docker";
  };
  x86-installer = nixos-generators.nixosGenerate {
    system = "x86_64-linux";
    modules = [
      ../hosts/install.nix
      ../users/humaid
      home-manager.nixosModules.home-manager
      {
        home-manager.useGlobalPkgs = true;
        home-manager.useUserPackages = true;
        home-manager.users.humaid = import ../users/humaid/home-manager.nix;
      }
    ];
    customFormats.standalone-iso = import ../lib/standalone-iso.nix {inherit nixpkgs;};
    format = "standalone-iso";
  };
}
