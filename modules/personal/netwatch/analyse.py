"""Deterministic analysis of a capture window.

Pure by construction: reads files, writes JSON, performs no network access.
Every check here is a threshold or a set membership. Nothing in this file
decides what a service is — see the design doc on why classification is
deliberately out of scope.
"""

import json
import sys

FLOW_COLUMNS = 12


def read_devices(path):
    """Return {lowercase mac: label} from a whitespace-separated watchlist."""
    devices = {}
    with open(path) as handle:
        for line in handle:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            parts = line.split()
            if len(parts) < 2:
                continue
            devices[parts[0].lower()] = parts[1]
    return devices


def _int(value):
    try:
        return int(value)
    except (TypeError, ValueError):
        return 0


def parse_flows(text):
    """Parse tshark's tab-separated output into flow dicts.

    Ports arrive in separate TCP and UDP columns because tshark emits one or
    the other; this collapses them into a single pair plus a protocol name.
    """
    rows = []
    for line in text.split("\n"):
        if not line.strip():
            continue
        cols = line.split("\t")
        if len(cols) < FLOW_COLUMNS:
            continue
        proto_num = cols[5].strip()
        if proto_num == "6":
            proto, sport, dport = "tcp", cols[6], cols[7]
        elif proto_num == "17":
            proto, sport, dport = "udp", cols[8], cols[9]
        else:
            proto, sport, dport = proto_num or "other", "", ""
        rows.append({
            "ts": cols[0],
            "eth_src": cols[1].lower(),
            "eth_dst": cols[2].lower(),
            "ip_src": cols[3],
            "ip_dst": cols[4],
            "proto": proto,
            "sport": _int(sport),
            "dport": _int(dport),
            "length": _int(cols[10]),
            "sni": cols[11].strip(),
        })
    return rows


def aggregate_peers(flows, mac):
    """Aggregate a device's flows into per-peer byte counts.

    Direction is decided by the Ethernet address, not the IP, so the result is
    correct regardless of which address the device currently holds.
    """
    mac = mac.lower()
    peers = {}
    total = 0
    for flow in flows:
        outbound = flow["eth_src"] == mac
        inbound = flow["eth_dst"] == mac
        if not (outbound or inbound):
            continue
        if outbound:
            ip, port = flow["ip_dst"], flow["dport"]
        else:
            ip, port = flow["ip_src"], flow["sport"]
        if not ip:
            continue
        key = (ip, port, flow["proto"])
        peer = peers.setdefault(key, {
            "ip": ip, "port": port, "proto": flow["proto"],
            "bytes_out": 0, "bytes_in": 0, "packets": 0, "sni": "",
        })
        peer["bytes_out" if outbound else "bytes_in"] += flow["length"]
        peer["packets"] += 1
        if flow["sni"] and not peer["sni"]:
            peer["sni"] = flow["sni"]
        total += flow["length"]
    ordered = sorted(peers.values(),
                     key=lambda p: p["bytes_out"] + p["bytes_in"],
                     reverse=True)
    return ordered, total


BLOCKED_VERDICTS = {"BLOCKED"}
RESOLVED_VERDICTS = {"RESOLVED", "CACHED"}


def read_dnsmap(text):
    """Return {address: domain} from the full resolver history.

    The map must be built from all available history rather than the capture
    window. The resolver caches for hours and prefetches, so an address in use
    now may have been resolved long before the window opened; correlating
    against the window alone reports ordinary CDN peers as unexplained.
    """
    mapping = {}
    for line in text.split("\n"):
        if not line.strip():
            continue
        parts = line.split("\t")
        if len(parts) < 2:
            continue
        mapping.setdefault(parts[1].strip(), parts[0].strip())
    return mapping


def read_queries(text):
    """Return [(mac, domain, verdict)] from the resolver query log."""
    rows = []
    for line in text.split("\n"):
        if not line.strip():
            continue
        parts = line.split("\t")
        if len(parts) < 3:
            continue
        rows.append((parts[0].strip().lower(),
                     parts[1].strip(), parts[2].strip()))
    return rows


def annotate_peers(peers, dnsmap):
    """Add resolved_name and explained to each peer, in place."""
    for peer in peers:
        name = dnsmap.get(peer["ip"], "")
        peer["resolved_name"] = name
        peer["explained"] = bool(name)


def read_baselines(text):
    """Return {scope: {domain}}. Scope is "net" or a device MAC."""
    scopes = {}
    for line in text.split("\n"):
        if not line.strip():
            continue
        parts = line.split("\t")
        if len(parts) < 2:
            continue
        scope = parts[0].strip().lower()
        scopes.setdefault(scope, set()).add(parts[1].strip())
    return scopes


