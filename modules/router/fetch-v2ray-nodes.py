#!/usr/bin/env python3
"""Fetch public v2ray/xray subscription lists and emit the throttleable nodes.

WHY THIS EXISTS
---------------
Public "free config" repositories publish thousands of vless/vmess/trojan/
shadowsocks/hysteria2 endpoints as a plain-text subscription and rewrite them
every few minutes. A client pointed at one never resolves an endpoint by name —
it reads an address out of the file and dials it — so the node is invisible to
every DNS instrument the router has, and blocking nodes one at a time cannot
win against a list that replaces them faster than they can be added.

What CAN be done is take the list itself. It is public, unauthenticated, and it
names the operator's whole estate in one fetch. That is what this does.

The output feeds custom-vpn-intel-throttle.txt, which is shaped for LOW-TRUST
POOL DEVICES ONLY. That scope is not incidental — it is what makes a list this
size acceptable. The output is far too large to check address by address, so it
must not be able to reach devices outside the pool; custom-throttle-list.txt is
the house-wide file and stays hand-curated for exactly that reason.

It is intel, not evidence: an address here has been PUBLISHED as a proxy
endpoint, which is a much stronger provenance than "a device talked to it", but
it has NOT been probed, and no certificate or PTR has been read for most of
them. Say that when quoting it.

WHY MOST OF THE LIST IS THROWN AWAY
-----------------------------------
Roughly a quarter of the endpoints are CDN addresses, and they are worse than
useless — they are actively dangerous. With SNI-routed fronting the client can
dial ANY edge address of the CDN and put the real host in the TLS SNI and the
WebSocket Host header, so the address carries no information about the node.
Shaping it only degrades whatever else the house reaches through that edge.

That is not hypothetical. Real entries removed by these filters:

  * 1.1.1.1  — published as a hysteria2 endpoint, and on lowTrustNeverCover
               because it is the resolver half the network depends on.
  * 127.0.0.1 — published as an endpoint. Throttling loopback is nonsense; a
               private address would have matched LAN traffic.
  * 104.20.77.131, 172.64.143.172 — Cloudflare anycast that the ASN table has
               no row for, so an ASN-only filter passes them straight through.

Hence three independent CDN guards, not one. Each catches what the others miss.

FILTERS, IN ORDER
-----------------
  1. Not globally routable (loopback, private, reserved, multicast, link-local).
  2. On the never-cover list — the resolver, the Akamai edges, the STUN server,
     this operator's own host. Hard refusal, never a warning.
  3. Inside a prefix the CDN itself publishes (Cloudflare and Fastly serve
     machine-readable lists). This is the guard that catches unlisted anycast.
  4. Originated by a CDN / shared-edge AS, looked up in a MaxMind GeoLite2 ASN
     table. See --asn-table: the router keeps a current one, and it places ~10%
     more addresses than the ip2asn-combined.tsv checked into this repo.
  5. No origin AS in the table at all. Excluded rather than kept: filter 4
     never got to clear them, and 2 of the 22 in the first run were Cloudflare.
  6. Already covered by custom-throttle-list.txt or custom-ip-blocklist.txt.
     Tested by CONTAINMENT, not string equality — those files are mostly CIDRs
     now, so an exact-match dedupe silently re-adds addresses already shaped.
  7. An Amazon address whose PTR is not *.compute.amazonaws.com, including one
     with no PTR at all. See below.

AMAZON IS KEPT ONLY WHEN ITS PTR PROVES IT, MICROSOFT IS NOT KEPT AT ALL
------------------------------------------------------------------------
AS16509 and AS8075 each carry both tenant compute and the provider's own CDN
edge, so the AS number alone cannot separate a rented VM from a shared edge.
Reverse DNS can, for one of them: an EC2 tenant resolves to
*.compute.amazonaws.com and a CloudFront edge does not.

THIS USED TO BE A ONE-TIME MANUAL CHECK AND IT ROTTED. The first run looked up
all 126 Amazon addresses by hand, found every one was EC2, and that became a
line in the header of custom-vpn-intel-throttle.txt asserting there was no
CloudFront among them. On 2026-08-30 the run kept 108 Amazon addresses and one
of them, 18.239.134.69, reverse-resolved to
server-18-239-134-69.bkk50.r.cloudfront.net. A shared CDN edge is the one thing
this file must never shape, so the check is now filter 7 and runs every time.

Azure VMs get no PTR by default, so the same test cannot distinguish a VM from
a Front Door edge and AS8075 stays on the CDN list, dropped wholesale. That is
the same rule filter 7 applies to an Amazon address with no PTR: an unchecked
address is worse than no address. Microsoft publishes service tags that would
settle it, behind a confirmation page this script will not scrape.

USAGE
-----
  ./fetch-v2ray-nodes.py                      # addresses, one per line
  ./fetch-v2ray-nodes.py --stats              # what was kept and what was cut
  ./fetch-v2ray-nodes.py --rejects            # what was cut, with the reason
  ./fetch-v2ray-nodes.py --asn-table PATH     # default /var/lib/geoip/asn.tsv
  ./fetch-v2ray-nodes.py --url URL            # repeatable; replaces the default
  ./fetch-v2ray-nodes.py --no-ptr-check       # skip filter 7 (needs a resolver)

Run it on the router, or pass --asn-table pointing at this directory's
ip2asn-combined.tsv to run it anywhere. Needs no credentials.
"""

