#!/usr/bin/env python3
"""Reduce a window of the router's DNS query log to the part worth reading.

Reads blocky's "query resolved" lines (the journal on bongo/bingo), aggregates
them, drops what is already understood, and prints what is left.

Three things get dropped, and each is counted rather than silently discarded:

  common     the domain is in the common-domains list, which is a sops secret.
             Vendor infrastructure whose lookup tells you nothing.
  blocked    the query was BLOCKED. It is already handled; the fact that a
             device keeps asking is a retry count, not a new finding.
  local      the name is in a local zone, or is a search-domain retry of one
             (`foo.example.com.v6.alq.ae`), which is an artefact of a failed
             lookup rather than a lookup.

What survives is grouped by registrable domain and sorted by how unusual it
looks — fewest distinct clients first, because one device asking for something
nothing else asks for is the shape a finding has.

Usage:
  dns-review.py --since "48 hours ago" [--host bongo] [--common FILE]
  dns-review.py --file captured.log --common FILE

Without --common the filter still runs, minus the common-domains stage; it says
so rather than pretending it filtered.
"""

import argparse
import collections
import os
import re
import subprocess
import sys

# Registrable domain needs the public-suffix exceptions or "com.au" becomes the
# domain and every Australian site collapses into one row.
MULTI_LABEL_SUFFIXES = {
    "co.uk", "org.uk", "ac.uk", "gov.uk", "com.au", "net.au", "org.au",
    "co.jp", "com.br", "co.in", "net.in", "org.in", "com.cn", "net.cn",
    "com.hk", "com.sg", "com.tr", "com.mx", "co.za", "com.ar", "com.ph",
    "co.id", "com.my", "co.kr", "com.tw", "co.nz", "com.pk", "com.eg",
    "co.il", "com.sa", "net.sa", "com.qa", "com.kw", "com.bh", "com.om",
    "com.jo", "com.lb", "com.ae", "net.ae", "org.ae", "gov.ae", "ac.ae",
    "sch.ae", "com.ua", "com.ru", "com.pl", "com.ve", "com.co", "com.pe",
    "com.ng", "com.gh", "com.vn", "com.bd", "com.np", "com.lk",
}

LINE = re.compile(
    r"question_name=(?P<name>\S+)"
    r"|client_names=(?P<client>\S+)"
    r"|response_type=(?P<rtype>\S+)"
    r"|response_reason=(?P<reason>.*?) response_type="
)


def registrable(name):
    parts = name.rstrip(".").split(".")
    if len(parts) >= 3 and ".".join(parts[-2:]) in MULTI_LABEL_SUFFIXES:
        return ".".join(parts[-3:])
    return ".".join(parts[-2:]) if len(parts) >= 2 else name


def load_common(path):
    """One registrable domain per line, `#` comments. Missing file is fatal:
    running unfiltered by accident produces a wall of output that looks like a
    result."""
    if path is None:
        return None
    if not os.path.exists(path):
        sys.exit(
            f"{path}: not found. It is a sops secret — decrypt it first:\n"
            f"  sops -d secrets/router/dns-common-domains.txt > /tmp/common.txt"
        )
    out = set()
    with open(path) as fh:
        for line in fh:
            line = line.split("#", 1)[0].strip().lower().rstrip(".")
            if line:
                out.add(line)
    return out


def covered_by(name, domains):
    """Suffix match on label boundaries. `notapple.com` must not match
    `apple.com`, which a plain endswith would let through."""
    labels = name.split(".")
    for i in range(len(labels)):
        if ".".join(labels[i:]) in domains:
            return ".".join(labels[i:])
    return None


