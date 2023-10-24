machine_name: {
  lib,
  nixpkgs,
  nixpkgs-unstable,
  sops-nix,
  alejandra,
  home-manager,
  system,
  user,
  overlays,
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
    specialArgs = {inherit lib;};

    modules = [
      ../hosts/${machine_name}.nix
      ../hardware/${machine_name}.nix
      # ../users/${user}

      {
        nixpkgs.overlays = overlays;
        networking.hostName = machine_name;
        environment.systemPackages = [alejandra.defaultPackage.${system}];

        # Pass "unstable" as specialArgs after importing it.
        _module.args.unstable = unstable;

        # Let "nixos-version" know git revision of sifr.
        #system.configurationRevision = nixpkgs.lib.mkIf (self ? rev) self.rev;
      }

      sops-nix.nixosModules.sops

      home-manager.nixosModules.home-manager
      {
        home-manager.useGlobalPkgs = true;
        home-manager.useUserPackages = true;
        #home-manager.users.${user} = import ../users/${user}/home-manager.nix;
      }
    ]
    ++ (import ../modules/modules-list.nix);
  }
