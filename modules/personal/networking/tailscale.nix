{
  config,
  pkgs,
  lib,
  ...
}:
let
  cfg = config.sifr.personal.tailscale;
  inherit (lib)
    mkOption
    types
    mkMerge
    mkIf
    mkEnableOption
    ;
in
{
  options.sifr.personal.tailscale = {
    enable = mkEnableOption "Tailscale configuration";
    exitNode = mkEnableOption "exit node configuration";
    ssh = mkOption {
      description = "Enables openssh for access through tailscale only";
      type = types.bool;
      default = true;
    };
    auth = mkOption {
      description = "Performs a oneshot authentication with an auth-key";
      type = types.bool;
      default = config.sifr.hasGadgetSecrets;
    };
    authKeyPath = mkOption {
      description = "Path to the Tailscale auth key file";
      type = types.nullOr types.str;
      default = null;
    };
  };

  config = mkMerge [
    (mkIf cfg.enable {
      services.tailscale.enable = true;
      networking.firewall = {
        trustedInterfaces = [ "tailscale0" ];
        # This allows local discovery/connection.
        allowedUDPPorts = [ config.services.tailscale.port ];
      };
    })
    (mkIf (cfg.enable && cfg.exitNode) {
      # We need to relax some settings so that we can be an exit node.
      networking.firewall.checkReversePath = "loose";
      boot.kernel.sysctl = {
        "net.ipv4.ip_forward" = 1;
        "net.ipv6.conf.all.forwarding" = 1;
      };
    })
    (mkIf (cfg.enable && cfg.ssh) {
      services.openssh = {
        enable = true;

        # Security: do not allow password auth or root login.
        settings = {
          PasswordAuthentication = false;
          PermitRootLogin = "no";
        };

        # Do not open firewall rules, tailscale can access only.
        openFirewall = false;
      };

      environment.systemPackages = with pkgs; [ mosh ];
    })
    (mkIf (cfg.enable && cfg.auth) {
      assertions = [
        {
          assertion = cfg.authKeyPath != null;
          message = "sifr.personal.tailscale.authKeyPath must be set when Tailscale auth is enabled";
        }
      ];

      warnings =
        if (cfg.enable && cfg.auth && !config.sifr.hasGadgetSecrets) then
          [
            "You have enabled tailscale authentication without enabling gadget secrets (${config.networking.hostName})"
          ]
        else
          [ ];

      # Source: https://tailscale.com/blog/nixos-minecraft/
      systemd.services.tailscale-autoconnect = {
        description = "Automatic connection to Tailscale";

        # make sure tailscale is running before trying to connect to tailscale
        after = [
          "network-pre.target"
          "tailscale.service"
        ];
        wants = [
          "network-pre.target"
          "tailscale.service"
        ];
        wantedBy = [ "multi-user.target" ];

        # set this service as a oneshot job
        serviceConfig.Type = "oneshot";

        # have the job run this shell script
        script = ''
          # wait for tailscaled to settle
          sleep 2

          # check if we are already authenticated to tailscale
          status="$(${pkgs.tailscale}/bin/tailscale status -json | ${pkgs.jq}/bin/jq -r .BackendState)"
          if [ $status = "Running" ]; then # if so, then do nothing
            exit 0
          fi

          # get tailscale secret key
          tskey=$(cat ${cfg.authKeyPath})
          if [ -z $tskey ]; then
            echo "Empty auth key!"
            exit 1
          fi

          # otherwise authenticate with tailscale
          ${pkgs.tailscale}/bin/tailscale up -authkey $tskey
        '';
      };
    })
  ];
}