import argparse
import base64
import bisect
import concurrent.futures
import ipaddress
import json
import os
import pathlib
import socket
import sys
import urllib.parse
import urllib.request
from collections import Counter

HERE = pathlib.Path(__file__).resolve().parent

# Where the filter lists actually are. They became sops secrets on 2026-09-03
# and no longer sit beside this script, so point this at a decrypted checkout:
#
#   .claude/skills/editing-sops-lists/lists.sh checkout
#   ROUTER_LISTS_DIR=.lists-work python3 modules/router/fetch-v2ray-nodes.py
#   .claude/skills/editing-sops-lists/lists.sh commit
#
# ip2asn-combined.tsv is public data and stays beside the script, so it keeps
# using HERE.
LISTS = pathlib.Path(os.environ.get("ROUTER_LISTS_DIR", HERE))

# The aggregate of every Sub*.txt in the repository, refreshed upstream every
# few minutes. The per-Sub files are strict subsets, so fetching this one is
# both cheaper and more complete than walking them.
DEFAULT_URLS = [
    "https://raw.githubusercontent.com/Epodonios/v2ray-configs/main/All_Configs_Sub.txt",
]

# Published by the CDNs themselves, so they stay correct as the estates grow.
CDN_PREFIX_SOURCES = {
    "cloudflare": "https://www.cloudflare.com/ips-v4",
    "fastly": "https://api.fastly.com/public-ip-list",
}

# Shared-edge networks: an address here is reachable by SNI from any node, so
# it identifies nothing and shaping it hits the house. Tenant-compute networks
# (Hetzner, OVH, DigitalOcean, Linode/Akamai Connected Cloud, Oracle, Vultr,
# Contabo, Scaleway, …) are deliberately NOT here — those are the real nodes.
#
# AS63949 is "Akamai Connected Cloud", which is LINODE, a VPS provider, and not
# the Akamai edge. Filtering it on the word "Akamai" would throw away 23 real
# nodes. The Akamai edge ASNs are 20940 and 16625.
CDN_ASNS = {
    13335: "Cloudflare",
    209242: "Cloudflare London / Spectrum",
    54113: "Fastly",
    212238: "Datacamp / CDN77",
    60068: "CDN77",
    199524: "G-Core Labs",
    208006: "ArvanCloud CDN",
    57568: "ArvanCloud",
    20940: "Akamai edge",
    16625: "Akamai edge",
    15169: "Google",
    8075: "Microsoft — compute and Front Door share the ASN, see module docstring",
    13238: "Yandex CDN",
    202015: "Bunny CDN",
    56655: "Bunny CDN",
}

# Mirrors lowTrustNeverCover in ip-blocklist.nix. Duplicated rather than
# imported because this is a standalone script run by hand; if that list grows,
# grow this one. A mismatch here is caught by the build-time tripwire on the
# generated set, not by this script.
NEVER = {
    "1.1.1.1",
    "1.0.0.1",
    "95.100.170.42",
    "23.44.201.155",
    "74.125.250.129",
    "185.93.2.251",
    "143.244.56.58",
    "45.59.120.67",
}


def get(url: str) -> bytes:
    req = urllib.request.Request(url, headers={"User-Agent": "curl/8"})
    with urllib.request.urlopen(req, timeout=60) as r:
        return r.read()


def b64pad(s: str) -> str:
    s = s.strip().replace("-", "+").replace("_", "/")
    return s + "=" * (-len(s) % 4)


