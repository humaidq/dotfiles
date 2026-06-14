{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.sifr.router;
  pppdService = "pppd-etisalat.service";
in
{
  config = lib.mkIf cfg.enable {
    systemd.services = lib.mkIf config.services.pppd.enable {
      cake-sqm = {
        description = "Apply CAKE SQM to ${cfg.ppp} (upload) and ${cfg.lan0} (download)";
        after = [ pppdService ];
        bindsTo = [ pppdService ];
        partOf = [ pppdService ];
        wantedBy = [ pppdService ];

        path = with pkgs; [
          iproute2
        ];

        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStop = pkgs.writeShellScript "cake-sqm-stop" ''
            set -euo pipefail

            tc qdisc del dev ${cfg.ppp} root 2>/dev/null || true
            tc qdisc del dev ${cfg.lan0} root 2>/dev/null || true
          '';
        };

        # The download shaper deliberately lives on the LAN interface egress
        # rather than on a WAN-ingress -> ifb redirect. A WAN ingress qdisc runs
        # before netfilter's forward hook, so the DSCP marks applied by the
        # nftables qos-mark chain would never be visible to a download shaper
        # fed from there. Shaping LAN egress runs after the forward hook, so
        # CAKE's diffserv4 classifier sees the marks and prioritisation works in
        # both directions.
        script = ''
          set -euo pipefail

          # Upload: egress of the PPP uplink. "nat" recovers the real LAN source
          # behind the masquerade so dual-srchost fairness is per-LAN-host.
          tc qdisc replace dev ${cfg.ppp} root cake \
            bandwidth ${cfg.bandwidth.upload} \
            diffserv4 \
            nat \
            dual-srchost

          # Download: egress towards the LAN. At this point reverse-NAT has
          # already restored the real LAN destination, so "nat" is unnecessary;
          # dual-dsthost gives per-LAN-host fairness on inbound traffic.
          tc qdisc replace dev ${cfg.lan0} root cake \
            bandwidth ${cfg.bandwidth.download} \
            diffserv4 \
            dual-dsthost
        '';
      };
    };
  };
}
