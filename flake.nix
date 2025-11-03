{
  description = "sifr is a declarative system configuration built by Humaid";

  nixConfig = {
    extra-substituters = [ "https://cache.huma.id" ];
    extra-trusted-public-keys = [ "cache.huma.id:YJG69WGZ8iUFwrZFrXbLY50m9jXNmJUas1vwtksUFFM=" ];
    allow-import-from-derivation = false;
  };

  inputs = {
    # Personal imports
    humaid-site.url = "github:humaidq/huma.id";

    # External imports
    nixpkgs.url = "github:nixos/nixpkgs/nixos-25.05";
    nixpkgs-unstable.url = "github:nixos/nixpkgs/nixos-unstable";
    nixos-hardware.url = "github:nixos/nixos-hardware";
    nixos-hardware-star64.url = "github:humaidq/nixos-hardware/star64";
    #nur.url = "github:nix-community/NUR";
    flake-parts.url = "github:hercules-ci/flake-parts";
    flake-root.url = "github:srid/flake-root";

    impermanence.url = "github:nix-community/impermanence";
    nix-topology.url = "github:oddlama/nix-topology";

    treefmt-nix = {
      url = "github:numtide/treefmt-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    flake-compat = {
      url = "github:inclyc/flake-compat";
      flake = false;
    };

    srvos = {
      url = "github:nix-community/srvos";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    nix-index-database = {
      url = "github:nix-community/nix-index-database";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    lanzaboote = {
      url = "github:nix-community/lanzaboote/v0.4.2";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    home-manager = {
      url = "github:nix-community/home-manager/release-25.05";
      #url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    nixos-generators = {
      url = "github:nix-community/nixos-generators";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    nixvim = {
      url = "github:nix-community/nixvim/nixos-25.05";
      #url = "github:nix-community/nixvim";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    nix-darwin = {
      url = "github:LnL7/nix-darwin/nix-darwin-25.05";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    inputs@{ nixpkgs, flake-parts, ... }:
    flake-parts.lib.mkFlake
      {
        inherit inputs;
        specialArgs = {
          inherit (nixpkgs) lib;
          vars = {
            user = "humaid";
          };
        };
      }
      {
        imports = [
          inputs.flake-root.flakeModule
          inputs.treefmt-nix.flakeModule
          inputs.nix-topology.flakeModule
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
          #"riscv64-linux"
        ];
        debug = true;
        perSystem =
          {
            config,
            system,
            pkgs,
            ...
          }:
          {
            #topology.modules = [./topology/default.nix];
            _module.args = {
              pkgs = import inputs.nixpkgs {
                inherit system inputs;
                config = {
                  allowUnfree = true;
                };
                overlays = [ inputs.nix-topology.overlays.default ];
              };
            };
            devShells.default = pkgs.mkShell { inputsFrom = [ config.flake-root.devShell ]; };
            treefmt.config = {
              package = pkgs.treefmt;
              inherit (config.flake-root) projectRootFile;
              programs = {
                nixfmt.enable = true;
                nixfmt.package = pkgs.nixfmt-rfc-style;
                deadnix.enable = true;
                statix.enable = true;
                shellcheck.enable = true;
              };
            };
            formatter = config.treefmt.build.wrapper;
          };
      };
}