def endpoints(text: str):
    """Yield the host of every config line, across all six URI dialects."""
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "://" not in line:
            continue
        scheme = line.split("://", 1)[0].lower()
        body = line.split("://", 1)[1]
        try:
            if scheme == "vmess":
                # vmess:// is base64 of a JSON object; the host is "add".
                d = json.loads(base64.b64decode(b64pad(body)).decode("utf-8", "replace"))
                host = str(d.get("add", ""))
            elif scheme == "ss":
                # Either base64(method:pass@host:port) or base64(method:pass)@host:port.
                b = body.split("#", 1)[0]
                if "@" not in b:
                    b = base64.b64decode(b64pad(b)).decode("utf-8", "replace")
                host = b.rsplit("@", 1)[-1].split("?", 1)[0].rpartition(":")[0]
            else:
                host = urllib.parse.urlsplit(line).hostname or ""
        except Exception:
            # A malformed line in someone else's list is not our problem, and
            # must never abort the run — these files carry thousands of entries
            # written by many tools.
            continue
        host = host.strip().strip("[]").rstrip(".")
        if host:
            yield host


def load_asn_table(path: pathlib.Path):
    """Sorted (start, end, asn) ranges from a MaxMind- or ip2asn-style TSV."""
    rows = []
    for row in path.read_text(errors="replace").splitlines():
        p = row.split("\t")
        if len(p) < 3:
            continue
        try:
            lo, hi, asn = ipaddress.ip_address(p[0]), ipaddress.ip_address(p[1]), int(p[2])
        except ValueError:
            continue
        if lo.version == 4:
            rows.append((int(lo), int(hi), asn))
    if not rows:
        raise SystemExit(f"{path}: no usable rows — wrong file?")
    rows.sort()
    return rows, [r[0] for r in rows]


def covered_by(nets, addr):
    for n in nets:
        if addr in n:
            return n
    return None


def amazon_ptrs(addrs):
    """Reverse-resolve Amazon addresses, concurrently. {addr: ptr-or-None}."""
    def one(a):
        try:
            return a, socket.gethostbyaddr(str(a))[0].rstrip(".").lower()
        except Exception:
            # NXDOMAIN, timeout and SERVFAIL are indistinguishable here and are
            # treated the same way by the caller, so there is nothing to gain
            # from telling them apart.
            return a, None

    if not addrs:
        return {}
    with concurrent.futures.ThreadPoolExecutor(max_workers=32) as pool:
        return dict(pool.map(one, addrs))


