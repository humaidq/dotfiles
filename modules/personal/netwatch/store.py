#!/usr/bin/env python3
"""Durable observation store.

A per-run report cannot answer whether something has been happening for weeks.
This store can, and the columns that make it possible are net24 and net16: an
operator renting a fresh address every session leaves no repeated address, so
history keyed on the address alone shows unrelated peers. Grouped by the
network that owns them, the same data shows a count of distinct addresses
inside one range, which is what rotation looks like.
"""

import json
import sqlite3
import sys

SCHEMA = """
CREATE TABLE IF NOT EXISTS runs (
    run_ts      INTEGER PRIMARY KEY,
    captured    INTEGER NOT NULL,
    skip_reason TEXT
);
CREATE TABLE IF NOT EXISTS peer_obs (
    run_ts        INTEGER NOT NULL,
    mac           TEXT NOT NULL,
    label         TEXT NOT NULL,
    ip            TEXT NOT NULL,
    port          INTEGER NOT NULL,
    proto         TEXT NOT NULL,
    bytes_out     INTEGER NOT NULL,
    bytes_in      INTEGER NOT NULL,
    packets       INTEGER NOT NULL,
    sni           TEXT NOT NULL,
    resolved_name TEXT NOT NULL,
    explained     INTEGER NOT NULL,
    net24         TEXT NOT NULL,
    net16         TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS peer_obs_net24 ON peer_obs (net24);
CREATE INDEX IF NOT EXISTS peer_obs_mac_ts ON peer_obs (mac, run_ts);
CREATE TABLE IF NOT EXISTS domain_seen (
    domain    TEXT PRIMARY KEY,
    first_ts  INTEGER NOT NULL
);
"""


def _octets(ip):
    parts = ip.split(".")
    if len(parts) != 4:
        return None
    try:
        values = [int(p) for p in parts]
    except ValueError:
        return None
    if any(v < 0 or v > 255 for v in values):
        return None
    return values


def net24(ip):
    """Enclosing /24, or empty string if the address is not IPv4."""
    values = _octets(ip)
    if values is None:
        return ""
    return "{}.{}.{}.0/24".format(*values[:3])


def net16(ip):
    """Enclosing /16, or empty string if the address is not IPv4."""
    values = _octets(ip)
    if values is None:
        return ""
    return "{}.{}.0.0/16".format(*values[:2])


def connect(path):
    conn = sqlite3.connect(path)
    conn.executescript(SCHEMA)
    conn.commit()
    return conn


def ingest(conn, observations):
    """Append one run. Returns the number of peer rows written."""
    run_ts = observations["run_ts"]
    conn.execute(
        "INSERT OR REPLACE INTO runs (run_ts, captured, skip_reason) "
        "VALUES (?, ?, ?)",
        (run_ts, 1 if observations.get("captured") else 0,
         observations.get("skip_reason")))

    written = 0
    for device in observations.get("devices", []):
        for peer in device.get("peers", []):
            conn.execute(
                "INSERT INTO peer_obs (run_ts, mac, label, ip, port, proto,"
                " bytes_out, bytes_in, packets, sni, resolved_name,"
                " explained, net24, net16)"
                " VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
                (run_ts, device["mac"], device["label"], peer["ip"],
                 peer["port"], peer["proto"], peer["bytes_out"],
                 peer["bytes_in"], peer["packets"], peer.get("sni", ""),
                 peer.get("resolved_name", ""),
                 1 if peer.get("explained") else 0,
                 net24(peer["ip"]), net16(peer["ip"])))
            written += 1
        for domain in device.get("novelty", {}).get("new_for_device", []):
            conn.execute(
                "INSERT OR IGNORE INTO domain_seen (domain, first_ts) "
                "VALUES (?, ?)", (domain, run_ts))
    conn.commit()
    return written


def prune(conn, older_than_ts):
    """Delete peer rows older than a cutoff. Returns rows removed.

    Only peer rows are pruned. The runs table and domain_seen are tiny and are
    what tell you the tool was running at all, so they are kept.
    """
    cur = conn.execute("DELETE FROM peer_obs WHERE run_ts < ?",
                       (older_than_ts,))
    conn.commit()
    return cur.rowcount


def main(argv):
    if len(argv) < 3:
        sys.stderr.write("usage: store DB OBSERVATIONS_JSON [PRUNE_BEFORE]\n")
        return 2
    conn = connect(argv[1])
    with open(argv[2]) as handle:
        observations = json.load(handle)
    written = ingest(conn, observations)
    if len(argv) > 3:
        prune(conn, int(argv[3]))
    sys.stderr.write("stored {} peer rows\n".format(written))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
