{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.sifr.router;

  # Shared with the o11y client module, which points node_exporter's textfile
  # collector at the same path. Kept as a plain string in both places rather
  # than an option: the two modules are only ever deployed together as part of
  # this flake, and an option would imply a flexibility that nothing uses.
  textfileDir = "/var/lib/prometheus-node-exporter-text-files";

  # Reads tc and nft, writes a Prometheus textfile. Python rather than the
  # shell used elsewhere in this module tree because all three inputs are JSON
  # documents that need reshaping rather than line-oriented output that needs
  # filtering — the jq incantation for the tin array alone would be longer than
  # this whole script and considerably harder to correct later.
  qosTextfile = pkgs.writers.writePython3Bin "qos-textfile" { flakeIgnore = [ "E501" ]; } ''
    """Collect QoS statistics into a Prometheus textfile.

    Five sources, one file:
      * CAKE per-tin stats, which is where prioritisation is actually visible
      * the HTB penalty classes that the throttle and imo lists steer into
      * the nftables rule counters from qos-mark and forward_throttle, which
        show classification firing
      * the size of the throttle and imo sets, which is how a runtime
        `tempthrottle add` becomes visible at all
      * the per-address drop counters of the ad-hoc `tempblock` table
    """

    import json
    import os
    import subprocess
    import sys
    import tempfile

    DEVICES = [${
      lib.concatMapStringsSep ", " (d: ''"${d}"'') [
        cfg.ppp
        cfg.lan0
      ]
    }]
    OUT = "${textfileDir}/qos.prom"

    # CAKE reports tins in display order, which for diffserv4 is Bulk, Best
    # Effort, Video, Voice. That ordering is positional and carries no label in
    # the JSON, so this mapping is only correct while shape() in qos.nix passes
    # diffserv4. threshold_rate is exported alongside precisely so a wrong
    # mapping is detectable rather than silent: the ratios are 1/16, 1/1, 1/2
    # and 1/4 of the shaped rate respectively, so a tin labelled "voice" whose
    # threshold is not a quarter of the link means this list is stale.
    DIFFSERV4_TINS = ["bulk", "besteffort", "video", "voice"]

    # The classids that shape() builds. 1:1 is the shaping parent rather than a
    # traffic class and is deliberately absent — its counters are the sum of
    # the three below and would double every total on the dashboard.
    CLASSES = {"1:10": "normal", "1:20": "throttle", "1:30": "imo"}

    # (table, chain) pairs whose per-rule counters are exported, distinguished
    # by a `chain` label. qos-mark shows prioritisation firing; forward_throttle
    # shows the throttle and imo sets matching, split by direction and address
    # family — a breakdown the HTB class counters cannot give, since both
    # families and both directions land in the same class.
    RULE_CHAINS = [
        ("router-filter", "qos-mark"),
        ("router-blocklists", "forward_throttle"),
    ]

    # The sets forward_throttle matches on. Their rule counters say how much
    # traffic is being marked but nothing about how many addresses are in
    # scope, and these sets have two writers: nft-blocklists-local repopulates
    # them from custom-throttle-list.txt on a rebuild, and `tempthrottle`
    # adds and deletes elements live. Exporting the cardinality is what makes
    # the second writer visible — otherwise a temporary throttle is
    # indistinguishable from the listed ones, and its removal invisible.
    THROTTLE_SETS = ["throttle4", "throttle6", "imo4", "imo6"]

    # The table `tempblock` creates on first use (see tempblock.bash). It is
    # not part of networking.nftables.tables, so nothing else here knows about
    # it, and it is absent whenever no temporary block is in force.
    TEMPBLOCK_TABLE = "router_tempblock"
    TEMPBLOCK_CHAIN = "block"
    TEMPBLOCK_PREFIX = "tempblock:"

    # Which way the rule with this match field points, in the vocabulary
    # `tempblock list` already uses for the same two counters.
    TEMPBLOCK_DIRECTIONS = {"daddr": "to-peer", "saddr": "from-peer"}


    def run_json(*argv):
        """Return parsed JSON from argv, or None if the command failed.

        Failures are expected rather than exceptional: the timer fires
        regardless of whether pppd has brought ppp0 up or cake-sqm has built
        the qdisc tree, and a device that does not exist yet is not an error
        worth failing the unit over. Anything unparseable is treated the same
        way; the collector_success metric at the end is what surfaces a
        genuinely broken collection.
        """
        try:
            out = subprocess.run(
                argv, capture_output=True, timeout=10, check=True
            ).stdout
        except (subprocess.CalledProcessError, subprocess.TimeoutExpired, OSError):
            return None
        try:
            return json.loads(out)
        except json.JSONDecodeError:
            return None


    def escape(value):
        """Escape a Prometheus label value (backslash, quote, newline)."""
        return (
            str(value)
            .replace("\\", "\\\\")
            .replace('"', '\\"')
            .replace("\n", "\\n")
        )


    class Metrics:
        """Accumulates samples and emits them grouped under one HELP/TYPE."""

        def __init__(self):
            self.meta = {}
            self.samples = {}

        def add(self, name, help_text, kind, labels, value):
            if name not in self.meta:
                self.meta[name] = (help_text, kind)
                self.samples[name] = []
            rendered = ",".join(
                f'{k}="{escape(v)}"' for k, v in sorted(labels.items())
            )
            # An empty label set is written bare rather than as an empty pair
            # of braces. Prometheus accepts both, but the bare form is what
            # every other exporter emits and what anyone grepping this file
            # will expect to find.
            suffix = f"{{{rendered}}}" if rendered else ""
            self.samples[name].append(f"{name}{suffix} {value}")

        def render(self):
            lines = []
            for name in sorted(self.meta):
                help_text, kind = self.meta[name]
                lines.append(f"# HELP {name} {help_text}")
                lines.append(f"# TYPE {name} {kind}")
                lines.extend(sorted(self.samples[name]))
            return "\n".join(lines) + "\n"


    # (json key, metric suffix, help, type, scale)
    TIN_FIELDS = [
        ("sent_bytes", "sent_bytes_total", "Bytes sent by this CAKE tin", "counter", 1),
        ("sent_packets", "sent_packets_total", "Packets sent by this CAKE tin", "counter", 1),
        ("drops", "drops_total", "Packets dropped by this CAKE tin", "counter", 1),
        ("ecn_mark", "ecn_marks_total", "Packets ECN-marked by this CAKE tin", "counter", 1),
        ("ack_drops", "ack_drops_total", "Redundant ACKs dropped by this CAKE tin", "counter", 1),
        ("backlog_bytes", "backlog_bytes", "Bytes currently queued in this CAKE tin", "gauge", 1),
        ("sparse_flows", "sparse_flows", "Flows in this tin below their fair share", "gauge", 1),
        ("bulk_flows", "bulk_flows", "Flows in this tin at or above their fair share", "gauge", 1),
        ("unresponsive_flows", "unresponsive_flows", "Flows in this tin ignoring congestion signals", "gauge", 1),
        ("threshold_rate", "threshold_bytes_per_second", "Rate above which this tin loses its priority boost", "gauge", 1),
        # Delays are microseconds in tc's JSON; Prometheus convention is base units.
        ("avg_delay_us", "avg_delay_seconds", "Average sojourn time in this CAKE tin", "gauge", 1e-6),
        ("peak_delay_us", "peak_delay_seconds", "Peak sojourn time in this CAKE tin", "gauge", 1e-6),
        ("base_delay_us", "base_delay_seconds", "Minimum sojourn time in this CAKE tin", "gauge", 1e-6),
    ]

    CLASS_FIELDS = [
        ("bytes", "sent_bytes_total", "Bytes sent by this HTB class", "counter"),
        ("packets", "sent_packets_total", "Packets sent by this HTB class", "counter"),
        ("drops", "drops_total", "Packets dropped by this HTB class", "counter"),
        ("overlimits", "overlimits_total", "Times this HTB class exceeded its rate", "counter"),
        ("backlog", "backlog_bytes", "Bytes currently queued in this HTB class", "gauge"),
    ]


    def collect_tins(metrics, device):
        qdiscs = run_json("tc", "-s", "-j", "qdisc", "show", "dev", device)
        if not qdiscs:
            return False
        found = False
        for qdisc in qdiscs:
            if qdisc.get("kind") != "cake":
                continue
            tins = qdisc.get("tins") or []
            # Fall back to positional labels rather than guessing when the tin
            # count is not diffserv4's four. Mislabelling "video" onto a
            # besteffort-mode tin would be worse than an unfriendly name.
            names = DIFFSERV4_TINS if len(tins) == len(DIFFSERV4_TINS) else [
                str(i) for i in range(len(tins))
            ]
            for name, tin in zip(names, tins):
                labels = {"device": device, "tin": name}
                for key, suffix, help_text, kind, scale in TIN_FIELDS:
                    if key not in tin:
                        continue
                    value = tin[key] * scale
                    metrics.add(
                        f"router_qos_tin_{suffix}", help_text, kind, labels, value
                    )
                found = True
        return found


    def collect_classes(metrics, device):
        classes = run_json("tc", "-s", "-j", "class", "show", "dev", device)
        if not classes:
            return False
        found = False
        for entry in classes:
            name = CLASSES.get(entry.get("handle"))
            if name is None:
                continue
            stats = entry.get("stats") or {}
            labels = {"device": device, "class": name}
            for key, suffix, help_text, kind in CLASS_FIELDS:
                if key not in stats:
                    continue
                metrics.add(
                    f"router_qos_class_{suffix}", help_text, kind, labels, stats[key]
                )
            if "rate" in entry:
                metrics.add(
                    "router_qos_class_rate_bytes_per_second",
                    "Configured HTB rate for this class",
                    "gauge",
                    labels,
                    entry["rate"],
                )
            found = True
        return found


    def collect_rules(metrics, table, chain):
        doc = run_json("nft", "-j", "list", "chain", "inet", table, chain)
        if not doc:
            return False
        found = False
        for item in doc.get("nftables", []):
            rule = item.get("rule")
            if not rule:
                continue
            # The comment is the only stable identifier a rule has. Handles are
            # assigned at load time and shift whenever a rule is added above,
            # so labelling by handle would rewrite every series on each change.
            comment = rule.get("comment")
            if not comment:
                continue
            for expr in rule.get("expr", []):
                counter = expr.get("counter")
                if not isinstance(counter, dict):
                    continue
                labels = {"rule": comment, "chain": chain}
                metrics.add(
                    "router_qos_rule_packets_total",
                    "Packets matched by this classification rule",
                    "counter",
                    labels,
                    counter.get("packets", 0),
                )
                metrics.add(
                    "router_qos_rule_bytes_total",
                    "Bytes matched by this classification rule",
                    "counter",
                    labels,
                    counter.get("bytes", 0),
                )
                found = True
        return found


    def collect_sets(metrics):
        found = False
        for name in THROTTLE_SETS:
            doc = run_json(
                "nft", "-j", "list", "set", "inet", "router-blocklists", name
            )
            if not doc:
                continue
            for item in doc.get("nftables", []):
                entry = item.get("set")
                if not entry:
                    continue
                # `elem` is absent rather than empty for a set with nothing in
                # it, which is exactly the state a `tempthrottle del` of the
                # last address leaves behind — it has to read as 0, not as a
                # missing sample.
                metrics.add(
                    "router_qos_set_elements",
                    "Addresses currently in this nftables set",
                    "gauge",
                    {"set": name},
                    len(entry.get("elem") or []),
                )
                found = True
        return found


    def tempblock_totals(doc):
        """Sum the tempblock chain's counters per (address, direction).

        Accumulated rather than returned per rule. Each address normally has
        one rule per direction, but tempblock repairs one-sided leftovers
        instead of rewriting them and nothing stops two rules for the same
        address and direction existing. Two samples with identical labels is
        not a duplicated line but a parse error that makes node_exporter
        discard every metric in the textfile directory, so the sum is taken
        here where a collision is harmless.
        """
        totals = {}
        for item in doc.get("nftables", []):
            rule = item.get("rule") or {}
            comment = rule.get("comment") or ""
            if not comment.startswith(TEMPBLOCK_PREFIX):
                continue
            # The comment, not the match expression: nft normalises what it
            # prints for a CIDR (host bits masked) and for IPv6, so the match
            # is not necessarily the text the operator typed — and the comment
            # is what `tempblock del` takes back. See cmd_list in tempblock.bash.
            address = comment[len(TEMPBLOCK_PREFIX):]
            direction = "unknown"
            counter = None
            for expr in rule.get("expr", []):
                payload = expr.get("match", {}).get("left", {}).get("payload", {})
                direction = TEMPBLOCK_DIRECTIONS.get(payload.get("field"), direction)
                if isinstance(expr.get("counter"), dict):
                    counter = expr["counter"]
            if counter is None:
                continue
            key = (address, direction)
            running = totals.get(key, (0, 0))
            totals[key] = (
                running[0] + counter.get("packets", 0),
                running[1] + counter.get("bytes", 0),
            )
        return totals


    def collect_tempblock(metrics):
        # Absent table and broken nft are different answers and only one of
        # them is "nothing is blocked", so the table list is consulted first.
        # Reporting 0 because nft could not be run would say the blocks had
        # been lifted, which is the one wrong answer that matters here.
        tables = run_json("nft", "-j", "list", "tables")
        if not tables:
            return False
        present = False
        for item in tables.get("nftables", []):
            entry = item.get("table") or {}
            if entry.get("name") == TEMPBLOCK_TABLE and entry.get("family") == "inet":
                present = True
        totals = {}
        if present:
            doc = run_json(
                "nft", "-j", "list", "chain", "inet", TEMPBLOCK_TABLE, TEMPBLOCK_CHAIN
            )
            if not doc:
                return False
            totals = tempblock_totals(doc)

        for (address, direction), (packets, bytes_) in totals.items():
            labels = {"ip": address, "direction": direction}
            metrics.add(
                "router_tempblock_packets_total",
                "Packets dropped by this temporary block",
                "counter",
                labels,
                packets,
            )
            metrics.add(
                "router_tempblock_bytes_total",
                "Bytes dropped by this temporary block",
                "counter",
                labels,
                bytes_,
            )
        metrics.add(
            "router_tempblock_addresses",
            "Addresses currently blocked by tempblock",
            "gauge",
            {},
            len({address for address, _ in totals}),
        )
        return True


    def main():
        metrics = Metrics()
        ok = False
        for device in DEVICES:
            ok |= collect_tins(metrics, device)
            ok |= collect_classes(metrics, device)
        for table, chain in RULE_CHAINS:
            ok |= collect_rules(metrics, table, chain)
        ok |= collect_sets(metrics)
        ok |= collect_tempblock(metrics)

        metrics.add(
            "router_qos_collector_success",
            "Whether the QoS collector produced any samples on this run",
            "gauge",
            {},
            1 if ok else 0,
        )

        # Written through a temporary file in the same directory and renamed.
        # node_exporter's textfile collector reads on its own schedule, and a
        # partially written file is not merely stale but a parse error that
        # discards every metric in the directory, not just this one.
        directory = os.path.dirname(OUT)
        try:
            handle, tmp = tempfile.mkstemp(dir=directory, suffix=".tmp")
            with os.fdopen(handle, "w") as fh:
                fh.write(metrics.render())
            os.chmod(tmp, 0o644)
            os.replace(tmp, OUT)
        except OSError as err:
            print(f"qos-textfile: cannot write {OUT}: {err}", file=sys.stderr)
            return 1
        return 0


    sys.exit(main())
  '';
in
{
  config = lib.mkIf (cfg.enable && config.sifr.personal.o11y.client.enable) {
    # The directory itself is created by the o11y client module, which is also
    # what configures the collector that reads it — see the gate on this
    # module's config block.

    systemd.services.qos-textfile = {
      description = "Collect QoS statistics into a Prometheus textfile";

      path = with pkgs; [
        iproute2
        nftables
      ];

      serviceConfig = {
        Type = "oneshot";
        ExecStart = lib.getExe qosTextfile;

        # Reads the qdisc tree and the nft ruleset, writes one file. It needs
        # CAP_NET_ADMIN for the nft listing and nothing else, so everything
        # else is taken away.
        CapabilityBoundingSet = [ "CAP_NET_ADMIN" ];
        AmbientCapabilities = [ "CAP_NET_ADMIN" ];
        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        PrivateDevices = true;
        ReadWritePaths = [ textfileDir ];
        RestrictAddressFamilies = [
          "AF_UNIX"
          "AF_NETLINK"
        ];
      };
    };

    systemd.timers.qos-textfile = {
      description = "Sample QoS statistics regularly";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        # Faster than the scrape interval on purpose: Prometheus rate() over a
        # textfile is only as good as the freshest sample, and a 15s write
        # against a 60s scrape means the counters are never more than a
        # quarter-interval stale.
        OnBootSec = "30s";
        OnUnitActiveSec = "15s";
        AccuracySec = "1s";
      };
    };
  };
}
