machine_name: { nixpkgs, nixpkgs-unstable, home-manager, system, user, overlays }:

nixpkgs.lib.nixosSystem rec {
  inherit system;

  modules =
    [ 
      {
        # Pass "unstable" as specialArgs after importing it.
        _module.args.unstable = import nixpkgs-unstable {inherit system;};
      }
      ../hosts/${machine_name}.nix
      ../hardware/${machine_name}.nix
      ../users/${user}
      {
        nixpkgs.overlays = overlays;
        networking.hostName = machine_name;

        # Let "nixos-version" know git revision of hsys.
        #system.configurationRevision = nixpkgs.lib.mkIf (self ? rev) self.rev;
      }
  
      home-manager.nixosModules.home-manager {
        home-manager.useGlobalPkgs = true;
        home-manager.useUserPackages = true;
        home-manager.users.${user} = import ../users/${user}/home-manager.nix;
      }
    ];
}
