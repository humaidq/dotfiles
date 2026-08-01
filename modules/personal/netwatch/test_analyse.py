#!/usr/bin/env python3
import unittest
import analyse

FLOWS = "\n".join([
    # ts  ethsrc ethdst ipsrc ipdst proto tcpsp tcpdp udpsp udpdp len sni
    "1.0\taa:bb:cc:dd:ee:01\tff:ff:ff:ff:ff:ff\t198.51.100.5\t192.0.2.10\t6\t51000\t443\t\t\t400\texample.com",
    "1.1\tff:ff:ff:ff:ff:ff\taa:bb:cc:dd:ee:01\t192.0.2.10\t198.51.100.5\t6\t443\t51000\t\t\t200\t",
    "1.2\taa:bb:cc:dd:ee:01\tff:ff:ff:ff:ff:ff\t198.51.100.5\t192.0.2.20\t17\t\t\t51001\t4500\t400\t",
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
        self.assertEqual(top["bytes_out"], 400)
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


TUNNEL_FLOWS = "\n".join([
    "1.0\taa:bb:cc:dd:ee:01\tff:ff:ff:ff:ff:ff\t198.51.100.5\t192.0.2.99\t17\t\t\t51000\t4500\t9000\t",
    "1.1\tff:ff:ff:ff:ff:ff\taa:bb:cc:dd:ee:01\t192.0.2.99\t198.51.100.5\t17\t\t\t4500\t51000\t900\t",
    "1.2\taa:bb:cc:dd:ee:01\tff:ff:ff:ff:ff:ff\t198.51.100.5\t192.0.2.10\t6\t51001\t443\t\t\t100\t",
])


class TestCheckShape(unittest.TestCase):
    def _peers(self, text, mac="aa:bb:cc:dd:ee:01"):
        peers, total = analyse.aggregate_peers(analyse.parse_flows(text), mac)
        analyse.annotate_peers(peers, analyse.read_dnsmap(DNSMAP))
        return peers, total

    def test_flags_dominant_top_peer(self):
        peers, total = self._peers(TUNNEL_FLOWS)
        names = [o["check"] for o in analyse.check_shape(peers, total)]
        self.assertIn("top_peer_share", names)

    def test_does_not_flag_a_peer_below_the_dominance_threshold(self):
        # FLOWS splits 600/400: below TOP_PEER_SHARE, unlike a 70/30 split,
        # which is not a "balanced spread" and should already flag (see the
        # boundary test below).
        peers, total = self._peers(FLOWS)
        names = [o["check"] for o in analyse.check_shape(peers, total)]
        self.assertNotIn("top_peer_share", names)

    def test_flags_a_peer_at_exactly_the_threshold_share(self):
        # The check exists to catch a dominant peer, so a peer holding
        # exactly TOP_PEER_SHARE (70%) must flag, not just anything above it.
        peers = [
            {"ip": "192.0.2.10", "port": 443, "proto": "tcp",
             "bytes_out": 700, "bytes_in": 0, "packets": 1, "sni": "",
             "explained": True},
            {"ip": "192.0.2.20", "port": 443, "proto": "tcp",
             "bytes_out": 300, "bytes_in": 0, "packets": 1, "sni": "",
             "explained": True},
        ]
        names = [o["check"] for o in analyse.check_shape(peers, 1000)]
        self.assertIn("top_peer_share", names)

    def test_flags_ipsec_ports(self):
        peers, total = self._peers(TUNNEL_FLOWS)
        names = [o["check"] for o in analyse.check_shape(peers, total)]
        self.assertIn("vpn_port", names)

    def test_flags_unexplained_high_volume_peer(self):
        peers, total = self._peers(TUNNEL_FLOWS)
        names = [o["check"] for o in analyse.check_shape(peers, total)]
        self.assertIn("unexplained_peer", names)

    def test_empty_capture_produces_no_observations(self):
        self.assertEqual(analyse.check_shape([], 0), [])


IPV6_FLOWS = "\n".join([
    "1.0\taa:bb:cc:dd:ee:01\tff:ff:ff:ff:ff:ff\t\t\t\t\t\t\t\t150\t",
    "1.1\taa:bb:cc:dd:ee:01\tff:ff:ff:ff:ff:ff\t\t\t\t\t\t\t\t250\t",
    "1.2\taa:bb:cc:dd:ee:01\tff:ff:ff:ff:ff:ff\t198.51.100.5\t192.0.2.10"
    "\t6\t51000\t443\t\t\t400\texample.com",
])


class TestCountUnaddressed(unittest.TestCase):
    def test_counts_flows_with_no_ipv4_address(self):
        flows = analyse.parse_flows(IPV6_FLOWS)
        self.assertEqual(
            analyse.count_unaddressed(flows, "aa:bb:cc:dd:ee:01"), 2)

    def test_ignores_flows_for_other_devices(self):
        flows = analyse.parse_flows(IPV6_FLOWS)
        self.assertEqual(
            analyse.count_unaddressed(flows, "aa:bb:cc:dd:ee:99"), 0)

    def test_zero_when_every_flow_has_an_address(self):
        flows = analyse.parse_flows(FLOWS)
        self.assertEqual(
            analyse.count_unaddressed(flows, "aa:bb:cc:dd:ee:01"), 0)


class TestBuild(unittest.TestCase):
    def test_builds_one_entry_per_device_sorted_by_severity(self):
        result = analyse.build(
            TUNNEL_FLOWS, DNSMAP, QUERIES,
            {"aa:bb:cc:dd:ee:01": "phone-a"},
            analyse.read_baselines(BASELINES), 1754000000)
        self.assertTrue(result["captured"])
        self.assertEqual(result["run_ts"], 1754000000)
        self.assertEqual(len(result["devices"]), 1)
        device = result["devices"][0]
        self.assertEqual(device["label"], "phone-a")
        severities = [o["severity"] for o in device["observations"]]
        self.assertEqual(severities, sorted(severities, reverse=True))

    def test_device_with_no_traffic_still_appears(self):
        result = analyse.build(
            "", DNSMAP, QUERIES,
            {"aa:bb:cc:dd:ee:01": "phone-a"},
            analyse.read_baselines(BASELINES), 1754000000)
        self.assertEqual(result["devices"][0]["total_bytes"], 0)
        self.assertEqual(result["devices"][0]["peers"], [])

    def test_flags_ipv6_traffic_it_cannot_analyse(self):
        result = analyse.build(
            IPV6_FLOWS, DNSMAP, QUERIES,
            {"aa:bb:cc:dd:ee:01": "phone-a"},
            analyse.read_baselines(BASELINES), 1754000000)
        device = result["devices"][0]
        checks = {o["check"]: o for o in device["observations"]}
        self.assertIn("non_ipv4_not_analysed", checks)
        self.assertIn("2", checks["non_ipv4_not_analysed"]["detail"])

    def test_does_not_flag_ipv6_when_every_flow_is_addressed(self):
        result = analyse.build(
            FLOWS, DNSMAP, QUERIES,
            {"aa:bb:cc:dd:ee:01": "phone-a"},
            analyse.read_baselines(BASELINES), 1754000000)
        checks = [o["check"] for o in result["devices"][0]["observations"]]
        self.assertNotIn("non_ipv4_not_analysed", checks)


if __name__ == "__main__":
    unittest.main()
