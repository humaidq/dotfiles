{
  lib,
  nixpkgs,
  nixpkgs-unstable,
  sops-nix,
  nixos-generators,
  alejandra,
  home-manager,
  nix-darwin,
}@inputs: let
  allModules =
    [
      home-manager.nixosModules.home-manager
      {
        home-manager.useGlobalPkgs = true;
        home-manager.useUserPackages = true;
        home-manager.sharedModules = [
          sops-nix.homeManagerModules.sops
        ];
      }
    ]
    ++ (import ../modules/modules-list.nix);
in {
  nixosSystem = machine_name: {
    system,
    vars,
    extraModules ? [],
  }: let
    pkgs = import nixpkgs {
      inherit system;
      config.allowUnfree = true;
    };
    unstable = import nixpkgs-unstable {
      inherit system;
      config.allowUnfree = true;
    };
  in
    nixpkgs.lib.nixosSystem rec {
      inherit system;
      specialArgs = {inherit vars lib unstable inputs;};

      modules =
        allModules ++
        [
          ../hosts/${machine_name}.nix
          ../hardware/${machine_name}.nix
          {
            networking.hostName = machine_name;
            environment.systemPackages = [alejandra.defaultPackage.${system}];
            system.stateVersion = "23.11";
          }
        ]
        ++ extraModules;
    };

  darwinSystem = machine_name: {vars}:
    nix-darwin.lib.darwinSystem {
      system = "aarch64-darwin";
      specialArgs = {inherit vars lib;};
      modules = [
        ../hosts/${machine_name}.nix

        home-manager.darwinModules.home-manager
        {
          home-manager.useGlobalPkgs = true;
          home-manager.useUserPackages = true;
        }
        ../modules/options.nix
        ../modules/shell
      ];
    };

  nixosGenerate = machine_name: {
    system,
    vars,
    format,
    customFormats ? {},
    extraModules ? [],
  }: let
    pkgs = import nixpkgs {
      inherit system;
      config.allowUnfree = true;
    };
    unstable = import nixpkgs-unstable {
      inherit system;
      config.allowUnfree = true;
    };
  in
    nixos-generators.nixosGenerate rec {
      inherit system format customFormats;
      specialArgs = {inherit vars lib unstable;};

      modules =
        [
          ../hosts/${machine_name}.nix
          {
            networking.hostName = machine_name;
            environment.systemPackages = [alejandra.defaultPackage.${system}];
          }
        ]
        ++ allModules
        ++ extraModules;
    };
}
