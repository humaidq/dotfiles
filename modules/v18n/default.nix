{
  config,
  pkgs,
  home-manager,
  unstable,
  lib,
  vars,
  ...
}:
with lib; let
  cfg = config.sifr.v18n;
in {
  options.sifr.v18n.docker.enable = mkOption {
    description = "Enable docker";
    type = types.bool;
    default = false;
  };
  options.sifr.v18n.emulation.enable = mkOption {
    description = "Enable QEMU emulation of other systems";
    type = types.bool;
    default = false;
  };
  options.sifr.v18n.emulation.systems = mkOption {
    description = "List of systems to emulate with binfmt";
    type = types.listOf types.str;
    default = [];
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
