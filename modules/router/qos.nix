{
  config,
  lib,
  pkgs,
  utils,
  ...
}:

let
  cfg = config.sifr.router;
  pppdService = "pppd-etisalat.service";
  pppDevice = "${utils.escapeSystemdPath "/sys/subsystem/net/devices/${cfg.ppp}"}.device";
  inherit (cfg) throttle imoThrottle;
in
{
  config = lib.mkIf cfg.enable {
    systemd.services = lib.mkIf config.services.pppd.enable {
      cake-sqm = {
        description = "Apply CAKE SQM to ${cfg.ppp} (upload) and ${cfg.lan0} (download)";

        # Tied to the ppp0 *device*, not to pppd.service. A qdisc belongs to a
        # netdev, and the daily redial (pppd-uplink-redial HUPs the daemon)
        # destroys and recreates ppp0 while pppd.service itself stays running
        # the whole time. Bound to the service, this unit therefore ran exactly
        # once per boot and the upload shaper was silently gone from the first
        # 05:00 redial onwards -- observed on 2026-08-23 with six days of
        # uptime, `tc qdisc show dev ppp0` reporting a bare `noqueue` while the
        # download shaper on the LAN side (a netdev that never goes away) still
        # had its full tree. Bulk upload was unshaped for ~23 hours out of 24,
        # and the throttle and imo penalty classes went with it.
        #
        # BindsTo the device stops this unit (and so runs ExecStop) when ppp0
        # disappears; WantedBy on the same device starts it again when udev
        # brings the new one back. After= on pppd.service only orders the
        # first start at boot.
        after = [
          pppdService
          pppDevice
        ];
        bindsTo = [ pppDevice ];
        wantedBy = [ pppDevice ];

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
        # CAKE is no longer the root qdisc. It sits under an HTB tree as the
        # default class, so penalty classes can exist alongside it for the
        # addresses in custom-throttle-list.txt (marked 0x2) and
        # custom-imo-list.txt (marked 0x3) — see forward_throttle in
        # ip-blocklist.nix.
        #
        # HTB purely to get the classes — the default one is given the full link
        # rate and CAKE inside it still does all the real work, so ordinary
        # traffic behaves as it did when CAKE was root. Both penalty classes are
        # rate-limited by HTB and sit at the lowest HTB priority, so they only
        # ever get what ordinary traffic has left.
        #
        # The two penalty classes no longer work the same way. The imo class is
        # still HTB plus netem loss; the throttled class is a rate cap and
        # nothing else since 2026-08-13, because impairment turned out to help
        # the clients being shaped pick a different node — see the throttled
        # class below and sifr.router.throttle in default.nix.
        #
        # HTB does the rate in both cases rather than netem's own `rate` option,
        # which is a plain token bucket with none of HTB's borrowing behaviour.
        # Keeping rate and queue in separate qdiscs is what made it possible to
        # drop the impairment without touching the shaping number.
        script = ''
          set -euo pipefail

          shape() {
            local dev="$1" bw="$2"; shift 2

            # Torn down and rebuilt rather than `replace`d in place. The classes
            # below hang off a shaping parent (1:1) instead of off the root, and
            # tc cannot reparent an existing class: a `replace` against a tree
            # left over from the older flat layout would silently keep the old
            # parents, and the priorities would never take effect.
            tc qdisc del dev "$dev" root 2>/dev/null || true
            tc qdisc add dev "$dev" root handle 1: htb default 10

            # Shaping parent at the full link rate. Every class below is a
            # sibling under it, and that is what makes HTB's `prio` mean
            # anything: classes attached straight to the root qdisc have no
            # common ancestor to compete for, so they never contend and a
            # priority written on them would be decoration.
            tc class add dev "$dev" parent 1: classid 1:1 htb \
              rate "$bw" ceil "$bw"

            # Default class: the whole link, CAKE unchanged underneath. prio 0
            # is HTB's highest, so ordinary traffic is always dequeued ahead of
            # the two penalty classes below.
            tc class add dev "$dev" parent 1:1 classid 1:10 htb \
              rate "$bw" ceil "$bw" prio 0
            tc qdisc add dev "$dev" parent 1:10 handle 10: cake \
              bandwidth "$bw" "$@"

            # The penalty classes are prio 7, HTB's lowest. Their rates
            # deliberately overcommit the parent — 1:10 alone is already the
            # whole link — which is the mechanism, not an oversight: when the
            # link is busy the parent has no tokens to hand out, HTB serves the
            # priority bands in order, and these two get only what 1:10 leaves.
            # Their own rate caps are what bounds them when the link is idle.

            # Throttled class: a rate cap and nothing else. netem used to sit
            # here adding latency, jitter and loss; it was removed on
            # 2026-08-13 because the clients being shaped score candidate nodes
            # on RTT and loss, so impairing a node made it easy to spot and
            # discard. See the comment on sifr.router.throttle in default.nix.
            #
            # fq_codel rather than the default pfifo, and the choice matters —
            # a plain fifo here would silently reintroduce the latency this
            # change exists to remove. The default queue is txqueuelen packets
            # deep, which at ${throttle.rate} is minutes of standing buffer, and
            # bufferbloat that severe is just as visible to an RTT probe as
            # netem's delay was.
            #
            # fq_codel earns its place twice over: it holds the bulk queue near
            # `target` instead of letting it grow, and it flow-isolates, so a
            # probe or a keepalive gets its own queue and answers immediately
            # while a bulk transfer on the same node sits at the cap. That is
            # precisely the shape wanted — the node measures healthy and moves
            # no data.
            #
            # target 100ms because codel's 5ms default is meaningless below a
            # megabit: one 1500-byte packet takes ~120ms to clock out at
            # ${throttle.rate}, so a 5ms target would have codel dropping
            # constantly and hand the client back the loss signal just removed.
            tc class add dev "$dev" parent 1:1 classid 1:20 htb \
              rate ${throttle.rate} ceil ${throttle.rate} prio 7
            tc qdisc add dev "$dev" parent 1:20 handle 20: fq_codel \
              limit 100 target 100ms interval 1s noecn

            # Steer anything nftables marked into the throttled class. `protocol
            # all` so one filter covers IPv4 and IPv6 alike. The filter hangs off
            # the root qdisc, which is unchanged by the classes moving down a
            # level — flowid names the class directly.
            tc filter add dev "$dev" parent 1: protocol all prio 1 \
              handle 0x2 fw flowid 1:20

            # imo class. Rate capped and lossy at every hour of every day.
            #
            # No delay or jitter, unlike the throttled class above. Latency is
            # what makes a long-lived tunnel unusable; for imo the rate cap
            # and the loss are the whole mechanism.
            #
            # Not built at all on a host whose imoPolicy is "block": nothing
            # there ever sets mark 0x3, so the class, its netem qdisc and the
            # filter feeding it would sit empty forever.
            ${lib.optionalString (cfg.imoPolicy != "block") ''
              tc class add dev "$dev" parent 1:1 classid 1:30 htb \
                rate ${imoThrottle.rate} ceil ${imoThrottle.rate} prio 7
              tc qdisc add dev "$dev" parent 1:30 handle 30: netem \
                loss ${imoThrottle.loss} \
                limit 1000

              tc filter add dev "$dev" parent 1: protocol all prio 1 \
                handle 0x3 fw flowid 1:30
            ''}

            # Cooldown class. Everything a device in cooldown is still allowed
            # to reach — the captive-portal carve-out and the allowed ASNs —
            # marked 0x4 by the cooldown chain in cooldown.nix.
            #
            # prio 7 like the other two penalty classes, so a cooled device
            # cannot take capacity from anyone. That is nearly moot in practice:
            # the class is empty except while a cooldown is running, which is
            # minutes at a time.
            #
            # fq_codel with the same parameters as the throttled class, for the
            # first of the two reasons given there and not the second. Nothing
            # here is hiding from a client's node scoring; this is a phone whose
            # owner has been cut off. What matters is that the default pfifo at
            # ${cfg.cooldown.rate} would be tens of seconds of standing buffer,
            # so a probe or a push keepalive would queue behind whatever bulk
            # transfer the device tried first and time out — and a device that
            # concludes the network is broken is the failure this whole feature
            # exists to avoid. Flow isolation keeps the small things answering.
            ${lib.optionalString cfg.cooldown.enable ''
              tc class add dev "$dev" parent 1:1 classid 1:40 htb \
                rate ${cfg.cooldown.rate} ceil ${cfg.cooldown.rate} prio 7
              tc qdisc add dev "$dev" parent 1:40 handle 40: fq_codel \
                limit 100 target 100ms interval 1s noecn

              tc filter add dev "$dev" parent 1: protocol all prio 1 \
                handle 0x4 fw flowid 1:40
            ''}
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

      # The imo loss value is fixed now, so cake-sqm writes the final number
      # when it builds the class and nothing has to correct it afterwards.
      # What varies by day is whether the estate is shaped or dropped at all,
      # and that is set membership rather than a tc parameter — see
      # imo-policy.service in ip-blocklist.nix.
    };
  };
}
