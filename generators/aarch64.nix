{
  lib,
  inputs,
  nixpkgs,
  nixos-generators,
  nixpkgs-unstable,
  sops-nix,
  alejandra,
  home-manager,
}: {
  vmware = nixos-generators.nixosGenerate {
    system = "aarch64-linux";
    modules = [
      ../hosts/install.nix
      ../users/humaid
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
      ../hosts/rpi.nix
      ../users/humaid
      home-manager.nixosModules.home-manager
      {
        home-manager.useGlobalPkgs = true;
        home-manager.useUserPackages = true;
        home-manager.users.humaid = import ../users/humaid/home-manager.nix;
      }
    ];
    format = "sd-aarch64";
  };
}
