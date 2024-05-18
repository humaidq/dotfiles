{
  description = "sifr is a declarative system configuration built by Humaid";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    nixpkgs-unstable.url = "github:nixos/nixpkgs/nixpkgs-unstable";
    nixos-hardware.url = "github:nixos/nixos-hardware";
    nur.url = "github:nix-community/NUR";

    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    nixos-generators = {
      url = "github:nix-community/nixos-generators";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    alejandra = {
      url = "github:kamadorueda/alejandra/3.0.0";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    nix-darwin = {
      url = "github:LnL7/nix-darwin/master";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = inputs @ {
    self,
    home-manager,
    nixpkgs,
    nixpkgs-unstable,
    nixos-hardware,
    nixos-generators,
    sops-nix,
    nur,
    alejandra,
    nix-darwin,
    ...
  }: let
    vars = {
      user = "humaid";
    };
    mksystem = import ./lib/mksystem.nix {
      inherit (nixpkgs) lib;
      inherit nixpkgs nixpkgs-unstable home-manager alejandra sops-nix nixos-generators nix-darwin;
    };
  in rec {
    # System Configurations for NixOS
    nixosConfigurations = {
      # System that runs on a VM on Macbook Pro, my main system
      goral = mksystem.nixosSystem "goral" {
        inherit vars;
        system = "aarch64-linux";
      };

      # Sytem that runs on Thinkpad T590
      serow = mksystem.nixosSystem "serow" {
        inherit vars;
        system = "x86_64-linux";
      };

      # System that runs on Vultr cloud, hosting huma.id
      duisk = mksystem.nixosSystem "duisk" {
        inherit vars;
        system = "x86_64-linux";
      };

      # System that runs on my work laptop
      tahr = mksystem.nixosSystem "tahr" {
        inherit vars;
        system = "x86_64-linux";
      };

      boerbok = nixpkgs.lib.nixosSystem {
        specialArgs = {inherit nixos-hardware vars; };
        modules = [ ./hosts/boerbok.nix ];
      };
    };

    # System Configurations for macOS
    darwinConfigurations = {
      takin = mksystem.darwinSystem "takin" {
        inherit vars;
      };
    };

    # Generators for aarch64
    packages.aarch64-linux = let
      system = "aarch64-linux";
    in {
      argali = mksystem.nixosGenerate "argali" {
        inherit vars system;
        format = "sd-aarch64";
        extraModules = [
          nixos-hardware.nixosModules.raspberry-pi-4
        ];
      };
    };

    # Generators for riscv64
    packages.riscv64-linux = {
      boerbok-sd = nixosConfigurations.boerbok.config.system.build.sdImage;
    };
  };
}
