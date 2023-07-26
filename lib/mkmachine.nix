machine_name: { nixpkgs, home-manager, system, user, overlays }:

nixpkgs.lib.nixosSystem rec {
  inherit system;
  modules =
    [ 
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
