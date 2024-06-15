{
  description = "sifr is a declarative system configuration built by Humaid";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-24.05";
    nixos-hardware.url = "github:nixos/nixos-hardware";
    #nur.url = "github:nix-community/NUR";
    nix-topology.url = "github:oddlama/nix-topology";
    flake-parts.url = "github:hercules-ci/flake-parts";
    flake-root.url = "github:srid/flake-root";
    stylix.url = "github:danth/stylix";

    treefmt-nix = {
      url = "github:numtide/treefmt-nix";
    };

    flake-compat = {
      url = "github:inclyc/flake-compat";
      flake = false;
    };

    nix-index-database = {
      url = "github:nix-community/nix-index-database";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    home-manager = {
      url = "github:nix-community/home-manager/release-24.05";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    nixos-generators = {
      url = "github:nix-community/nixos-generators";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    nixvim = {
      url = "github:nix-community/nixvim";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.home-manager.follows = "home-manager";
      inputs.treefmt-nix.follows = "treefmt-nix";
      inputs.nix-darwin.follows = "nix-darwin";
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
    nixpkgs,
    flake-parts,
    ...
  }:
    flake-parts.lib.mkFlake {
      inherit inputs;
      specialArgs = {
        inherit (nixpkgs) lib;
        vars = {
          user = "humaid";
        };
      };
    } {
      imports = [
        inputs.flake-root.flakeModule
        inputs.treefmt-nix.flakeModule
        ./hosts
      ];
      flake = {
        nixosModules = {
          sifrOS = import ./modules;
        };
      };
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
        "riscv64-linux"
      ];
      debug = true;
      perSystem = {
        config,
        system,
        pkgs,
        ...
      }: {
        devShells.default = pkgs.mkShell {
          inputsFrom = [config.flake-root.devShell];
        };
        treefmt.config = {
          package = pkgs.treefmt;
          inherit (config.flake-root) projectRootFile;
          programs = {
            alejandra.enable = true;
            deadnix.enable = true;
            statix.enable = true;
            shellcheck.enable = true;
          };
        };
        formatter = config.treefmt.build.wrapper;
        _module.args.pkgs = import inputs.nixpkgs {
          inherit system inputs;
          config.allowUnfree = true;
        };
      };
    };
}
