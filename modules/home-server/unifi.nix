# UniFi OS Server: the controller for the wireless access points on the LAN.
#
# Ubiquiti ship this as a self-extracting binary blob rather than a package, so
# there is no NixOS service for it. rcambrj/unifi-os-server unpacks the OCI
# image out of that installer and runs it under podman with a handful of
# systemd drop-ins to make the appliance's init happy inside a container. That
# is the whole reason this is a container and not a normal service.
{
  config,
  lib,
  inputs,
  ...
}:

let
  cfg = config.sifr.home-server;
  ucfg = cfg.unifi;
in
{
  imports = [ inputs.unifi-os-server.nixosModules.unifi-os-server ];

  options.sifr.home-server.unifi = {
    enable = lib.mkEnableOption "UniFi OS Server for the access points on the LAN";

    informAddress = lib.mkOption {
      type = lib.types.str;
      description = ''
        Address the access points are told to report to, as
        `http://<address>:8080/inform`. This has to be the LAN address of this
        host on the same network as the APs — the mesh address does not work,
        since an adopted AP only ever speaks to the address baked into its
        inform URL and it has no route into the mesh.
      '';
      example = "10.20.0.250";
    };

    uiPort = lib.mkOption {
      type = lib.types.port;
      default = 11443;
      description = ''
        Host port for the UniFi OS Server web UI. The container serves HTTPS
        here with its own self-signed certificate; nginx fronts it at
        unifi.alq.ae.
      '';
    };

    controllerPort = lib.mkOption {
      type = lib.types.port;
      default = 8444;
      description = ''
        Host port for the legacy Network controller's HTTPS interface, which
        the container serves on 8443. Remapped because step-ca already holds
        8443 on this host and every certificate here is issued through it, so
        the CA is the one that keeps the port. Nothing an access point does
        goes through here — adoption is the inform port — so only direct
        browser access to the legacy interface is affected.
      '';
    };
  };

  config = lib.mkIf (cfg.enable && ucfg.enable) {
    # The appliance image assumes podman (the drop-ins mount into its systemd),
    # while sifr.v12n.docker points oci-containers at docker for interactive
    # use. Nothing else in this configuration declares an oci-container, so
    # claiming the backend here costs nothing; docker itself stays enabled.
    virtualisation.podman.enable = true;
    virtualisation.oci-containers.backend = "podman";

    services.unifi-os-server = {
      enable = true;
      uosSystemIP = ucfg.informAddress;
      ports.ui = ucfg.uiPort;
      ports.controllerHttps = ucfg.controllerPort;

      # Inform, controller HTTPS, speed test, captive portal, STUN and
      # discovery all have to reach the APs directly on the LAN.
      openFirewallServicePorts = true;
      # The UI as well, so the controller is usable from the LAN when nginx or
      # ACME is unhappy — which is exactly when you want to reach it.
      openFirewallUiPort = true;
    };

    # The state directory is an impermanence bind mount, and the subdirectories
    # inside it come from tmpfiles. On the deploy that first introduces the
    # mount those two race: tmpfiles creates the subdirectories, the mount then
    # lands on top and hides them, and the container's own preStart fails on a
    # path that no longer exists. Waiting for the mount and re-running tmpfiles
    # underneath it costs nothing on every later start, when both are already
    # in place.
    systemd.services.podman-unifi-os-server = {
      unitConfig.RequiresMountsFor = config.services.unifi-os-server.stateDir;
      preStart = lib.mkBefore ''
        ${config.systemd.package}/bin/systemd-tmpfiles --create \
          --prefix=${config.services.unifi-os-server.stateDir}
      '';
    };
  };
}
