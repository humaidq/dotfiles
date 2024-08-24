{
  inputs,
  self,
  lib,
  vars,
  ...
}:
{
  flake =
    let
      specialArgs = {
        inherit self inputs vars;
      };
    in
    {
      nixosModules = {
        host-goral = import ./goral;
        host-serow = import ./serow;
        host-duisk = import ./duisk;
        host-tahr = import ./tahr;
        host-boerbok = import ./boerbok;
        host-argali = import ./argali;
        host-arkelli = import ./arkelli;

        # Generators hosts
        host-rpi4-bootstrap = import ./rpi4-bootstrap.nix;
        host-rpi5-bootstrap = import ./rpi5-bootstrap.nix;
        host-x86-installer = import ./x86-installer.nix;
      };
      nixosConfigurations = {
        goral = lib.nixosSystem {
          inherit specialArgs;
          modules = [ self.nixosModules.host-goral ];
        };
        serow = lib.nixosSystem {
          inherit specialArgs;
          modules = [ self.nixosModules.host-serow ];
        };
        duisk = lib.nixosSystem {
          inherit specialArgs;
          modules = [ self.nixosModules.host-duisk ];
        };
        tahr = lib.nixosSystem {
          inherit specialArgs;
          modules = [ self.nixosModules.host-tahr ];
        };
        boerbok = lib.nixosSystem {
          inherit specialArgs;
          modules = [ self.nixosModules.host-boerbok ];
        };
        argali = lib.nixosSystem {
          inherit specialArgs;
          modules = [ self.nixosModules.host-argali ];
        };
        arkelli = lib.nixosSystem {
          inherit specialArgs;
          modules = [ self.nixosModules.host-arkelli ];
        };
      };

      packages.x86_64-linux = {
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

        boerbok-sd-from-x86_64 =
          (lib.nixosSystem {
            inherit specialArgs;
            modules = [
              self.nixosModules.host-boerbok
              {

                nixpkgs.buildPlatform = "x86_64-linux";
              }
            ];
          }).config.system.build.sdImage;
      };

      packages.aarch64-linux = {
        rpi4-bootstrap = inputs.nixos-generators.nixosGenerate {
          format = "sd-aarch64";
          system = "aarch64-linux";
          inherit specialArgs;
          modules = [
            self.nixosModules.host-rpi4-bootstrap
            { sdImage.compressImage = false; }
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

              nixpkgs.buildPlatform = "x86_64-linux";
            }
          ];
        };

      };

      hydraJobs = {
        x86_64-linux = {
          serow = self.nixosConfigurations.serow.config.system.build.toplevel;
          tahr = self.nixosConfigurations.tahr.config.system.build.toplevel;
          duisk = self.nixosConfigurations.duisk.config.system.build.toplevel;

          boerbok-sd-from-x86_64 = self.packages.x86_64-linux.boerbok-sd-from-x86_64;
        };
        aarch64-linux = {
          rpi4-bootstrap = self.packages.x86_64-linux.rpi4-bootstrap;
          rpi5-bootstrap = self.packages.x86_64-linux.rpi5-bootstrap;
          goral = self.nixosConfigurations.goral.config.system.build.toplevel;
          argali = self.nixosConfigurations.argali.config.system.build.toplevel;
          arkelli = self.nixosConfigurations.arkelli.config.system.build.toplevel;
        };
        riscv64-linux = {
          boerbok = self.nixosConfigurations.boerbok.config.system.build.toplevel;
        };
      };
    };
}
