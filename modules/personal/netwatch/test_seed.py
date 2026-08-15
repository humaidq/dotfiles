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
    'INFO queryLog: query resolved answer=AAAA (2606:4700::1111) '
    'client_ip=198.51.100.5 question_name=six.example. '
    'response_type=RESOLVED',
    'INFO queryLog: query blocked answer=AAAA (::) '
    'client_ip=198.51.100.5 question_name=bad6.example. '
    'response_type=BLOCKED',
    'INFO queryLog: query resolved answer=A (192.0.2.40), '
    'AAAA (2606:4700::2222) '
    'client_ip=198.51.100.5 question_name=dual.example. '
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
    def _pairs(self, dnsmap):
        """Drop the last-seen timestamp column."""
        return sorted("\t".join(l.split("\t")[:2])
                      for l in dnsmap.split("\n") if l)

    def test_dnsmap_has_one_row_per_answer(self):
        dnsmap, _, _ = seed.build_indexes(LOG.split("\n"), LEASES)
        rows = self._pairs(dnsmap)
        self.assertIn("example.com\t192.0.2.10", rows)
        self.assertIn("two.example\t192.0.2.31", rows)

    def test_blocked_answers_are_excluded_from_dnsmap(self):
        dnsmap, _, _ = seed.build_indexes(LOG.split("\n"), LEASES)
        self.assertNotIn("0.0.0.0", dnsmap)

    def test_aaaa_answers_reach_dnsmap(self):
        dnsmap, _, _ = seed.build_indexes(LOG.split("\n"), LEASES)
        self.assertIn("six.example\t2606:4700::1111", self._pairs(dnsmap))

    def test_a_dual_stack_answer_records_both_families(self):
        rows = self._pairs(seed.build_indexes(LOG.split("\n"), LEASES)[0])
        self.assertIn("dual.example\t192.0.2.40", rows)
        self.assertIn("dual.example\t2606:4700::2222", rows)

    def test_the_blocked_ipv6_answer_is_excluded_from_dnsmap(self):
        # :: would otherwise become the "resolved name" of every blocked AAAA
        # in turn, and any peer at :: would come back explained.
        rows = self._pairs(seed.build_indexes(LOG.split("\n"), LEASES)[0])
        self.assertNotIn("bad6.example\t::", rows)

    def test_quad_a_is_not_double_counted_as_an_a_record(self):
        row = seed.parse_line(
            'INFO queryLog: query resolved answer=AAAA (2606:4700::1111) '
            'client_ip=198.51.100.5 question_name=six.example. '
            'response_type=RESOLVED')
        self.assertEqual(row["answers"], ["2606:4700::1111"])

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


class TestUnion(unittest.TestCase):
    """seed accumulates history rather than replacing it.

    journald rotates, so a run that only sees today's log entries must not
    forget a domain it learned about weeks ago just because the log line
    that first taught it has since aged out.
    """

    def _pairs(self, dnsmap):
        """Drop the last-seen timestamp column."""
        return ["\t".join(l.split("\t")[:2])
                for l in dnsmap.split("\n") if l]

    def test_dnsmap_keeps_an_address_missing_from_the_current_log(self):
        dnsmap, _, _ = seed.build_indexes(
            LOG.split("\n"), LEASES,
            existing_dnsmap="old.example\t198.51.100.200\n")
        rows = self._pairs(dnsmap)
        self.assertIn("old.example\t198.51.100.200", rows)
        # and still contains what this run itself resolved
        self.assertIn("example.com\t192.0.2.10", rows)

    def test_dnsmap_does_not_duplicate_a_pair_seen_both_times(self):
        dnsmap, _, _ = seed.build_indexes(
            LOG.split("\n"), LEASES,
            existing_dnsmap="example.com\t192.0.2.10\n")
        rows = self._pairs(dnsmap)
        self.assertEqual(rows.count("example.com\t192.0.2.10"), 1)

    def test_baseline_keeps_a_domain_missing_from_the_current_log(self):
        existing = "net\told.example\naa:bb:cc:dd:ee:01\told.example\n"
        _, _, baseline = seed.build_indexes(
            LOG.split("\n"), LEASES, existing_baseline=existing)
        rows = [l for l in baseline.split("\n") if l]
        self.assertIn("net\told.example", rows)
        self.assertIn("aa:bb:cc:dd:ee:01\told.example", rows)
        # and still contains what this run itself resolved
        self.assertIn("net\texample.com", rows)

    def test_baseline_does_not_duplicate_a_domain_seen_both_times(self):
        _, _, baseline = seed.build_indexes(
            LOG.split("\n"), LEASES, existing_baseline="net\texample.com\n")
        rows = [l for l in baseline.split("\n") if l]
        self.assertEqual(rows.count("net\texample.com"), 1)


class TestDnsmapExpiry(unittest.TestCase):
    NOW = 1_800_000_000
    OLD = NOW - 200 * 86400
    RECENT = NOW - 10 * 86400

    def test_drops_a_mapping_older_than_the_retention(self):
        dnsmap, _, _ = seed.build_indexes(
            [], LEASES,
            existing_dnsmap="stale.example\t192.0.2.90\t{}\n".format(self.OLD),
            now_ts=self.NOW)
        self.assertNotIn("stale.example", dnsmap)

    def test_keeps_a_mapping_inside_the_retention(self):
        dnsmap, _, _ = seed.build_indexes(
            [], LEASES,
            existing_dnsmap="live.example\t192.0.2.91\t{}\n".format(
                self.RECENT),
            now_ts=self.NOW)
        self.assertIn("live.example", dnsmap)

    def test_a_row_without_a_timestamp_is_kept_not_discarded(self):
        dnsmap, _, _ = seed.build_indexes(
            [], LEASES,
            existing_dnsmap="legacy.example\t192.0.2.92\n",
            now_ts=self.NOW)
        self.assertIn("legacy.example\t192.0.2.92\t{}".format(self.NOW),
                      dnsmap)

    def test_a_reassigned_address_resolves_to_its_current_owner(self):
        # Retained row first, freshly seen row after; analyse.read_dnsmap
        # takes the last, so the new owner wins.
        log = ['INFO queryLog: query resolved answer=A (192.0.2.10) '
               'client_ip=198.51.100.5 question_name=new.example. '
               'response_type=RESOLVED']
        dnsmap, _, _ = seed.build_indexes(
            log, LEASES,
            existing_dnsmap="old.example\t192.0.2.10\t{}\n".format(
                self.RECENT),
            now_ts=self.NOW)
        rows = [l for l in dnsmap.split("\n") if l]
        self.assertLess(rows.index("old.example\t192.0.2.10\t{}".format(
            self.RECENT)),
            rows.index("new.example\t192.0.2.10\t{}".format(self.NOW)))


class TestAtomicWrite(unittest.TestCase):
    def test_replaces_the_file_only_once_fully_written(self):
        import os
        import tempfile
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "f.tsv")
            with open(path, "w") as handle:
                handle.write("original\n")
            seed._write_atomic(path, "replacement")
            with open(path) as handle:
                self.assertEqual(handle.read(), "replacement\n")
            self.assertFalse(os.path.exists(path + ".tmp"))


if __name__ == "__main__":
    unittest.main()