def read_list_cidrs(path: pathlib.Path):
    """Every prefix in one of the router's own .txt lists, as networks."""
    out = []
    if not path.exists():
        return out
    for line in path.read_text().splitlines():
        s = line.split("#", 1)[0].strip()
        if not s:
            continue
        try:
            out.append(ipaddress.ip_network(s, strict=False))
        except ValueError:
            continue
    return out


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--url", action="append", default=None)
    ap.add_argument("--asn-table", default="/var/lib/geoip/asn.tsv")
    ap.add_argument("--stats", action="store_true")
    ap.add_argument("--rejects", action="store_true")
    ap.add_argument(
        "--no-ptr-check",
        action="store_true",
        help="skip the Amazon EC2 reverse-DNS filter (see FILTER 7)",
    )
    args = ap.parse_args()

    urls = args.url or DEFAULT_URLS
    table = pathlib.Path(args.asn_table)
    if not table.exists():
        raise SystemExit(
            f"{table}: not found. Run this on the router, or pass "
            f"--asn-table {HERE / 'ip2asn-combined.tsv'} to use the checked-in table."
        )
    rows, starts = load_asn_table(table)

    def origin_as(addr):
        a = int(addr)
        i = bisect.bisect_right(starts, a) - 1
        if i < 0 or a > rows[i][1]:
            return None
        return rows[i][2]

    cdn_nets = []
    cf = get(CDN_PREFIX_SOURCES["cloudflare"]).decode()
    cdn_nets += [ipaddress.ip_network(l.strip()) for l in cf.splitlines() if l.strip()]
    fa = json.loads(get(CDN_PREFIX_SOURCES["fastly"]))
    cdn_nets += [
        ipaddress.ip_network(p) for p in fa.get("addresses", []) if ":" not in p
    ]

    already = read_list_cidrs(LISTS / "custom-throttle-list.txt") + read_list_cidrs(
        LISTS / "custom-ip-blocklist.txt"
    )

    hosts, domains = set(), set()
    for url in urls:
        for host in endpoints(get(url).decode("utf-8", "replace")):
            try:
                hosts.add(ipaddress.ip_address(host))
            except ValueError:
                domains.add(host.lower())

    keep, rejects, why = [], [], Counter()
    for a in sorted(hosts, key=int):
        if a.version != 4:
            rejects.append((a, "IPv6 endpoint — pool policy is v4-only"))
            why["IPv6"] += 1
        elif not a.is_global:
            rejects.append((a, "not globally routable"))
            why["not globally routable"] += 1
        elif str(a) in NEVER:
            rejects.append((a, "on the never-cover list"))
            why["never-cover"] += 1
        elif (n := covered_by(cdn_nets, a)) is not None:
            rejects.append((a, f"published CDN prefix {n}"))
            why["published CDN prefix"] += 1
        elif (asn := origin_as(a)) is None:
            rejects.append((a, "no origin AS in the table"))
            why["no origin AS"] += 1
        elif asn in CDN_ASNS:
            rejects.append((a, f"CDN AS{asn} ({CDN_ASNS[asn]})"))
            why[f"CDN AS{asn}"] += 1
        elif (n := covered_by(already, a)) is not None:
            rejects.append((a, f"already covered by {n}"))
            why["already listed"] += 1
        else:
            keep.append(a)

    # FILTER 7: Amazon addresses must prove they are EC2 by reverse DNS.
    #
    # AS16509 carries both tenant compute and CloudFront, and the AS number
    # cannot tell them apart — see the module docstring. That was checked by
    # hand once, found 126 addresses all resolving to *.compute.amazonaws.com,
    # and the conclusion "no CloudFront among them" was written into the header
    # of custom-vpn-intel-throttle.txt as though it were a property of Amazon
    # rather than a fact about one day's list.
    #
    # It stopped being true. The 2026-08-30 run kept 108 Amazon addresses, of
    # which 18.239.134.69 reverse-resolved to
    # server-18-239-134-69.bkk50.r.cloudfront.net — a CloudFront edge, in a
    # file whose entire premise is that shaping a shared edge degrades the
    # house. A second had no PTR at all. A one-time manual check cannot hold a
    # list that upstream rewrites every few minutes, so the check runs here.
    #
    # No PTR is a rejection, not a pass. That is the same rule already applied
    # to Azure, whose VMs get no PTR either: an unchecked address is worse than
    # no address.
    if not args.no_ptr_check:
        amazon = [a for a in keep if origin_as(a) == 16509]
        ptrs = amazon_ptrs(amazon)
        confirmed = sum(1 for p in ptrs.values() if p and p.endswith(".compute.amazonaws.com"))
        # A resolver that is down would reject every Amazon address and look
        # exactly like a list that happens to contain none — a silent 100-odd
        # address change. Refuse to guess.
        if amazon and confirmed == 0:
            raise SystemExit(
                f"PTR check: none of {len(amazon)} Amazon addresses resolved to "
                f"*.compute.amazonaws.com. That is far more likely to be a broken "
                f"resolver than a list with no EC2 nodes in it. Fix resolution, or "
                f"pass --no-ptr-check to skip this filter and accept that CloudFront "
                f"edges may end up in the output."
            )
        survivors = []
        for a in keep:
            ptr = ptrs.get(a) if a in ptrs else None
            if a not in ptrs:
                survivors.append(a)
            elif ptr is None:
                rejects.append((a, "Amazon address with no PTR — unverifiable as EC2"))
                why["Amazon, no PTR"] += 1
            elif ptr.endswith(".compute.amazonaws.com"):
                survivors.append(a)
            else:
                rejects.append((a, f"Amazon address, non-EC2 PTR {ptr}"))
                why["Amazon, not EC2"] += 1
        keep = survivors

    if args.stats:
        print(f"subscription URLs   : {len(urls)}", file=sys.stderr)
        print(f"unique IP endpoints : {len(hosts)}", file=sys.stderr)
        print(f"domain endpoints    : {len(domains)} (not used — see the .txt header)",
              file=sys.stderr)
        print(f"kept                : {len(keep)}", file=sys.stderr)
        print(f"rejected            : {len(rejects)}", file=sys.stderr)
        for k, v in why.most_common():
            print(f"  {v:>5}  {k}", file=sys.stderr)
        return 0

    if args.rejects:
        for a, reason in rejects:
            print(f"{a}\t{reason}")
        return 0

    for a in keep:
        print(a)
    print(f"fetch-v2ray-nodes: {len(keep)} kept, {len(rejects)} rejected",
          file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
