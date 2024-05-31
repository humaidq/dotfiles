{
  inputs,
  self,
  lib,
  vars,
  ...
}: {
  flake.nixosModules = {
    host-goral = import ./goral;
    host-serow = import ./serow;
    host-duisk = import ./duisk;
    host-tahr = import ./tahr;
    host-boerbok = import ./boerbok;
    host-argali = import ./argali;

    host-rpi4-bootstrap = import ./rpi4-bootstrap.nix;
  };
  flake.nixosConfigurations = let
    specialArgs = {
      inherit self inputs vars;
    };
  in {
    goral = lib.nixosSystem {
      inherit specialArgs;
      modules = [self.nixosModules.host-goral];
    };
    serow = lib.nixosSystem {
      inherit specialArgs;
      modules = [self.nixosModules.host-serow];
    };
    duisk = lib.nixosSystem {
      inherit specialArgs;
      modules = [self.nixosModules.host-duisk];
    };
    tahr = lib.nixosSystem {
      inherit specialArgs;
      modules = [self.nixosModules.host-tahr];
    };
    boerbok = lib.nixosSystem {
      inherit specialArgs;
      modules = [self.nixosModules.host-boerbok];
    };
    argali = lib.nixosSystem {
      inherit specialArgs;
      modules = [self.nixosModules.host-argali];
    };
    rpi4-bootstrap = lib.nixosSystem {
      inherit specialArgs;
      modules = [self.nixosModules.host-rpi4-bootstrap];
    };
  };
}
