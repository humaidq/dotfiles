{
  config,
  pkgs,
  lib,
  ...
}:
with lib; let
  cfg = config.sifr.tailscale;
in {
  options.sifr.tailscale.enable = mkOption {
    description = "Enable tailscale configuration";
    type = types.bool;
    default = false;
  };
  options.sifr.tailscale.exitNode = mkOption {
    description = "Sets up the system as an exit node";
    type = types.bool;
    default = false;
  };

  options.sifr.tailscale.ssh = mkOption {
    description = "Enables openssh for access through tailscale only";
    type = types.bool;
    default = false;
  };

  options.sifr.tailscale.auth = mkOption {
    description = "Performs a oneshot authentication with an auth-key";
    type = types.bool;
    default = false;
  };
  options.sifr.tailscale.tsKey = mkOption {
    description = "The oneshot key";
    type = types.str;
  };

  config = mkMerge [
    (mkIf cfg.enable {
      services.tailscale.enable = true;
      networking.firewall = {
        trustedInterfaces = ["tailscale0"];
        # This allows local discovery/connection.
        allowedUDPPorts = [config.services.tailscale.port];
      };
    })
    (mkIf cfg.exitNode {
      # We need to relax some settings so that we can be an exit node.
      networking.firewall.checkReversePath = "loose";
      boot.kernel.sysctl = {
        "net.ipv4.ip_forward" = 1;
        "net.ipv6.conf.all.forwarding" = 1;
      };
    })
    (mkIf cfg.ssh {
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

      environment.systemPackages = with pkgs; [mosh];
    })
    (mkIf cfg.auth {
      # Source: https://tailscale.com/blog/nixos-minecraft/
      systemd.services.tailscale-autoconnect = {
        description = "Automatic connection to Tailscale";

        # make sure tailscale is running before trying to connect to tailscale
        after = ["network-pre.target" "tailscale.service"];
        wants = ["network-pre.target" "tailscale.service"];
        wantedBy = ["multi-user.target"];

        # set this service as a oneshot job
        serviceConfig.Type = "oneshot";

        # have the job run this shell script
        script = with pkgs; ''
          # wait for tailscaled to settle
          sleep 2

          # check if we are already authenticated to tailscale
          status="$(${tailscale}/bin/tailscale status -json | ${jq}/bin/jq -r .BackendState)"
          if [ $status = "Running" ]; then # if so, then do nothing
            exit 0
          fi

          # otherwise authenticate with tailscale
          ${tailscale}/bin/tailscale up -authkey ${cfg.tsKey}
        '';
      };
    })
  ];
}