def novelty(queries, mac, baselines):
    """Domains new to this device and to the network, plus verdict counts.

    Novelty is the deterministic stand-in for rotation. An operator moving to a
    fresh registrable domain produces a first-seen entry without anyone having
    to know what the operator is.

    The two scopes answer different questions. Network-new means nothing here
    has ever resolved it. Device-new means this device started reaching
    something the household already used, which is the weaker but still useful
    signal.
    """
    mac = mac.lower()
    device_seen = baselines.get(mac, set())
    network_seen = baselines.get("net", set())
    counts = {}
    blocked = 0
    mine = []
    for row_mac, domain, verdict in queries:
        if row_mac != mac:
            continue
        if verdict in BLOCKED_VERDICTS:
            blocked += 1
            continue
        if verdict not in RESOLVED_VERDICTS:
            continue
        counts[domain] = counts.get(domain, 0) + 1
        if domain not in mine:
            mine.append(domain)
    return {
        "new_for_device": [d for d in mine if d not in device_seen],
        "new_for_network": [d for d in mine if d not in network_seen],
        "top_resolved": sorted(counts.items(), key=lambda kv: (-kv[1], kv[0])),
        "blocked_count": blocked,
    }


TOP_PEER_SHARE = 0.70
VPN_PORTS = {500, 4500, 1194, 51820}
TUNNEL_PROTOS = {"47", "50", "51"}
UNEXPLAINED_MIN_BYTES = 100_000
UNEXPLAINED_MIN_SHARE = 0.20


def check_shape(peers, total):
    """Threshold checks over aggregated peers. No judgement, no naming."""
    observations = []
    if not peers or total <= 0:
        return observations

    top = peers[0]
    share = (top["bytes_out"] + top["bytes_in"]) / total
    if share > TOP_PEER_SHARE:
        observations.append({
            "check": "top_peer_share",
            "severity": 2,
            "detail": "top peer {}:{} holds {:.1f}% of {} bytes".format(
                top["ip"], top["port"], share * 100, total),
        })

    for peer in peers:
        if peer["port"] in VPN_PORTS or peer["proto"] in TUNNEL_PROTOS:
            observations.append({
                "check": "vpn_port",
                "severity": 2,
                "detail": "{}:{}/{} carried {} bytes".format(
                    peer["ip"], peer["port"], peer["proto"],
                    peer["bytes_out"] + peer["bytes_in"]),
            })

    for peer in peers:
        volume = peer["bytes_out"] + peer["bytes_in"]
        if peer.get("explained"):
            continue
        if (
            volume < UNEXPLAINED_MIN_BYTES
            and volume / total < UNEXPLAINED_MIN_SHARE
        ):
            continue
        observations.append({
            "check": "unexplained_peer",
            "severity": 1,
            "detail": "{}:{} carried {} bytes with no lookup{}".format(
                peer["ip"], peer["port"], volume,
                " (SNI " + peer["sni"] + ")" if peer["sni"] else ""),
        })

    return observations


def build(flows_text, dnsmap_text, queries_text, devices, baselines, run_ts):
    """Assemble the full observations structure for every watched device."""
    flows = parse_flows(flows_text)
    dnsmap = read_dnsmap(dnsmap_text)
    queries = read_queries(queries_text)

    entries = []
    for mac, label in sorted(devices.items()):
        peers, total = aggregate_peers(flows, mac)
        annotate_peers(peers, dnsmap)
        observations = check_shape(peers, total)
        fresh = novelty(queries, mac, baselines)
        for domain in fresh["new_for_network"]:
            observations.append({
                "check": "new_domain_network",
                "severity": 1,
                "detail": "first time anything here resolved {}".format(
                    domain
                ),
            })
        for domain in fresh["new_for_device"]:
            if domain in fresh["new_for_network"]:
                continue
            observations.append({
                "check": "new_domain_device",
                "severity": 0,
                "detail": "first time this device resolved {}".format(domain),
            })
        observations.sort(key=lambda o: -o["severity"])
        entries.append({
            "mac": mac,
            "label": label,
            "total_bytes": total,
            "peer_count": len(peers),
            "peers": peers,
            "novelty": fresh,
            "observations": observations,
        })

    return {
        "run_ts": run_ts,
        "captured": True,
        "skip_reason": None,
        "devices": entries,
    }


def main(argv):
    if len(argv) != 7:
        sys.stderr.write(
            "usage: analyse FLOWS DNSMAP QUERIES DEVICES BASELINES RUN_TS\n")
        return 2
    flows_p, dnsmap_p, queries_p, devices_p, baselines_p, run_ts = argv[1:]
    with open(flows_p) as f:
        flows_text = f.read()
    with open(dnsmap_p) as f:
        dnsmap_text = f.read()
    with open(queries_p) as f:
        queries_text = f.read()
    try:
        with open(baselines_p) as f:
            baselines = read_baselines(f.read())
    except FileNotFoundError:
        baselines = {}
    result = build(flows_text, dnsmap_text, queries_text,
                   read_devices(devices_p), baselines, int(run_ts))
    json.dump(result, sys.stdout, indent=2, sort_keys=True)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
