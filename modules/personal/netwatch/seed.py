"""Build the DNS indexes and domain baseline from resolver history.

Both the correlation and the novelty check are worthless without history, and
there is already months of it. Importing once means the tool is useful on its
first run rather than after a month of accumulation.
"""

import re
import sys

CLIENT_RE = re.compile(r"client_ip=(\S+)")
QUESTION_RE = re.compile(r"question_name=(\S+)")
VERDICT_RE = re.compile(r"response_type=(\w+)")
ANSWER_RE = re.compile(r"A \((\d+\.\d+\.\d+\.\d+)\)")

BLOCKED_ANSWERS = {"0.0.0.0", "127.0.0.1"}


def parse_line(line):
    """Extract one query from a resolver log line, or None."""
    question = QUESTION_RE.search(line)
    if not question:
        return None
    client = CLIENT_RE.search(line)
    verdict = VERDICT_RE.search(line)
    return {
        "client": client.group(1) if client else "",
        "domain": question.group(1).rstrip("."),
        "verdict": verdict.group(1) if verdict else "-",
        "answers": ANSWER_RE.findall(line),
    }


def _eui64(mac):
    """The IPv6 link-local address a MAC yields under EUI-64.

    Devices using RFC 7217 stable-privacy addresses cannot be mapped this way
    and are simply not matched; their IPv6 queries stay unattributed rather
    than being attributed to the wrong device.
    """
    parts = mac.lower().split(":")
    if len(parts) != 6:
        return ""
    first = int(parts[0], 16) ^ 0x02
    return "fe80::{:02x}{}:{}ff:fe{}:{}{}".format(
        first, parts[1], parts[2], parts[3], parts[4], parts[5])


def _client_index(leases_text):
    """Map every address a device is known by back to its MAC."""
    index = {}
    for line in leases_text.split("\n"):
        parts = line.split()
        if len(parts) < 3:
            continue
        mac, ip = parts[1].lower(), parts[2]
        index[ip] = mac
        link_local = _eui64(mac)
        if link_local:
            index[link_local] = mac
    return index


def build_indexes(lines, leases_text):
    """Return (dnsmap_tsv, dnsq_tsv, baseline_tsv).

    The baseline is scope-tagged: a "net" row means the network has resolved
    the domain before, a MAC row means that device has. The two answer
    different questions and both are cheap to record.
    """
    clients = _client_index(leases_text)
    dnsmap = []
    seen_pairs = set()
    dnsq = []
    baseline = []
    baseline_seen = set()

    for line in lines:
        row = parse_line(line)
        if not row:
            continue
        for answer in row["answers"]:
            if answer in BLOCKED_ANSWERS:
                continue
            pair = (row["domain"], answer)
            if pair in seen_pairs:
                continue
            seen_pairs.add(pair)
            dnsmap.append("{}\t{}".format(*pair))
        mac = clients.get(row["client"])
        if mac:
            dnsq.append(
                "{}\t{}\t{}".format(mac, row["domain"], row["verdict"])
            )
        if row["verdict"] in ("RESOLVED", "CACHED"):
            for scope in ("net", mac):
                if not scope:
                    continue
                key = (scope, row["domain"])
                if key in baseline_seen:
                    continue
                baseline_seen.add(key)
                baseline.append("{}\t{}".format(*key))

    return "\n".join(dnsmap), "\n".join(dnsq), "\n".join(baseline)


def main(argv):
    if len(argv) != 5:
        sys.stderr.write(
            "usage: seed LEASES DNSMAP_OUT DNSQ_OUT BASELINE_TSV_OUT\n"
            "resolver log is read from stdin\n"
        )
        return 2
    with open(argv[1]) as handle:
        leases = handle.read()
    dnsmap, dnsq, baseline = build_indexes(
        sys.stdin.read().split("\n"), leases
    )
    outputs = ((argv[2], dnsmap), (argv[3], dnsq), (argv[4], baseline))
    for path, data in outputs:
        with open(path, "w") as handle:
            handle.write(data)
            handle.write("\n")
    sys.stderr.write(
        "seeded {} mappings, {} queries, {} domains\n".format(
            dnsmap.count("\n") + 1,
            dnsq.count("\n") + 1,
            baseline.count("\n") + 1,
        )
    )
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
