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
  }: {
    nixosConfigurations = (
      import ./hosts {
        inherit (nixpkgs) lib;
        inherit inputs nixpkgs nixpkgs-unstable home-manager sops-nix alejandra;
      }
    );

    # Generators (x86_64 and aarch64)
    packages.x86_64-linux = (
      import ./generators/x86.nix {
        inherit (nixpkgs) lib;
        inherit inputs nixpkgs nixos-generators nixpkgs-unstable home-manager sops-nix alejandra;
      }
    );
    packages.aarch64-linux = (
      import ./generators/aarch64.nix {
        inherit (nixpkgs) lib;
        inherit inputs nixpkgs nixos-generators nixpkgs-unstable home-manager sops-nix alejandra;
      }
    );
  };
}
