#!/usr/bin/env python3
"""Deterministic analysis of a capture window.

Pure by construction: reads files, writes JSON, performs no network access.
Every check here is a threshold or a set membership. Nothing in this file
decides what a service is — see the design doc on why classification is
deliberately out of scope.
"""

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
        scopes.setdefault(parts[0].strip().lower(), set()).add(parts[1].strip())
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
