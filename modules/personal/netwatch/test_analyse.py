#!/usr/bin/env python3
import unittest
import analyse

FLOWS = "\n".join([
    # ts  ethsrc ethdst ipsrc ipdst proto tcpsp tcpdp udpsp udpdp len sni
    "1.0\taa:bb:cc:dd:ee:01\tff:ff:ff:ff:ff:ff\t198.51.100.5\t192.0.2.10\t6\t51000\t443\t\t\t500\texample.com",
    "1.1\tff:ff:ff:ff:ff:ff\taa:bb:cc:dd:ee:01\t192.0.2.10\t198.51.100.5\t6\t443\t51000\t\t\t200\t",
    "1.2\taa:bb:cc:dd:ee:01\tff:ff:ff:ff:ff:ff\t198.51.100.5\t192.0.2.20\t17\t\t\t51001\t4500\t300\t",
])


class TestParseFlows(unittest.TestCase):
    def test_parses_tcp_row_with_sni(self):
        rows = analyse.parse_flows(FLOWS)
        self.assertEqual(len(rows), 3)
        self.assertEqual(rows[0]["ip_dst"], "192.0.2.10")
        self.assertEqual(rows[0]["dport"], 443)
        self.assertEqual(rows[0]["proto"], "tcp")
        self.assertEqual(rows[0]["sni"], "example.com")

    def test_parses_udp_ports_from_udp_columns(self):
        rows = analyse.parse_flows(FLOWS)
        self.assertEqual(rows[2]["proto"], "udp")
        self.assertEqual(rows[2]["dport"], 4500)

    def test_skips_blank_and_malformed_lines(self):
        rows = analyse.parse_flows("\n\nnot\tenough\tcolumns\n" + FLOWS)
        self.assertEqual(len(rows), 3)


class TestAggregatePeers(unittest.TestCase):
    def test_splits_direction_and_sums_bytes(self):
        peers, total = analyse.aggregate_peers(
            analyse.parse_flows(FLOWS), "aa:bb:cc:dd:ee:01")
        self.assertEqual(total, 1000)
        top = peers[0]
        self.assertEqual(top["ip"], "192.0.2.10")
        self.assertEqual(top["bytes_out"], 500)
        self.assertEqual(top["bytes_in"], 200)
        self.assertEqual(top["packets"], 2)

    def test_sorted_by_total_bytes_descending(self):
        peers, _ = analyse.aggregate_peers(
            analyse.parse_flows(FLOWS), "aa:bb:cc:dd:ee:01")
        self.assertEqual([p["ip"] for p in peers],
                         ["192.0.2.10", "192.0.2.20"])

    def test_carries_sni_onto_the_peer(self):
        peers, _ = analyse.aggregate_peers(
            analyse.parse_flows(FLOWS), "aa:bb:cc:dd:ee:01")
        self.assertEqual(peers[0]["sni"], "example.com")

    def test_ignores_flows_for_other_devices(self):
        peers, total = analyse.aggregate_peers(
            analyse.parse_flows(FLOWS), "aa:bb:cc:dd:ee:99")
        self.assertEqual(peers, [])
        self.assertEqual(total, 0)


class TestReadDevices(unittest.TestCase):
    def test_reads_pairs_and_ignores_comments(self):
        import tempfile, os
        with tempfile.TemporaryDirectory() as d:
            p = os.path.join(d, "devices.conf")
            with open(p, "w") as f:
                f.write("# a comment\n\nAA:BB:CC:DD:EE:01  phone-a\n")
            self.assertEqual(analyse.read_devices(p),
                             {"aa:bb:cc:dd:ee:01": "phone-a"})


DNSMAP = "example.com\t192.0.2.10\nother.example\t192.0.2.30\n"

QUERIES = "\n".join([
    "aa:bb:cc:dd:ee:01\texample.com\tRESOLVED",
    "aa:bb:cc:dd:ee:01\texample.com\tCACHED",
    "aa:bb:cc:dd:ee:01\tfresh.example\tRESOLVED",
    "aa:bb:cc:dd:ee:01\tbad.example\tBLOCKED",
    "aa:bb:cc:dd:ee:02\tother.example\tRESOLVED",
])


class TestDnsCorrelation(unittest.TestCase):
    def test_marks_peer_explained_when_a_lookup_exists(self):
        peers, _ = analyse.aggregate_peers(
            analyse.parse_flows(FLOWS), "aa:bb:cc:dd:ee:01")
        analyse.annotate_peers(peers, analyse.read_dnsmap(DNSMAP))
        self.assertTrue(peers[0]["explained"])
        self.assertEqual(peers[0]["resolved_name"], "example.com")

    def test_marks_peer_unexplained_when_no_lookup_exists(self):
        peers, _ = analyse.aggregate_peers(
            analyse.parse_flows(FLOWS), "aa:bb:cc:dd:ee:01")
        analyse.annotate_peers(peers, analyse.read_dnsmap(DNSMAP))
        unexplained = [p for p in peers if not p["explained"]]
        self.assertEqual([p["ip"] for p in unexplained], ["192.0.2.20"])


BASELINES = "\n".join([
    "net\texample.com",
    "net\tother.example",
    "aa:bb:cc:dd:ee:01\texample.com",
])


class TestNovelty(unittest.TestCase):
    def _run(self, text=BASELINES):
        return analyse.novelty(analyse.read_queries(QUERIES),
                               "aa:bb:cc:dd:ee:01",
                               analyse.read_baselines(text))

    def test_read_baselines_groups_by_scope(self):
        parsed = analyse.read_baselines(BASELINES)
        self.assertEqual(parsed["net"], {"example.com", "other.example"})
        self.assertEqual(parsed["aa:bb:cc:dd:ee:01"], {"example.com"})

    def test_new_for_device_uses_the_device_scope(self):
        self.assertEqual(self._run()["new_for_device"], ["fresh.example"])

    def test_a_domain_new_to_this_device_but_known_to_the_network_is_not_network_new(self):
        text = BASELINES + "\nnet\tfresh.example"
        result = self._run(text)
        self.assertEqual(result["new_for_device"], ["fresh.example"])
        self.assertEqual(result["new_for_network"], [])

    def test_new_for_network_uses_the_net_scope(self):
        self.assertEqual(self._run()["new_for_network"], ["fresh.example"])

    def test_blocked_answers_are_counted_not_listed(self):
        result = self._run()
        self.assertEqual(result["blocked_count"], 1)
        self.assertNotIn("bad.example", result["new_for_device"])

    def test_top_resolved_ranks_by_query_count(self):
        self.assertEqual(self._run()["top_resolved"][0], ("example.com", 2))


if __name__ == "__main__":
    unittest.main()
