"""Build the DNS indexes and domain baseline from resolver history.

Both the correlation and the novelty check are worthless without history, and
there is already months of it. Importing once means the tool is useful on its
first run rather than after a month of accumulation.
"""

import os
import re
import sys
import time

CLIENT_RE = re.compile(r"client_ip=(\S+)")
QUESTION_RE = re.compile(r"question_name=(\S+)")
VERDICT_RE = re.compile(r"response_type=(\w+)")
# Both families, because dnsmap is what makes a peer "explained" and a v6 peer
# left out of it reads as an unexplained endpoint carrying volume — the tool's
# loudest signal, fabricated.
#
# The leading \b is load-bearing. Without it "A \(" also matches the last A of
# "AAAA (", and the alternation would then capture v6 answers twice. It also
# keeps CAA out: the A in "CAA (" is preceded by another letter, so no word
# boundary precedes it.
ANSWER_RE = re.compile(r"\b(?:A|AAAA) \(([0-9A-Fa-f.:]+)\)")

# The v6 half of blocky's zeroIp block answer, alongside the v4 one. Without
# it every blocked AAAA would enter dnsmap as a real address for its domain,
# and :: would come back "explained" as whatever was blocked most recently.
BLOCKED_ANSWERS = {"0.0.0.0", "127.0.0.1", "::", "::1"}


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


DNSMAP_KEEP_DAYS = 90


def _read_dnsmap_rows(text):
    """Parse dnsmap rows into (domain, address, last_seen_ts).

    A row without a timestamp predates that column; treat it as seen now so a
    format upgrade does not silently discard the whole accumulated file.
    """
    rows = []
    for line in text.split("\n"):
        if not line.strip():
            continue
        parts = line.split("\t")
        if len(parts) < 2:
            continue
        try:
            ts = int(parts[2])
        except (IndexError, ValueError):
            ts = None
        rows.append((parts[0].strip(), parts[1].strip(), ts))
    return rows


def _write_atomic(path, data):
    """Write via a temp file and rename.

    These files are now the only copy of accumulated history — they are no
    longer regenerable from the journal, which is windowed. A truncating write
    interrupted by a crash or a full disk would reset the baseline, and that
    reappears as a burst of fabricated novelty findings: exactly the signal
    this tool exists to produce, and so the one that must never be an artefact
    of its own failure.
    """
    tmp = path + ".tmp"
    with open(tmp, "w") as handle:
        handle.write(data)
        handle.write("\n")
        handle.flush()
        os.fsync(handle.fileno())
    os.replace(tmp, path)


def _read_pairs(text):
    """Parse tab-separated two-column lines into an ordered list of pairs."""
    pairs = []
    for line in text.split("\n"):
        if not line.strip():
            continue
        parts = line.split("\t")
        if len(parts) < 2:
            continue
        pairs.append((parts[0].strip(), parts[1].strip()))
    return pairs


def build_indexes(
    lines, leases_text, existing_dnsmap="", existing_baseline="",
    now_ts=0, keep_days=DNSMAP_KEEP_DAYS
):
    """Return (dnsmap_tsv, dnsq_tsv, baseline_tsv).

    The baseline is scope-tagged: a "net" row means the network has resolved
    the domain before, a MAC row means that device has. The two answer
    different questions and both are cheap to record.

    dnsmap and baseline are unions, not snapshots: existing_dnsmap and
    existing_baseline seed the output so a domain already known stays known
    even after it rotates out of the journal this call reads from stdin.
    Without this, a run that only sees a shrinking window of history would
    make long-known domains look newly resolved.
    """
    clients = _client_index(leases_text)
    # Retained rows are emitted before freshly seen ones, and the reader takes
    # the last row for an address. A reassigned address therefore resolves to
    # whatever owns it now, and stale entries age out rather than pinning an
    # address to its first-ever owner forever.
    cutoff = now_ts - keep_days * 86400 if now_ts else 0
    dnsmap = []
    seen_pairs = set()
    for domain, answer, ts in _read_dnsmap_rows(existing_dnsmap):
        pair = (domain, answer)
        if pair in seen_pairs:
            continue
        stamp = now_ts if ts is None else ts
        if cutoff and stamp < cutoff:
            continue
        seen_pairs.add(pair)
        dnsmap.append("{}\t{}\t{}".format(domain, answer, stamp))

    dnsq = []
    baseline = []
    baseline_seen = set()
    for scope, domain in _read_pairs(existing_baseline):
        key = (scope, domain)
        if key in baseline_seen:
            continue
        baseline_seen.add(key)
        baseline.append("{}\t{}".format(*key))

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
            dnsmap.append("{}\t{}\t{}".format(
                row["domain"], answer, now_ts))
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


def _read_if_present(path):
    try:
        with open(path) as handle:
            return handle.read()
    except FileNotFoundError:
        return ""


def main(argv):
    if len(argv) not in (5, 6):
        sys.stderr.write(
            "usage: seed LEASES DNSMAP_OUT DNSQ_OUT BASELINE_TSV_OUT"
            " [EXISTING_BASELINE]\n"
            "resolver log is read from stdin\n"
            "DNSMAP_OUT and EXISTING_BASELINE (or BASELINE_TSV_OUT if"
            " EXISTING_BASELINE is omitted) are read before being"
            " overwritten, so their prior contents are unioned in\n"
        )
        return 2
    with open(argv[1]) as handle:
        leases = handle.read()
    existing_dnsmap = _read_if_present(argv[2])
    existing_baseline_path = argv[5] if len(argv) == 6 else argv[4]
    existing_baseline = _read_if_present(existing_baseline_path)
    dnsmap, dnsq, baseline = build_indexes(
        sys.stdin.read().split("\n"), leases,
        existing_dnsmap, existing_baseline, int(time.time()),
    )
    outputs = ((argv[2], dnsmap), (argv[3], dnsq), (argv[4], baseline))
    for path, data in outputs:
        _write_atomic(path, data)
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
