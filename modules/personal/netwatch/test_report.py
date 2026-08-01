#!/usr/bin/env python3
import unittest

import report

OBS = {
    "run_ts": 1754000000,
    "captured": True,
    "skip_reason": None,
    "devices": [{
        "mac": "aa:bb:cc:dd:ee:01",
        "label": "phone-a",
        "total_bytes": 1000,
        "peer_count": 2,
        "peers": [
            {"ip": "192.0.2.99", "port": 4500, "proto": "udp",
             "bytes_out": 800, "bytes_in": 100, "packets": 9,
             "sni": "", "resolved_name": "", "explained": False},
            {"ip": "192.0.2.10", "port": 443, "proto": "tcp",
             "bytes_out": 80, "bytes_in": 20, "packets": 2,
             "sni": "example.com", "resolved_name": "example.com",
             "explained": True},
        ],
        "novelty": {"new_for_device": ["fresh.example"],
                    "new_for_network": [], "top_resolved": [("example.com", 3)],
                    "blocked_count": 4},
        "observations": [
            {"check": "top_peer_share", "severity": 2,
             "detail": "top peer 192.0.2.99:4500 holds 90.0% of 1000 bytes"},
            {"check": "new_domain_device", "severity": 0,
             "detail": "first time this device resolved fresh.example"},
        ],
    }],
}

SKIPPED = {"run_ts": 1754000300, "captured": False,
           "skip_reason": "no ssh socket", "devices": []}


class TestRender(unittest.TestCase):
    def test_includes_device_label_and_totals(self):
        text = report.render(OBS)
        self.assertIn("phone-a", text)
        self.assertIn("1000 bytes", text)
        self.assertIn("2 peers", text)

    def test_lists_observations_most_severe_first(self):
        text = report.render(OBS)
        self.assertLess(text.index("top_peer_share"),
                        text.index("new_domain_device"))

    def test_shows_top_peers_with_share(self):
        text = report.render(OBS)
        self.assertIn("192.0.2.99", text)
        self.assertIn("90.0%", text)

    def test_marks_unexplained_peers(self):
        text = report.render(OBS)
        line = [l for l in text.splitlines() if "192.0.2.99" in l][0]
        self.assertIn("no-dns", line)

    def test_counts_blocked_answers_without_listing_them(self):
        text = report.render(OBS)
        self.assertIn("blocked answers: 4", text)

    def test_skipped_run_says_so_loudly_and_has_no_findings(self):
        text = report.render(SKIPPED)
        self.assertIn("RUN SKIPPED: no ssh socket", text)
        self.assertNotIn("peers", text)


if __name__ == "__main__":
    unittest.main()
