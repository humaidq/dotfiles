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
      baseArgs = { inherit self inputs vars; };
      homeServerSystem = lib.nixosSystem {
        specialArgs = baseArgs;
        modules = [
          self.nixosModules.host-oreamnos
          #inputs.srvos.nixosModules.server
          inputs.srvos.nixosModules.desktop
          inputs.srvos.nixosModules.mixins-nix-experimental
        ];
      };
      homeServerDomains = builtins.attrNames homeServerSystem.config.services.nginx.virtualHosts;
      specialArgs = baseArgs // {
        vars = baseArgs.vars // {
          inherit homeServerDomains;
        };
      };
    in
    {
      nixosModules = {
        host-oreamnos = import ./oreamnos;
        host-serow = import ./serow;
        host-anoa = import ./anoa;
        host-duisk = import ./duisk;
        host-lighthouse = import ./lighthouse;
        #host-boerbok = import ./boerbok;
        #host-argali = import ./argali;
        #host-arkelli = import ./arkelli;

        # Generators hosts
        host-rpi4-bootstrap = import ./rpi4-bootstrap.nix;
        host-rpi5-bootstrap = import ./rpi5-bootstrap.nix;
        host-x86-installer = import ./x86-installer.nix;
      };

      nixosConfigurations = {
        oreamnos = lib.nixosSystem {
          inherit specialArgs;
          modules = [
            self.nixosModules.host-oreamnos
            inputs.srvos.nixosModules.server
            inputs.srvos.nixosModules.mixins-nix-experimental
          ];
        };
        serow = lib.nixosSystem {
          inherit specialArgs;
          modules = [
            self.nixosModules.host-serow
            inputs.srvos.nixosModules.desktop
            inputs.srvos.nixosModules.mixins-nix-experimental
          ];
        };
        anoa = lib.nixosSystem {
          inherit specialArgs;
          modules = [
            self.nixosModules.host-anoa
            inputs.srvos.nixosModules.desktop
            inputs.srvos.nixosModules.mixins-nix-experimental
          ];
        };
        duisk = lib.nixosSystem {
          inherit specialArgs;
          modules = [
            self.nixosModules.host-duisk
            inputs.srvos.nixosModules.server
            inputs.srvos.nixosModules.hardware-vultr-vm
            inputs.srvos.nixosModules.mixins-nix-experimental
          ];
        };
        lighthouse = lib.nixosSystem {
          inherit specialArgs;
          modules = [
            self.nixosModules.host-lighthouse
            inputs.srvos.nixosModules.server
            inputs.srvos.nixosModules.hardware-vultr-vm
            inputs.srvos.nixosModules.mixins-nix-experimental
          ];
        };
        #boerbok = lib.nixosSystem {
        #  inherit specialArgs;
        #  modules = [ self.nixosModules.host-boerbok ];
        #};
        #argali = lib.nixosSystem {
        #  inherit specialArgs;
        #  modules = [ self.nixosModules.host-argali ];
        #};
        #arkelli = lib.nixosSystem {
        #  inherit specialArgs;
        #  modules = [ self.nixosModules.host-arkelli ];
        #};
      };

      packages.x86_64-linux = {
        installer = inputs.nixos-generators.nixosGenerate {
          format = "iso";
          system = "x86_64-linux";
          inherit specialArgs;
          modules = [
            self.nixosModules.host-x86-installer
            inputs.srvos.nixosModules.mixins-nix-experimental
            {
              isoImage = {
                squashfsCompression = "zstd -Xcompression-level 6";
              };
            }
          ];
        };

        #boerbok-sd-from-x86_64 =
        #  (lib.nixosSystem {
        #    inherit specialArgs;
        #    modules = [
        #      self.nixosModules.host-boerbok
        #      {

        #        nixpkgs.buildPlatform = "x86_64-linux";
        #      }
        #    ];
        #  }).config.system.build.sdImage;
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
          oreamnos = self.nixosConfigurations.oreamnos.config.system.build.toplevel;
          serow = self.nixosConfigurations.serow.config.system.build.toplevel;
          duisk = self.nixosConfigurations.duisk.config.system.build.toplevel;
          lighthouse = self.nixosConfigurations.lighthouse.config.system.build.toplevel;
          anoa = self.nixosConfigurations.anoa.config.system.build.toplevel;

          #inherit (self.packages.x86_64-linux) boerbok-sd-from-x86_64;
        };
        #aarch64-linux = {
        #  inherit (self.packages.aarch64-linux) rpi4-bootstrap;
        #  inherit (self.packages.aarch64-linux) rpi5-bootstrap;
        #  argali = self.nixosConfigurations.argali.config.system.build.toplevel;
        #  arkelli = self.nixosConfigurations.arkelli.config.system.build.toplevel;
        #};
        # hydra doesn't support riscv (due to GHC not available)
        #riscv64-linux = {
        #  boerbok = self.nixosConfigurations.boerbok.config.system.build.toplevel;
        #};
      };
    };
}
