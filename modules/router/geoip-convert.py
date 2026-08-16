"""Flatten MaxMind's GeoLite2 CSVs into sorted range tables.

Two editions, one shape. Country joins Blocks to Locations for an ISO code;
ASN needs no join, its Blocks file already carries the number and the
organisation. Both come out as start/end range tables the router reads with the
same binary search, which is why they share a script rather than having one
each that drifts.

The distributed CSV is two files that have to be joined: Blocks lists networks
against a numeric geoname_id, and Locations maps that id to an ISO country
code. Doing the join here, once per download, rather than in the router's web
server means the server loads one file in exactly the shape it already reads
ip2asn-combined.tsv in, and needs no CSV parser, no second index and no
MaxMind-specific knowledge at all.

Output is "<start>\\t<end>\\t<cc>", sorted by start address within each family,
because the reader binary-searches it.

Two country columns exist in the Blocks file and the difference is the whole
reason this work is being done:

  * geoname_id is where the network IS. For 2a04:4e42:80::/48 that is AE —
    Fastly's Dubai POP.
  * registered_country_geoname_id is where the operator is registered. For the
    same network that is US, which is exactly what ip2asn-combined.tsv reports
    for the entire /32 it can see.

geoname_id wins here, and falls back to the registered country only when the
row has none — some networks are registered but not placed, and a registration
is a better answer than a blank.
"""

import csv
import ipaddress
import os
import sys

BLOCKS = (
    "GeoLite2-Country-Blocks-IPv4.csv",
    "GeoLite2-Country-Blocks-IPv6.csv",
)
LOCATIONS = "GeoLite2-Country-Locations-en.csv"


def read_locations(path):
    """Return {geoname_id: iso country code}, skipping rows with no code."""
    codes = {}
    with open(path, newline="") as handle:
        for row in csv.DictReader(handle):
            code = (row.get("country_iso_code") or "").strip()
            if code:
                codes[row["geoname_id"]] = code
    return codes


def read_blocks(path, codes):
    """Yield (start, end, cc) for every network that resolves to a country."""
    with open(path, newline="") as handle:
        for row in csv.DictReader(handle):
            try:
                network = ipaddress.ip_network(row["network"])
            except (ValueError, KeyError):
                continue
            code = codes.get(row.get("geoname_id", ""))
            if not code:
                code = codes.get(row.get("registered_country_geoname_id", ""))
            if not code:
                continue
            yield network[0], network[-1], code


ASN_BLOCKS = (
    "GeoLite2-ASN-Blocks-IPv4.csv",
    "GeoLite2-ASN-Blocks-IPv6.csv",
)


def read_asn_blocks(path):
    """Yield (start, end, "asn\t\torg") for every network with a number.

    The empty middle column is the country, which LoadASNTable still reads at
    that position and peers.go no longer uses — the country comes from the
    Country edition now, because an AS registration is not where a network is.
    Emitting the column keeps the reader's five-field layout untouched.
    """
    with open(path, newline="") as handle:
        for row in csv.DictReader(handle):
            try:
                network = ipaddress.ip_network(row["network"])
                number = int(row["autonomous_system_number"])
            except (ValueError, KeyError):
                continue
            org = (row.get("autonomous_system_organization") or "").strip()
            org = org.replace("\t", " ")
            yield network[0], network[-1], "{}\t\t{}".format(number, org)


def build_asn(directory):
    """Render the ASN table from an unpacked GeoLite2-ASN-CSV."""
    rows = []
    for name in ASN_BLOCKS:
        path = os.path.join(directory, name)
        if os.path.exists(path):
            rows.extend(read_asn_blocks(path))
    if not rows:
        raise SystemExit("geoip-convert: no usable ASN blocks found")
    rows.sort(key=lambda r: (r[0].version, r[0].packed))
    # NOT coalesced. Two adjacent ranges of the same AS are genuinely one
    # range, but the value carries the organisation string too, and merging on
    # a string comparison of every row buys far less here than it did for
    # two-letter country codes while risking joining two ASNs whose names
    # happen to match.
    return "\n".join(
        "{}\t{}\t{}".format(s, e, rest) for s, e, rest in rows)


def build(directory):
    """Render the whole table from an unpacked GeoLite2-Country-CSV."""
    codes = read_locations(os.path.join(directory, LOCATIONS))
    if not codes:
        raise SystemExit("geoip-convert: no country codes in " + LOCATIONS)

    rows = []
    for name in BLOCKS:
        path = os.path.join(directory, name)
        if not os.path.exists(path):
            # Either family may be absent from a partial extract. Missing one
            # is not fatal — half a table still answers half the peers — but
            # both missing is caught by the emptiness check below.
            continue
        rows.extend(read_blocks(path, codes))

    if not rows:
        raise SystemExit("geoip-convert: no usable blocks found")

    # Sorted by family then start address, which is the order the reader's
    # binary search assumes. Sorting on the packed form rather than the text
    # is what makes "10.0.0.0" order after "9.0.0.0" instead of before it.
    rows.sort(key=lambda r: (r[0].version, r[0].packed))
    return "\n".join(
        "{}\t{}\t{}".format(s, e, cc) for s, e, cc in coalesce(rows))


def coalesce(rows):
    """Merge ranges that touch and share a country.

    MaxMind distributes this as CIDR blocks, so a single country's allocation
    arrives split across however many prefixes it takes to express it — a /20
    and a /21 and a /24 in sequence, all the same answer. Merging them is a
    pure win: the file the router loads and holds in memory gets smaller, and
    every lookup is a binary search over fewer rows for an identical result.

    Only exactly adjacent ranges are merged. A gap, however small, is a range
    MaxMind has no country for, and swallowing it would invent an answer for
    addresses the data deliberately does not place.
    """
    merged = []
    for start, end, code in rows:
        if merged:
            last_start, last_end, last_code = merged[-1]
            if (last_code == code
                    and last_end.version == start.version
                    and int(last_end) + 1 == int(start)):
                merged[-1] = (last_start, end, code)
                continue
        merged.append((start, end, code))
    return merged


def main(argv):
    if len(argv) != 4 or argv[1] not in ("country", "asn"):
        sys.stderr.write(
            "usage: geoip-convert <country|asn> CSV_DIRECTORY OUT\n")
        return 2
    renderer = build if argv[1] == "country" else build_asn
    rendered = renderer(argv[2]) + "\n"

    # Written and renamed. router-web reads this file at startup and the
    # updater replaces it underneath a running server; a truncating write would
    # give a restart in that window a half-parsed table, which is worse than an
    # old one because it fails silently — a missing range just reports no
    # country.
    tmp = argv[3] + ".tmp"
    with open(tmp, "w") as handle:
        handle.write(rendered)
        handle.flush()
        os.fsync(handle.fileno())
    os.replace(tmp, argv[3])
    sys.stderr.write("geoip-convert: wrote {} {} ranges\n".format(
        rendered.count("\n"), argv[1]))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
