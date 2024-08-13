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
    #host-boerbok = import ./boerbok;
    host-argali = import ./argali;
    host-arkelli = import ./arkelli;

    # Generators hosts
    host-rpi4-bootstrap = import ./rpi4-bootstrap.nix;
    host-rpi5-bootstrap = import ./rpi5-bootstrap.nix;
    host-x86-installer = import ./x86-installer.nix;
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
    #boerbok = lib.nixosSystem {
    #  inherit specialArgs;
    #  modules = [self.nixosModules.host-boerbok];
    #};
    argali = lib.nixosSystem {
      inherit specialArgs;
      modules = [self.nixosModules.host-argali];
    };
    arkelli = lib.nixosSystem {
      inherit specialArgs;
      modules = [self.nixosModules.host-arkelli];
    };
  };

  flake.packages.x86_64-linux = let
    specialArgs = {
      inherit self inputs vars;
    };
  in {
    installer = inputs.nixos-generators.nixosGenerate {
      format = "iso";
      system = "x86_64-linux";
      inherit specialArgs;
      modules = [
        self.nixosModules.host-x86-installer
        {
          isoImage = {
            squashfsCompression = "zstd -Xcompression-level 6";
          };
        }
      ];
    };
  };

  flake.packages.aarch64-linux = let
    specialArgs = {
      inherit self inputs vars;
    };
  in {
    rpi4-bootstrap = inputs.nixos-generators.nixosGenerate {
      format = "sd-aarch64";
      system = "aarch64-linux";
      inherit specialArgs;
      modules = [
        self.nixosModules.host-rpi4-bootstrap
        {
          sdImage.compressImage = false;
        }
      ];
    };
    rpi5-bootstrap = inputs.nixos-generators.nixosGenerate {
      format = "sd-aarch64";
      system = "aarch64-linux";
      inherit specialArgs;
      modules = [
        self.nixosModules.host-rpi5-bootstrap
        {
          sdImage.compressImage = false;
        }
      ];
    };
  };
  flake.packages.riscv64-linux = {
    #boerbok-sd = self.nixosConfigurations.boerbok.config.system.build.sdImage;
  };
}
