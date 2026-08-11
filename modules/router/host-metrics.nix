{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.sifr.router;

  # Same path and the same reasoning as qos-metrics.nix: the o11y client module
  # creates the directory and points node_exporter's textfile collector at it,
  # and this module is only ever deployed alongside it.
  textfileDir = "/var/lib/prometheus-node-exporter-text-files";

  # Reads two sources and writes one file:
  #
  #   * the nftables sets below, which carry a monotonic byte and packet
  #     counter per LAN address, split by direction;
  #   * conntrack, which is the only place the *peer* of a flow is visible, and
  #     therefore the only way to compute what share of a device's traffic one
  #     peer holds.
  #
  # The share is the number that matters. Every tunnel found on these networks
  # has been found by the same observation: a tunnel peer holds 70-100% of one
  # device's bytes, where the same device browsing normally sits at 20-35%.
  hostTextfile = pkgs.writers.writePython3Bin "host-flow-textfile" { flakeIgnore = [ "E501" ]; } ''
    """Collect per-host traffic statistics into a Prometheus textfile.

    Totals come from nftables set element counters, which are monotonic and
    survive the flows that produced them. Share comes from conntrack, which
    knows the peer but forgets it the moment the flow closes.
    """

    import json
    import os
    import subprocess
    import sys
    import tempfile

    OUT = "${textfileDir}/hostflow.prom"
    TABLE = "inet router-hostacct"

    # (set name, direction label, address family)
    SETS = [
        ("hosts_up4", "upload", 4),
        ("hosts_down4", "download", 4),
        ("hosts_up6", "upload", 6),
        ("hosts_down6", "download", 6),
    ]


    def run(*argv):
        """Run a command, returning stdout or None. Never raises."""
        try:
            done = subprocess.run(argv, capture_output=True, text=True, timeout=30, check=False)
        except (OSError, subprocess.SubprocessError) as err:
            print(f"host-flow-textfile: {argv[0]}: {err}", file=sys.stderr)
            return None
        if done.returncode != 0:
            return None
        return done.stdout


    class Metrics:
        def __init__(self):
            self.lines = []
            self.seen = set()

        @staticmethod
        def escape(value):
            return str(value).replace("\\", "\\\\").replace('"', '\\"').replace("\n", " ")

        def add(self, name, help_text, kind, labels, value):
            if name not in self.seen:
                self.lines.append(f"# HELP {name} {help_text}")
                self.lines.append(f"# TYPE {name} {kind}")
                self.seen.add(name)
            rendered = ",".join(f'{k}="{self.escape(v)}"' for k, v in sorted(labels.items()))
            suffix = f"{{{rendered}}}" if rendered else ""
            self.lines.append(f"{name}{suffix} {value}")

        def render(self):
            return "\n".join(self.lines) + "\n"


    def read_set(name):
        """Return {address: (bytes, packets)} for one nftables set."""
        raw = run("nft", "-j", "list", "set", *TABLE.split(), name)
        if raw is None:
            return {}
        try:
            doc = json.loads(raw)
        except json.JSONDecodeError:
            return {}
        out = {}
        for obj in doc.get("nftables", []):
            block = obj.get("set")
            if not block:
                continue
            for entry in block.get("elem", []):
                elem = entry.get("elem", entry)
                if not isinstance(elem, dict):
                    continue
                addr = elem.get("val")
                counter = elem.get("counter") or {}
                if isinstance(addr, (str, int)):
                    out[str(addr)] = (counter.get("bytes", 0), counter.get("packets", 0))
        return out


    def parse_conntrack(hosts):
        """Aggregate live flows into {host: {peer: bytes}}.

        `hosts` is the set of addresses nftables has seen on the LAN side, and
        is what decides which end of a tuple is the device. Deriving it from
        the sets rather than from a configured subnet means this needs no
        knowledge of the addressing and stays correct if it changes.
        """
        raw = run("conntrack", "-L", "-o", "extended")
        if raw is None:
            return {}
        flows = {}
        for line in raw.splitlines():
            fields = {}
            # Each direction repeats src/dst/bytes, so keep both occurrences.
            src, dst, total = [], [], 0
            for token in line.split():
                key, _, value = token.partition("=")
                if not value:
                    continue
                if key == "src":
                    src.append(value)
                elif key == "dst":
                    dst.append(value)
                elif key == "bytes":
                    try:
                        total += int(value)
                    except ValueError:
                        pass
            fields["src"], fields["dst"] = src, dst
            if not src or not dst or total == 0:
                continue
            # The original tuple is src[0] -> dst[0]. Whichever of the two is a
            # known LAN address is the device; the other is the peer. A flow
            # between two LAN addresses is local traffic and is skipped, since
            # a peer share against the router or another device says nothing
            # about tunnelling.
            host = peer = None
            if src[0] in hosts and dst[0] not in hosts:
                host, peer = src[0], dst[0]
            elif dst[0] in hosts and src[0] not in hosts:
                host, peer = dst[0], src[0]
            if host is None:
                continue
            flows.setdefault(host, {})
            flows[host][peer] = flows[host].get(peer, 0) + total
        return flows


    def main():
        metrics = Metrics()
        ok = False

        hosts = set()
        for name, direction, family in SETS:
            for addr, (byte_count, packet_count) in read_set(name).items():
                ok = True
                hosts.add(addr)
                labels = {"client": addr, "direction": direction}
                metrics.add(
                    "router_host_bytes_total",
                    "Bytes forwarded for a LAN address, by direction",
                    "counter",
                    labels,
                    byte_count,
                )
                metrics.add(
                    "router_host_packets_total",
                    "Packets forwarded for a LAN address, by direction",
                    "counter",
                    labels,
                    packet_count,
                )

        for host, peers in parse_conntrack(hosts).items():
            total = sum(peers.values())
            if total <= 0:
                continue
            top_peer, top_bytes = max(peers.items(), key=lambda item: item[1])
            metrics.add(
                "router_host_top_peer_share_ratio",
                "Fraction of a device's currently tracked bytes held by its single largest peer",
                "gauge",
                {"client": host},
                f"{top_bytes / total:.4f}",
            )
            metrics.add(
                "router_host_peer_count",
                "Distinct peers a device has live flows with",
                "gauge",
                {"client": host},
                len(peers),
            )
            metrics.add(
                "router_host_top_peer_info",
                "The peer currently holding the largest share of a device's traffic",
                "gauge",
                {"client": host, "peer": top_peer},
                1,
            )

        metrics.add(
            "router_host_collector_success",
            "Whether the host flow collector produced any samples on this run",
            "gauge",
            {},
            1 if ok else 0,
        )

        # Same write-and-rename as qos-metrics.nix, for the same reason: a
        # half-written file is not stale, it is a parse error that discards
        # every metric in the directory rather than only this one.
        directory = os.path.dirname(OUT)
        try:
            handle, tmp = tempfile.mkstemp(dir=directory, suffix=".tmp")
            with os.fdopen(handle, "w") as fh:
                fh.write(metrics.render())
            os.chmod(tmp, 0o644)
            os.replace(tmp, OUT)
        except OSError as err:
            print(f"host-flow-textfile: cannot write {OUT}: {err}", file=sys.stderr)
            return 1
        return 0


    sys.exit(main())
  '';
in
{
  config = lib.mkIf (cfg.enable && config.sifr.personal.o11y.client.enable) {
    # Conntrack tracks every flow regardless; this only asks it to keep the
    # byte and packet totals it otherwise throws away. Off by default, which is
    # why `conntrack -L` prints no counters until this is set.
    boot.kernel.sysctl."net.netfilter.nf_conntrack_acct" = 1;

    # A table of its own rather than a chain inside router-filter. It is gated
    # on the o11y client the same way the collector is, and keeping it separate
    # means the accounting can appear and disappear with that gate without
    # touching a table that decides whether packets live.
    #
    # policy accept and nothing but `update`, so this cannot alter the fate of
    # a packet — the worst it can do is cost a hash lookup per forwarded frame.
    networking.nftables.tables.router-hostacct = {
      family = "inet";
      content = ''
        # `flags dynamic` plus `counter` is what gives each element its own
        # byte and packet counter, which is the whole mechanism: one rule per
        # direction, and every address that appears gets counted without
        # anything having to enumerate the LAN first.
        #
        # No timeout deliberately. Elements would otherwise expire and reset
        # their counters, and a counter that silently restarts is worse than
        # one that grows: the set is bounded by the DHCP pool, and a reload
        # clears it anyway, which Prometheus already handles as a counter
        # reset.
        set hosts_up4 {
          type ipv4_addr
          flags dynamic
          counter
        }

        set hosts_down4 {
          type ipv4_addr
          flags dynamic
          counter
        }

        set hosts_up6 {
          type ipv6_addr
          flags dynamic
          counter
        }

        set hosts_down6 {
          type ipv6_addr
          flags dynamic
          counter
        }

        chain host-accounting {
          type filter hook forward priority filter + 10; policy accept;

          # Keyed on the interface rather than on an address range, so the
          # direction label means "towards the LAN" or "away from it" no matter
          # how the LAN is addressed. Traffic that never crosses lan0 is not
          # counted, which is intended: LAN-to-LAN says nothing about a tunnel.
          iifname "${cfg.lan0}" meta nfproto ipv4 update @hosts_up4 { ip saddr } comment "Per-host upload bytes (IPv4)"
          oifname "${cfg.lan0}" meta nfproto ipv4 update @hosts_down4 { ip daddr } comment "Per-host download bytes (IPv4)"
          iifname "${cfg.lan0}" meta nfproto ipv6 update @hosts_up6 { ip6 saddr } comment "Per-host upload bytes (IPv6)"
          oifname "${cfg.lan0}" meta nfproto ipv6 update @hosts_down6 { ip6 daddr } comment "Per-host download bytes (IPv6)"
        }
      '';
    };

    systemd.services.host-flow-textfile = {
      description = "Collect per-host traffic statistics into a Prometheus textfile";

      path = with pkgs; [
        nftables
        conntrack-tools
      ];

      serviceConfig = {
        Type = "oneshot";
        ExecStart = lib.getExe hostTextfile;

        # CAP_NET_ADMIN for the nft listing and the conntrack dump, and nothing
        # else — same treatment as the QoS collector next door.
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

    systemd.timers.host-flow-textfile = {
      description = "Sample per-host traffic statistics regularly";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        # Slower than the QoS collector's 15s. That one reads a qdisc tree;
        # this one walks the whole conntrack table, which is thousands of
        # entries on a busy link. The share figure is a property of a
        # conversation rather than of an instant, so a coarser sample loses
        # nothing that matters.
        OnBootSec = "45s";
        OnUnitActiveSec = "60s";
        AccuracySec = "5s";
      };
    };
  };
}
