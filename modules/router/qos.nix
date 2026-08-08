{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.sifr.router;
  pppdService = "pppd-etisalat.service";
  inherit (cfg) throttle imoThrottle;
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
        #
        # CAKE is no longer the root qdisc. It sits under an HTB root as the
        # default class, so a second class can exist alongside it for the
        # addresses in custom-throttle-list.txt, which nftables marks 0x2 (see
        # forward_throttle in ip-blocklist.nix).
        #
        # HTB purely to get two classes — the default one is given the full link
        # rate and CAKE inside it still does all the real work, so ordinary
        # traffic behaves as it did when CAKE was root. The throttled class is
        # rate-limited by HTB and then made unpleasant by netem.
        #
        # netem does the impairment rather than the rate: its own `rate` option
        # is a plain token bucket with none of HTB's borrowing behaviour, and
        # keeping the two concerns in separate qdiscs means the shaping number
        # and the misery numbers can be tuned independently.
        script = ''
          set -euo pipefail

          shape() {
            local dev="$1" bw="$2"; shift 2

            tc qdisc replace dev "$dev" root handle 1: htb default 10

            # Default class: the whole link, CAKE unchanged underneath.
            tc class replace dev "$dev" parent 1: classid 1:10 htb \
              rate "$bw" ceil "$bw"
            tc qdisc replace dev "$dev" parent 1:10 handle 10: cake \
              bandwidth "$bw" "$@"

            # Throttled class. `limit 1000` bounds netem's own queue: at
            # ${throttle.rate} a deep queue would add minutes of delay on top of
            # the intended latency and the tunnel would stall outright rather
            # than merely crawl, which is more detectable than what we want.
            tc class replace dev "$dev" parent 1: classid 1:20 htb \
              rate ${throttle.rate} ceil ${throttle.rate}
            tc qdisc replace dev "$dev" parent 1:20 handle 20: netem \
              delay ${throttle.delay} ${throttle.jitter} distribution normal \
              loss ${throttle.loss} \
              limit 1000

            # Steer anything nftables marked into the throttled class. `protocol
            # all` so one filter covers IPv4 and IPv6 alike.
            tc filter replace dev "$dev" parent 1: protocol all prio 1 \
              handle 0x2 fw flowid 1:20

            # imo class. Rate capped at every hour; only the loss varies, and
            # the value written here is just a starting point —
            # imo-throttle-schedule.service corrects it for the current time
            # of day as soon as this unit finishes, and every half hour after.
            #
            # No delay or jitter, unlike the throttled class above. Latency is
            # what makes a long-lived tunnel unusable; for imo the rate cap
            # and the loss are the whole mechanism.
            tc class replace dev "$dev" parent 1: classid 1:30 htb \
              rate ${imoThrottle.rate} ceil ${imoThrottle.rate}
            tc qdisc replace dev "$dev" parent 1:30 handle 30: netem \
              loss ${imoThrottle.baseLoss} \
              limit 1000

            tc filter replace dev "$dev" parent 1: protocol all prio 1 \
              handle 0x3 fw flowid 1:30
          }

          # Upload: egress of the PPP uplink. "nat" recovers the real LAN source
          # behind the masquerade so dual-srchost fairness is per-LAN-host.
          shape ${cfg.ppp} ${cfg.bandwidth.upload} diffserv4 nat dual-srchost

          # Download: egress towards the LAN. At this point reverse-NAT has
          # already restored the real LAN destination, so "nat" is unnecessary;
          # dual-dsthost gives per-LAN-host fairness on inbound traffic.
          shape ${cfg.lan0} ${cfg.bandwidth.download} diffserv4 dual-dsthost
        '';
      };
    };
  };
}
