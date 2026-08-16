{
  config,
  pkgs,
  lib,
  vars,
  ...
}:
let
  cfg = config.sifr.v12n;
  inherit (lib)
    mkOption
    types
    mkMerge
    mkIf
    mkEnableOption
    ;
in
{
  options.sifr.v12n = {
    docker.enable = mkEnableOption "docker";
    emulation.enable = mkEnableOption "QEMU emulation of other systems";
    emulation.systems = mkOption {
      description = "List of systems to emulate with binfmt";
      type = types.listOf types.str;
      default = [ ];
    };
  };
  config = mkMerge [
    (mkIf cfg.docker.enable {
      users.users.${vars.user}.extraGroups = [ "docker" ];
      virtualisation.docker.enable = true;
      # A default rather than a plain set: a module that ships an appliance
      # image which only runs under podman (see home-server/unifi.nix) has to
      # be able to claim the backend without disabling docker for the user.
      virtualisation.oci-containers.backend = lib.mkDefault "docker";
    })
    (mkIf cfg.emulation.enable {
      environment.systemPackages = with pkgs; [
        qemu_kvm
        qemu_full
        OVMF
        edk2
        (pkgs.writeShellScriptBin "qemu-system-x86_64-uefi" ''
          qemu-system-x86_64 \
            -bios ${pkgs.OVMF.fd}/FV/OVMF.fd \
            "$@"
        '')
        # guestfish files out of qcow2
        libguestfs
      ];
    })
    (mkIf (cfg.emulation.systems != [ ]) { boot.binfmt.emulatedSystems = cfg.emulation.systems; })
  ];
}
