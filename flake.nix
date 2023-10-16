{
  description = "sifr is a declarative system configuration built by Humaid";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-23.05";
    nixpkgs-unstable.url = "github:nixos/nixpkgs/nixpkgs-unstable";
    nixos-hardware.url = "github:nixos/nixos-hardware";
    nur.url = "github:nix-community/NUR";

    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    home-manager = {
      url = "github:nix-community/home-manager/release-23.05";
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
    ...
  }: let
    pkgs = import <nixpkgs> {};
    mkMachine = import ./lib/mkmachine.nix;
    overlays = [];
  in {
    #formatter.${system} = alejandra.defaultPackage.${system};

    # System that runs on a VM on Macbook Pro, my main system
    nixosConfigurations.goral = mkMachine "goral" {
      inherit overlays nixpkgs nixpkgs-unstable home-manager;
      system = "aarch64-linux";
      user   = "humaid";
    };

    # Sytem that runs on Thinkpad
    nixosConfigurations.serow = mkMachine "serow" {
      inherit overlays nixpkgs nixpkgs-unstable home-manager;
      system = "x86_64-linux";
      user   = "humaid";
    };

    # System that runs on Vultr cloud hosting huma.id
    nixosConfigurations.duisk = mkMachine "duisk" {
      inherit overlays nixpkgs nixpkgs-unstable home-manager;
      system = "x86_64-linux";
      user   = "humaid";
    };

    # System that runs on my work laptop
    nixosConfigurations.tahr = mkMachine "tahr" {
      inherit overlays nixpkgs nixpkgs-unstable home-manager;
      system = "x86_64-linux";
      user   = "humaid";
    };
    
    # System that runs on my temporary Dell laptop
    nixosConfigurations.capra = mkMachine "capra" {
      inherit overlays nixpkgs nixpkgs-unstable home-manager;
      system = "x86_64-linux";
      user   = "humaid";
    };

    packages.x86_64-linux = {
      x86-iso = nixos-generators.nixosGenerate {
        system = "x86_64-linux";
        modules = [
          ./hosts/minimal.nix
          ./users/humaid
          home-manager.nixosModules.home-manager {
            home-manager.useGlobalPkgs = true;
            home-manager.useUserPackages = true;
            home-manager.users.humaid = import ./users/humaid/home-manager.nix;
          }
        ];
        customFormats.standalone-iso = import ./lib/standalone-iso.nix {inherit nixpkgs;};
        format = "standalone-iso";
      };
      x86-docker = nixos-generators.nixosGenerate {
        system = "x86_64-linux";
        modules = [
          ./hosts/docker.nix
          ./users/humaid
          home-manager.nixosModules.home-manager {
            home-manager.useGlobalPkgs = true;
            home-manager.useUserPackages = true;
            home-manager.users.humaid = import ./users/humaid/home-manager.nix;
          }
        ];
        format = "docker";
      };
      x86-installer = nixos-generators.nixosGenerate {
        system = "x86_64-linux";
        modules = [
          ./hosts/install.nix
          ./users/humaid
          home-manager.nixosModules.home-manager {
            home-manager.useGlobalPkgs = true;
            home-manager.useUserPackages = true;
            home-manager.users.humaid = import ./users/humaid/home-manager.nix;
          }
        ];
        customFormats.standalone-iso = import ./lib/standalone-iso.nix {inherit nixpkgs;};
        format = "standalone-iso";
      };
    };
    packages.aarch64-linux = {
      vmware = nixos-generators.nixosGenerate {
        system = "aarch64-linux";
        modules = [
          ./hosts/install.nix
          ./users/humaid
          {
            sifr = {
              enablei3 = true;
            };
          }
        ];
        format = "vmware";
      };
      rpi4 = nixos-generators.nixosGenerate {
        system = "aarch64-linux";
        modules = [
          ./hosts/rpi.nix
          ./users/humaid
          home-manager.nixosModules.home-manager {
            home-manager.useGlobalPkgs = true;
            home-manager.useUserPackages = true;
            home-manager.users.humaid = import ./users/humaid/home-manager.nix;
          }
        ];
        format = "sd-aarch64";
      };
    };
  };
}
