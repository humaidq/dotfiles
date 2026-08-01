#!/usr/bin/env python3
import unittest

import seed

LOG = "\n".join([
    'INFO queryLog: query resolved answer=A (192.0.2.10) '
    'client_ip=198.51.100.5 question_name=example.com. response_type=RESOLVED',
    'INFO queryLog: query blocked answer=A (0.0.0.0) '
    'client_ip=198.51.100.5 question_name=bad.example. response_type=BLOCKED',
    'INFO queryLog: query resolved answer=A (192.0.2.30), A (192.0.2.31) '
    'client_ip=fe80::a8bb:ccff:fedd:ee01 question_name=two.example. '
    'response_type=RESOLVED',
    'unrelated log line with no query at all',
])

LEASES = "0 aa:bb:cc:dd:ee:01 198.51.100.5 phone-a *\n"


class TestParseLine(unittest.TestCase):
    def test_extracts_fields_and_answers(self):
        row = seed.parse_line(LOG.split("\n")[0])
        self.assertEqual(row["client"], "198.51.100.5")
        self.assertEqual(row["domain"], "example.com")
        self.assertEqual(row["verdict"], "RESOLVED")
        self.assertEqual(row["answers"], ["192.0.2.10"])

    def test_returns_none_for_unrelated_lines(self):
        self.assertIsNone(seed.parse_line("unrelated log line"))

    def test_strips_trailing_dot_from_domain(self):
        row = seed.parse_line(LOG.split("\n")[1])
        self.assertEqual(row["domain"], "bad.example")


class TestBuildIndexes(unittest.TestCase):
    def test_dnsmap_has_one_row_per_answer(self):
        dnsmap, _, _ = seed.build_indexes(LOG.split("\n"), LEASES)
        rows = sorted(l for l in dnsmap.split("\n") if l)
        self.assertIn("example.com\t192.0.2.10", rows)
        self.assertIn("two.example\t192.0.2.31", rows)

    def test_blocked_answers_are_excluded_from_dnsmap(self):
        dnsmap, _, _ = seed.build_indexes(LOG.split("\n"), LEASES)
        self.assertNotIn("0.0.0.0", dnsmap)

    def test_queries_are_keyed_by_mac_via_the_lease_file(self):
        _, dnsq, _ = seed.build_indexes(LOG.split("\n"), LEASES)
        self.assertIn("aa:bb:cc:dd:ee:01\texample.com\tRESOLVED", dnsq)

    def test_ipv6_link_local_maps_back_to_the_same_mac(self):
        _, dnsq, _ = seed.build_indexes(LOG.split("\n"), LEASES)
        self.assertIn("aa:bb:cc:dd:ee:01\ttwo.example\tRESOLVED", dnsq)

    def test_baseline_tags_the_network_scope(self):
        _, _, baseline = seed.build_indexes(LOG.split("\n"), LEASES)
        rows = [l for l in baseline.split("\n") if l]
        self.assertIn("net\texample.com", rows)
        self.assertIn("net\ttwo.example", rows)

    def test_baseline_also_tags_each_device_scope(self):
        _, _, baseline = seed.build_indexes(LOG.split("\n"), LEASES)
        rows = [l for l in baseline.split("\n") if l]
        self.assertIn("aa:bb:cc:dd:ee:01\texample.com", rows)

    def test_blocked_domains_are_not_baselined(self):
        _, _, baseline = seed.build_indexes(LOG.split("\n"), LEASES)
        self.assertNotIn("bad.example", baseline)


if __name__ == "__main__":
    unittest.main()
