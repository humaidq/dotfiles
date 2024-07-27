{
  config,
  pkgs,
  lib,
  vars,
  ...
}: let
  cfg = config.sifr.v12n;
  inherit (lib) mkOption types mkMerge mkIf mkEnableOption;
in {
  options.sifr.v12n = {
    docker.enable = mkEnableOption "docker";
    emulation.enable = mkEnableOption "QEMU emulation of other systems";
    emulation.systems = mkOption {
      description = "List of systems to emulate with binfmt";
      type = types.listOf types.str;
      default = [];
    };
  };
  config = mkMerge [
    (mkIf cfg.docker.enable {
      users.users.${vars.user}.extraGroups = ["docker"];
      virtualisation.docker.enable = true;
      virtualisation.oci-containers.backend = "docker";
    })
    (mkIf cfg.emulation.enable {
      environment.systemPackages = with pkgs; [
        qemu_kvm
        OVMF
      ];
    })
    (mkIf (cfg.emulation.systems != []) {
      boot.binfmt.emulatedSystems = cfg.emulation.systems;
    })
  ];
}