def parse(stream):
    """Yields (name, client, rtype, reason) per query-resolved line."""
    for line in stream:
        if "query resolved" not in line:
            continue
        name = client = rtype = reason = None
        m = re.search(r"question_name=(\S+)", line)
        if m:
            name = m.group(1).lower().rstrip(".")
        m = re.search(r"client_names=(\S+)", line)
        if m:
            client = m.group(1)
        m = re.search(r"response_type=(\S+)", line)
        if m:
            rtype = m.group(1)
        m = re.search(r"response_reason=(.*?) response_type=", line)
        if m:
            reason = m.group(1)
        if name:
            yield name, client or "-", rtype or "-", reason or "-"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--since", default="48 hours ago")
    ap.add_argument("--host", default="bongo", help="ssh target, or 'local'")
    ap.add_argument("--file", help="read a saved log instead of the journal")
    ap.add_argument("--common", help="decrypted common-domains list")
    ap.add_argument(
        "--local-zone",
        action="append",
        default=[],
        help="a local zone suffix, e.g. alq.ae. Repeatable.",
    )
    ap.add_argument("--min-clients", type=int, default=0,
                    help="only show names asked for by at most N clients (0 = no limit)")
    ap.add_argument("--show-blocked", action="store_true",
                    help="also list what was blocked, as retry counts")
    args = ap.parse_args()

    common = load_common(args.common)
    local_zones = {z.lower().strip(".") for z in args.local_zone}

    if args.file:
        stream = open(args.file, errors="replace")
    elif args.host == "local":
        stream = subprocess.Popen(
            ["journalctl", "-u", "blocky", "--since", args.since, "--no-pager", "-o", "cat"],
            stdout=subprocess.PIPE, text=True, errors="replace",
        ).stdout
    else:
        # One ssh connection: every fresh one costs a hardware key touch.
        stream = subprocess.Popen(
            ["ssh", "-o", "ControlMaster=auto", "-o", "ControlPath=/tmp/cc-dnsreview-%r@%h",
             "-o", "ControlPersist=30m", args.host,
             f"journalctl -u blocky --since {args.since!r} --no-pager -o cat"],
            stdout=subprocess.PIPE, text=True, errors="replace",
        ).stdout

    total = 0
    dropped = collections.Counter()
    folded = collections.Counter()          # common domain -> distinct names hidden
    folded_names = collections.defaultdict(set)
    blocked = collections.Counter()
    keep = collections.defaultdict(lambda: {"n": 0, "clients": collections.Counter(),
                                            "types": set()})

    for name, client, rtype, reason in parse(stream):
        total += 1

        if any(name == z or name.endswith("." + z) for z in local_zones):
            dropped["local"] += 1
            continue

        if rtype == "BLOCKED":
            dropped["blocked"] += 1
            blocked[(registrable(name), reason)] += 1
            continue

        if common is not None:
            hit = covered_by(name, common)
            if hit:
                dropped["common"] += 1
                folded[hit] += 1
                folded_names[hit].add(name)
                continue

        entry = keep[name]
        entry["n"] += 1
        entry["clients"][client] += 1
        entry["types"].add(rtype)

    print(f"# {total} query-resolved lines")
    for reason_key in ("local", "blocked", "common"):
        if dropped[reason_key]:
            print(f"#   -{dropped[reason_key]:>7} {reason_key}")
    if common is None:
        print("#   (no --common list given; common-domain filtering was skipped)")
    kept_names = sorted(
        keep.items(),
        key=lambda kv: (len(kv[1]["clients"]), -kv[1]["n"]),
    )
    if args.min_clients:
        kept_names = [kv for kv in kept_names if len(kv[1]["clients"]) <= args.min_clients]
    print(f"# {len(keep)} names left to review"
          f"{f', {len(kept_names)} shown' if args.min_clients else ''}\n")

    by_domain = collections.defaultdict(list)
    for name, e in kept_names:
        by_domain[registrable(name)].append((name, e))

    order = sorted(
        by_domain.items(),
        key=lambda kv: (len({c for _, e in kv[1] for c in e["clients"]}),
                        -sum(e["n"] for _, e in kv[1])),
    )
    for domain, names in order:
        clients = {c for _, e in names for c in e["clients"]}
        hits = sum(e["n"] for _, e in names)
        print(f"{domain}   [{hits} queries, {len(clients)} client(s)]")
        for name, e in sorted(names, key=lambda kv: -kv[1]["n"]):
            who = ", ".join(f"{c}({n})" for c, n in e["clients"].most_common())
            print(f"    {e['n']:>5}  {name:<52} {'/'.join(sorted(e['types']))}  {who}")
        print()

    if folded:
        print("# folded away by the common list (largest first) — if one of these "
              "is hiding a lot, look at it")
        for d, n in folded.most_common(15):
            print(f"#   {n:>7} queries, {len(folded_names[d]):>4} distinct names  {d}")

    if args.show_blocked and blocked:
        print("\n# blocked (already handled; these are retry counts)")
        for (d, reason), n in blocked.most_common(30):
            print(f"#   {n:>7}  {d:<40} {reason}")


if __name__ == "__main__":
    main()
