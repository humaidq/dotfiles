{
  description = "sifr is a declarative system configuration built by Humaid";

  nixConfig = {
    show-trace = true;
    lazy-trees = true;
    warn-dirty = false;

    experimental-features = [
      "flakes"
      "nix-command"
      "pipe-operators"
      "auto-allocate-uids"
    ];
    extra-substituters = [ "https://cache.huma.id" ];
    extra-trusted-public-keys = [ "cache.huma.id:YJG69WGZ8iUFwrZFrXbLY50m9jXNmJUas1vwtksUFFM=" ];
    allow-import-from-derivation = false;
  };

  inputs = {
    # Personal imports
    humaid-site = {
      url = "github:humaidq/huma.id";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    groundwave = {
      url = "git+https://git.alq.ae/humaid/groundwave";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # Our licensed TX-02 Berkeley Mono build; plain OTFs, not a flake.
    berkeley-font = {
      url = "git+https://git.alq.ae/humaid/berkeley-font";
      flake = false;
    };
    fleeti = {
      url = "github:ai4os-ae/fleeti";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # A TII (Ghaf) debugging-challenge platform, mirrored onto the forge here
    # because the upstream on GitHub is somebody else's account and this
    # deployment should not break when that repository moves. The default
    # branch there is `humaid-hosting`, which is the one carrying the Nix
    # packaging; `main` has none, so the URL deliberately takes the default
    # rather than pinning a ref.
    debug-platform = {
      url = "git+https://git.alq.ae/humaid/DebugPlatform";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    blueshot = {
      url = "github:humaidq/blueshot";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # External imports
    nixpkgs.url = "github:nixos/nixpkgs/nixos-26.05";
    nixpkgs-unstable.url = "github:nixos/nixpkgs/nixos-unstable";
    nixos-hardware.url = "github:nixos/nixos-hardware";
    nixos-hardware-star64.url = "github:humaidq/nixos-hardware/star64";
    #nur.url = "github:nix-community/NUR";
    flake-parts.url = "github:hercules-ci/flake-parts";
    flake-root.url = "github:srid/flake-root";

    impermanence.url = "github:nix-community/impermanence";

    helium = {
      url = "github:schembriaiden/helium-browser-nix-flake";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # UniFi OS Server, run as a podman container. Unpacks Ubiquiti's own
    # (unfree, binary) installer, so the build needs binwalk from our nixpkgs —
    # 3.1.0 here, which is the CLI the packaging expects.
    unifi-os-server = {
      url = "github:rcambrj/unifi-os-server";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    treefmt-nix = {
      url = "github:numtide/treefmt-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    flake-compat = {
      url = "github:inclyc/flake-compat";
      flake = false;
    };

    srvos = {
      url = "github:nix-community/srvos/46b488a30af5c61c98fe251911fdcdcead3110ee";
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
      url = "github:nix-community/lanzaboote/v1.0.0";
      #inputs.nixpkgs.follows = "nixpkgs";
    };

    home-manager = {
      url = "github:nix-community/home-manager/release-26.05";
      #url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    nixvim = {
      url = "github:nix-community/nixvim/nixos-26.05";
    };

    nix-darwin = {
      url = "github:LnL7/nix-darwin/nix-darwin-26.05";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    inputs@{ nixpkgs, flake-parts, ... }:
    let
      flakeOutputs =
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
              ./hosts
            ];
            systems = [
              "x86_64-linux"
              "aarch64-linux"
              "aarch64-darwin"
              #"riscv64-linux"
            ];
            perSystem =
              {
                config,
                lib,
                system,
                pkgs,
                ...
              }:
              {
                _module.args = {
                  pkgs = import inputs.nixpkgs {
                    inherit system inputs;
                    config = {
                      allowUnfree = true;
                    };
                  };
                };
                checks = import ./tests { inherit lib pkgs; };
                devShells.default = pkgs.mkShell { inputsFrom = [ config.flake-root.devShell ]; };
                treefmt.config = {
                  package = pkgs.treefmt;
                  inherit (config.flake-root) projectRootFile;
                  programs = {
                    nixfmt.enable = true;
                    nixfmt.package = pkgs.nixfmt;
                    deadnix.enable = true;
                    statix.enable = true;
                    shellcheck.enable = true;
                  };
                };
                formatter = config.treefmt.build.wrapper;
              };
          };
    in
    flakeOutputs
    // {
      nixosModules = flakeOutputs.nixosModules // {
        sifrOS = {
          base = import ./modules/base;
          desktop = import ./modules/desktop;
          installer = import ./modules/installer;
          laptop = import ./modules/laptop;
          router = import ./modules/router;
          security = import ./modules/security;
          server = import ./modules/server;
          persist = import ./modules/persist;
          personal = {
            amateur = import ./modules/personal/amateur.nix;
            base = import ./modules/personal/base.nix;
            dns = import ./modules/personal/dns.nix;
            focusMode = import ./modules/personal/focus-mode;
            kids = import ./modules/personal/kids.nix;
            networking = import ./modules/personal/networking;
            o11y = import ./modules/personal/o11y;
            receipt = import ./modules/personal/receipt.nix;
            research = import ./modules/personal/research.nix;
            sdrNoise = import ./modules/personal/sdr-noise.nix;
            securityResearch = import ./modules/personal/security-research.nix;
            university = import ./modules/personal/university.nix;
            work = import ./modules/personal/work.nix;
          };
        };
      };
    };
}
