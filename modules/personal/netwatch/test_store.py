#!/usr/bin/env python3
import os
import tempfile
import unittest

import store

OBS = {
    "run_ts": 1754000000,
    "captured": True,
    "skip_reason": None,
    "devices": [{
        "mac": "aa:bb:cc:dd:ee:01",
        "label": "phone-a",
        "total_bytes": 800,
        "peer_count": 2,
        "peers": [
            {"ip": "192.0.2.10", "port": 443, "proto": "tcp",
             "bytes_out": 500, "bytes_in": 200, "packets": 2,
             "sni": "example.com", "resolved_name": "example.com",
             "explained": True},
            {"ip": "192.0.2.77", "port": 4500, "proto": "udp",
             "bytes_out": 100, "bytes_in": 0, "packets": 1,
             "sni": "", "resolved_name": "", "explained": False},
        ],
        "novelty": {"new_for_device": [], "new_for_network": [],
                    "top_resolved": [], "blocked_count": 0},
        "observations": [],
    }],
}


class TestNetKeys(unittest.TestCase):
    def test_net24_and_net16(self):
        self.assertEqual(store.net24("192.0.2.10"), "192.0.2.0/24")
        self.assertEqual(store.net16("192.0.2.10"), "192.0.0.0/16")

    def test_non_ipv4_yields_empty_keys(self):
        self.assertEqual(store.net24("2001:db8::1"), "")
        self.assertEqual(store.net16("garbage"), "")


class TestIngest(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.db = os.path.join(self.dir.name, "store.db")

    def tearDown(self):
        self.dir.cleanup()

    def test_inserts_one_row_per_peer(self):
        conn = store.connect(self.db)
        self.assertEqual(store.ingest(conn, OBS), 2)
        rows = conn.execute("SELECT mac, ip, port, net24 FROM peer_obs "
                            "ORDER BY ip").fetchall()
        self.assertEqual(rows[0][1], "192.0.2.10")
        self.assertEqual(rows[0][3], "192.0.2.0/24")

    def test_records_explained_flag_and_sni(self):
        conn = store.connect(self.db)
        store.ingest(conn, OBS)
        row = conn.execute("SELECT explained, sni FROM peer_obs "
                           "WHERE ip='192.0.2.10'").fetchone()
        self.assertEqual(row[0], 1)
        self.assertEqual(row[1], "example.com")

    def test_ingesting_twice_accumulates_history(self):
        conn = store.connect(self.db)
        store.ingest(conn, OBS)
        store.ingest(conn, OBS)
        count = conn.execute("SELECT COUNT(*) FROM peer_obs").fetchone()[0]
        self.assertEqual(count, 4)

    def test_rotation_query_counts_distinct_addresses_per_net24(self):
        conn = store.connect(self.db)
        store.ingest(conn, OBS)
        other = {"run_ts": 1754000100, "captured": True, "skip_reason": None,
                 "devices": [dict(OBS["devices"][0],
                                  peers=[dict(OBS["devices"][0]["peers"][1],
                                              ip="192.0.2.78")])]}
        store.ingest(conn, other)
        row = conn.execute(
            "SELECT net24, COUNT(DISTINCT ip) FROM peer_obs "
            "WHERE explained=0 GROUP BY net24").fetchone()
        self.assertEqual(row, ("192.0.2.0/24", 2))

    def test_skipped_run_inserts_no_peer_rows_but_records_the_run(self):
        conn = store.connect(self.db)
        skipped = {"run_ts": 1754000200, "captured": False,
                   "skip_reason": "no ssh socket", "devices": []}
        self.assertEqual(store.ingest(conn, skipped), 0)
        row = conn.execute("SELECT captured, skip_reason FROM runs "
                           "ORDER BY run_ts DESC").fetchone()
        self.assertEqual(row, (0, "no ssh socket"))


class TestPrune(unittest.TestCase):
    def test_removes_rows_older_than_cutoff(self):
        with tempfile.TemporaryDirectory() as d:
            conn = store.connect(os.path.join(d, "s.db"))
            store.ingest(conn, OBS)
            self.assertEqual(store.prune(conn, 1754000001), 2)
            self.assertEqual(
                conn.execute("SELECT COUNT(*) FROM peer_obs").fetchone()[0], 0)


if __name__ == "__main__":
    unittest.main()
