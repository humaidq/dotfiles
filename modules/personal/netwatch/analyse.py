"""Deterministic analysis of a capture window.

Pure by construction: reads files, writes JSON, performs no network access.
Every check here is a threshold or a set membership. Nothing in this file
decides what a service is — see the design doc on why classification is
deliberately out of scope.
"""

import json
import sys

FLOW_COLUMNS = 15

# IPv6 headers that only chain to the next one. The protocol of a v6 packet is
# the first ipv6.nxt value that is not one of these — "0,6" is TCP behind a
# hop-by-hop header, not protocol 0.
#
# 51 (AH) is deliberately absent even though it is an extension header: it is
# in TUNNEL_PROTOS, and an AH-protected flow is exactly the thing that check
# exists to surface, so it must stay visible as the protocol rather than be
# skipped over to reach the payload behind it.
EXTENSION_HEADERS = {"0", "43", "44", "60", "135", "139", "140"}


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


def _outer(value):
    """The first value of a possibly repeated tshark field.

    tshark emits one comma-separated value per occurrence of a field in the
    frame, and an ICMP or ICMPv6 error quotes the packet that caused it — so
    the addresses of such a frame arrive as "outer,inner". The outer pair is
    the conversation this device is actually having; the inner one belongs to
    a flow already accounted for elsewhere. Taking the first value keeps the
    peer key on the real endpoint instead of a literal "a,b" that matches
    nothing and reads as an unexplained peer.
    """
    return value.split(",")[0].strip()


def _protocol(value):
    """The transport protocol number from ip.proto or ipv6.nxt.

    Skips past extension headers, which is why this is not just _outer: a
    fragmented or hop-by-hop-tagged v6 packet reports the chain, and the
    protocol wanted is the one at the end of it.
    """
    for part in value.split(","):
        part = part.strip()
        if part and part not in EXTENSION_HEADERS:
            return part
    return ""


def parse_flows(text):
    """Parse tshark's tab-separated output into flow dicts.

    Ports arrive in separate TCP and UDP columns because tshark emits one or
    the other; this collapses them into a single pair plus a protocol name.

    Addresses arrive in separate IPv4 and IPv6 columns for the same reason,
    and collapse the same way. Downstream cares about the family only through
    the address text itself, so nothing below this function has to branch on
    it — a v6 peer is a peer whose "ip" happens to contain colons.

    A frame carrying both families is one tunnelled inside the other, and IPv4
    wins. That is right for 6in4, where the v4 header is the outer one and the
    tunnel is what should be reported: the row comes out as protocol 41 to a
    real endpoint. It is wrong for 4in6, where it reports the inner
    conversation and loses the tunnel — accepted because these fields carry no
    header order to decide by, and no ordering gets both cases right. 4in6 is
    also the rarer of the two here, and cannot come from a low-trust device at
    all: the router denies that pool IPv6 to the WAN outright.
    """
    rows = []
    for line in text.split("\n"):
        if not line.strip():
            continue
        cols = line.split("\t")
        if len(cols) < FLOW_COLUMNS:
            continue
        ip_src = _outer(cols[3]) or _outer(cols[6])
        ip_dst = _outer(cols[4]) or _outer(cols[7])
        proto_num = _protocol(cols[5]) or _protocol(cols[8])
        if proto_num == "6":
            proto, sport, dport = "tcp", cols[9], cols[10]
        elif proto_num == "17":
            proto, sport, dport = "udp", cols[11], cols[12]
        else:
            proto, sport, dport = proto_num or "other", "", ""
        rows.append({
            "ts": cols[0],
            "eth_src": cols[1].lower(),
            "eth_dst": cols[2].lower(),
            "ip_src": ip_src,
            "ip_dst": ip_dst,
            "proto": proto,
            "sport": _int(_outer(sport)),
            "dport": _int(_outer(dport)),
            "length": _int(cols[13]),
            "sni": cols[14].strip(),
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


def count_unaddressed(flows, mac):
    """Count this device's frames that carried no IP address of either family.

    What is left after both families are parsed is layer-2 traffic: ARP, EAPOL,
    LLDP and the like. Some of that is unavoidable background on any LAN, so
    the count is a coverage note rather than a finding — it exists so that a
    device whose capture is mostly unparseable says so, instead of reading as
    "0 bytes across 0 peers" as if nothing had been captured at all.

    This used to count IPv6 as well, because tshark's ip.src/ip.dst are
    IPv4-only fields and left a v6 frame blank in both. That is no longer true:
    parse_flows reads ipv6.src/ipv6.dst, so v6 flows are aggregated like any
    other and no longer land here.
    """
    mac = mac.lower()
    count = 0
    for flow in flows:
        if flow["eth_src"] != mac and flow["eth_dst"] != mac:
            continue
        if not flow["ip_src"] and not flow["ip_dst"]:
            count += 1
    return count


BLOCKED_VERDICTS = {"BLOCKED"}
RESOLVED_VERDICTS = {"RESOLVED", "CACHED"}


def read_dnsmap(text):
    """Return {address: domain} from the full resolver history.

    The map must be built from all available history rather than the capture
    window. The resolver caches for hours and prefetches, so an address in use
    now may have been resolved long before the window opened; correlating
    against the window alone reports ordinary CDN peers as unexplained.

    A third column, if present, is the unix time the pair was last seen. It is
    written by the importer and ignored here.

    Last row wins, not first: the importer appends freshly seen pairs after the
    retained ones, so an address that has been reassigned resolves to whatever
    owns it now rather than to whatever held it first.
    """
    mapping = {}
    for line in text.split("\n"):
        if not line.strip():
            continue
        parts = line.split("\t")
        if len(parts) < 2:
            continue
        mapping[parts[1].strip()] = parts[0].strip()
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
    if share >= TOP_PEER_SHARE:
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
        unaddressed = count_unaddressed(flows, mac)
        if unaddressed:
            observations.append({
                "check": "non_ip_not_analysed",
                "severity": 0,
                "detail": "{} frames carried no IP address of either family"
                          " and were not analysed; this is ARP and other"
                          " layer-2 traffic, so it is a coverage note rather"
                          " than a finding".format(unaddressed),
            })
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
