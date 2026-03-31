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
        description = "Apply CAKE SQM to ${cfg.ppp}";
        after = [ pppdService ];
        bindsTo = [ pppdService ];
        partOf = [ pppdService ];
        wantedBy = [ pppdService ];

        path = with pkgs; [
          iproute2
          kmod
        ];

        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStop = pkgs.writeShellScript "cake-sqm-stop" ''
            set -euo pipefail

            tc qdisc del dev ${cfg.ppp} root 2>/dev/null || true
            tc qdisc del dev ${cfg.ppp} ingress 2>/dev/null || true
            tc qdisc del dev ${cfg.ifb} root 2>/dev/null || true
            ip link set dev ${cfg.ifb} down 2>/dev/null || true
          '';
        };

        script = ''
          set -euo pipefail

          modprobe ifb || true

          if ! ip link show dev ${cfg.ifb} >/dev/null 2>&1; then
            ip link add ${cfg.ifb} type ifb
          fi

          ip link set dev ${cfg.ifb} up

          tc qdisc del dev ${cfg.ppp} root 2>/dev/null || true
          tc qdisc del dev ${cfg.ppp} ingress 2>/dev/null || true
          tc qdisc del dev ${cfg.ifb} root 2>/dev/null || true

          tc qdisc replace dev ${cfg.ppp} root cake \
            bandwidth ${cfg.bandwidth.upload} \
            diffserv4 \
            nat \
            dual-srchost

          tc qdisc add dev ${cfg.ppp} handle ffff: ingress

          tc filter add dev ${cfg.ppp} parent ffff: protocol all matchall \
            action mirred egress redirect dev ${cfg.ifb}

          tc qdisc replace dev ${cfg.ifb} root cake \
            bandwidth ${cfg.bandwidth.download} \
            diffserv4 \
            nat \
            dual-dsthost
        '';
      };
    };
  };
}
