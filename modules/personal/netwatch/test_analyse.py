#!/usr/bin/env python3
import unittest
import analyse

# The columns netwatch.bash asks tshark for, in order. Fifteen tab-separated
# fields are unreadable written out literally — and a fixture whose meaning
# depends on counting empty tabs is a fixture that will be edited wrongly — so
# rows are built by name here and only the fields that matter are given.
COLUMNS = [
    "ts", "eth_src", "eth_dst",
    "ip_src", "ip_dst", "ip_proto",
    "ipv6_src", "ipv6_dst", "ipv6_nxt",
    "tcp_sport", "tcp_dport", "udp_sport", "udp_dport",
    "length", "sni",
]

PHONE = "aa:bb:cc:dd:ee:01"
GATEWAY = "ff:ff:ff:ff:ff:ff"


def flow(**fields):
    unknown = set(fields) - set(COLUMNS)
    assert not unknown, "not a tshark column: {}".format(sorted(unknown))
    return "\t".join(str(fields.get(name, "")) for name in COLUMNS)


FLOWS = "\n".join([
    flow(ts="1.0", eth_src=PHONE, eth_dst=GATEWAY,
         ip_src="198.51.100.5", ip_dst="192.0.2.10", ip_proto="6",
         tcp_sport="51000", tcp_dport="443", length="400",
         sni="example.com"),
    flow(ts="1.1", eth_src=GATEWAY, eth_dst=PHONE,
         ip_src="192.0.2.10", ip_dst="198.51.100.5", ip_proto="6",
         tcp_sport="443", tcp_dport="51000", length="200"),
    flow(ts="1.2", eth_src=PHONE, eth_dst=GATEWAY,
         ip_src="198.51.100.5", ip_dst="192.0.2.20", ip_proto="17",
         udp_sport="51001", udp_dport="4500", length="400"),
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


class TestParseFlowsIPv6(unittest.TestCase):
    def test_reads_addresses_from_the_ipv6_columns(self):
        row = analyse.parse_flows(flow(
            ts="1.0", eth_src=PHONE, eth_dst=GATEWAY,
            ipv6_src="2001:db8::5", ipv6_dst="2606:4700::1111",
            ipv6_nxt="6", tcp_sport="51000", tcp_dport="443",
            length="400", sni="example.com"))[0]
        self.assertEqual(row["ip_src"], "2001:db8::5")
        self.assertEqual(row["ip_dst"], "2606:4700::1111")
        self.assertEqual(row["proto"], "tcp")
        self.assertEqual(row["dport"], 443)
        self.assertEqual(row["sni"], "example.com")

    def test_ipv6_next_header_chain_resolves_to_the_transport(self):
        # "0,6" is TCP behind a hop-by-hop header, not protocol 0.
        row = analyse.parse_flows(flow(
            ts="1.0", eth_src=PHONE, eth_dst=GATEWAY,
            ipv6_src="2001:db8::5", ipv6_dst="2606:4700::1111",
            ipv6_nxt="0,6", tcp_sport="51000", tcp_dport="443",
            length="400"))[0]
        self.assertEqual(row["proto"], "tcp")

    def test_esp_over_ipv6_is_reported_as_the_tunnel_protocol(self):
        # 50 is in TUNNEL_PROTOS, so it must survive as the protocol rather
        # than be skipped past like a plain extension header.
        row = analyse.parse_flows(flow(
            ts="1.0", eth_src=PHONE, eth_dst=GATEWAY,
            ipv6_src="2001:db8::5", ipv6_dst="2606:4700::1111",
            ipv6_nxt="50", length="900"))[0]
        self.assertEqual(row["proto"], "50")

    def test_ah_is_not_skipped_as_an_extension_header(self):
        row = analyse.parse_flows(flow(
            ts="1.0", eth_src=PHONE, eth_dst=GATEWAY,
            ipv6_src="2001:db8::5", ipv6_dst="2606:4700::1111",
            ipv6_nxt="51,6", tcp_sport="51000", tcp_dport="443",
            length="900"))[0]
        self.assertEqual(row["proto"], "51")

    def test_icmp_error_keeps_the_outer_addresses(self):
        # tshark repeats ip.src/ip.dst for the quoted packet inside an ICMP
        # error. The outer pair is the conversation; the inner one belongs to
        # a flow counted elsewhere.
        row = analyse.parse_flows(flow(
            ts="1.0", eth_src=GATEWAY, eth_dst=PHONE,
            ip_src="192.0.2.10,198.51.100.5", ip_dst="198.51.100.5,192.0.2.10",
            ip_proto="1,6", length="70"))[0]
        self.assertEqual(row["ip_src"], "192.0.2.10")
        self.assertEqual(row["ip_dst"], "198.51.100.5")
        self.assertEqual(row["proto"], "1")


IPV6_FLOWS = "\n".join([
    flow(ts="1.0", eth_src=PHONE, eth_dst=GATEWAY,
         ipv6_src="2001:db8::5", ipv6_dst="2606:4700::1111", ipv6_nxt="6",
         tcp_sport="51000", tcp_dport="443", length="400",
         sni="example.com"),
    flow(ts="1.1", eth_src=GATEWAY, eth_dst=PHONE,
         ipv6_src="2606:4700::1111", ipv6_dst="2001:db8::5", ipv6_nxt="6",
         tcp_sport="443", tcp_dport="51000", length="200"),
])


class TestAggregatePeers(unittest.TestCase):
    def test_splits_direction_and_sums_bytes(self):
        peers, total = analyse.aggregate_peers(
            analyse.parse_flows(FLOWS), PHONE)
        self.assertEqual(total, 1000)
        top = peers[0]
        self.assertEqual(top["ip"], "192.0.2.10")
        self.assertEqual(top["bytes_out"], 400)
        self.assertEqual(top["bytes_in"], 200)
        self.assertEqual(top["packets"], 2)

    def test_sorted_by_total_bytes_descending(self):
        peers, _ = analyse.aggregate_peers(
            analyse.parse_flows(FLOWS), PHONE)
        self.assertEqual([p["ip"] for p in peers],
                         ["192.0.2.10", "192.0.2.20"])

    def test_carries_sni_onto_the_peer(self):
        peers, _ = analyse.aggregate_peers(
            analyse.parse_flows(FLOWS), PHONE)
        self.assertEqual(peers[0]["sni"], "example.com")

    def test_ignores_flows_for_other_devices(self):
        peers, total = analyse.aggregate_peers(
            analyse.parse_flows(FLOWS), "aa:bb:cc:dd:ee:99")
        self.assertEqual(peers, [])
        self.assertEqual(total, 0)

    def test_ipv6_peers_aggregate_like_any_other(self):
        peers, total = analyse.aggregate_peers(
            analyse.parse_flows(IPV6_FLOWS), PHONE)
        self.assertEqual(total, 600)
        self.assertEqual(len(peers), 1)
        self.assertEqual(peers[0]["ip"], "2606:4700::1111")
        self.assertEqual(peers[0]["port"], 443)
        self.assertEqual(peers[0]["bytes_out"], 400)
        self.assertEqual(peers[0]["bytes_in"], 200)


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
            analyse.parse_flows(FLOWS), PHONE)
        analyse.annotate_peers(peers, analyse.read_dnsmap(DNSMAP))
        self.assertTrue(peers[0]["explained"])
        self.assertEqual(peers[0]["resolved_name"], "example.com")

    def test_marks_peer_unexplained_when_no_lookup_exists(self):
        peers, _ = analyse.aggregate_peers(
            analyse.parse_flows(FLOWS), PHONE)
        analyse.annotate_peers(peers, analyse.read_dnsmap(DNSMAP))
        unexplained = [p for p in peers if not p["explained"]]
        self.assertEqual([p["ip"] for p in unexplained], ["192.0.2.20"])

    def test_an_ipv6_peer_is_explained_by_an_aaaa_lookup(self):
        # seed.py records AAAA answers into dnsmap; nothing here has to know
        # the family, because the address text is the key either way.
        peers, _ = analyse.aggregate_peers(
            analyse.parse_flows(IPV6_FLOWS), PHONE)
        analyse.annotate_peers(
            peers, analyse.read_dnsmap("example.com\t2606:4700::1111\n"))
        self.assertTrue(peers[0]["explained"])
        self.assertEqual(peers[0]["resolved_name"], "example.com")


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
    flow(ts="1.0", eth_src=PHONE, eth_dst=GATEWAY,
         ip_src="198.51.100.5", ip_dst="192.0.2.99", ip_proto="17",
         udp_sport="51000", udp_dport="4500", length="9000"),
    flow(ts="1.1", eth_src=GATEWAY, eth_dst=PHONE,
         ip_src="192.0.2.99", ip_dst="198.51.100.5", ip_proto="17",
         udp_sport="4500", udp_dport="51000", length="900"),
    flow(ts="1.2", eth_src=PHONE, eth_dst=GATEWAY,
         ip_src="198.51.100.5", ip_dst="192.0.2.10", ip_proto="6",
         tcp_sport="51001", tcp_dport="443", length="100"),
])


class TestCheckShape(unittest.TestCase):
    def _peers(self, text, mac=PHONE):
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

    def test_flags_a_wireguard_peer_reached_over_ipv6(self):
        # The point of parsing v6 at all: a tunnel that used to be invisible
        # because its addresses were in columns nothing read.
        peers, total = self._peers("\n".join([
            flow(ts="1.0", eth_src=PHONE, eth_dst=GATEWAY,
                 ipv6_src="2001:db8::5", ipv6_dst="2001:db8:bad::1",
                 ipv6_nxt="17", udp_sport="51000", udp_dport="51820",
                 length="9000"),
        ]))
        names = [o["check"] for o in analyse.check_shape(peers, total)]
        self.assertIn("vpn_port", names)

    def test_flags_unexplained_high_volume_peer(self):
        peers, total = self._peers(TUNNEL_FLOWS)
        names = [o["check"] for o in analyse.check_shape(peers, total)]
        self.assertIn("unexplained_peer", names)

    def test_empty_capture_produces_no_observations(self):
        self.assertEqual(analyse.check_shape([], 0), [])


# ARP and the like: no address in either family, so nothing to aggregate.
NON_IP_FLOWS = "\n".join([
    flow(ts="1.0", eth_src=PHONE, eth_dst=GATEWAY, length="150"),
    flow(ts="1.1", eth_src=PHONE, eth_dst=GATEWAY, length="250"),
    flow(ts="1.2", eth_src=PHONE, eth_dst=GATEWAY,
         ip_src="198.51.100.5", ip_dst="192.0.2.10", ip_proto="6",
         tcp_sport="51000", tcp_dport="443", length="400",
         sni="example.com"),
])


class TestCountUnaddressed(unittest.TestCase):
    def test_counts_frames_with_no_address_in_either_family(self):
        flows = analyse.parse_flows(NON_IP_FLOWS)
        self.assertEqual(analyse.count_unaddressed(flows, PHONE), 2)

    def test_ignores_flows_for_other_devices(self):
        flows = analyse.parse_flows(NON_IP_FLOWS)
        self.assertEqual(
            analyse.count_unaddressed(flows, "aa:bb:cc:dd:ee:99"), 0)

    def test_zero_when_every_flow_has_an_address(self):
        flows = analyse.parse_flows(FLOWS)
        self.assertEqual(analyse.count_unaddressed(flows, PHONE), 0)

    def test_ipv6_flows_no_longer_count_as_unaddressed(self):
        flows = analyse.parse_flows(IPV6_FLOWS)
        self.assertEqual(analyse.count_unaddressed(flows, PHONE), 0)


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

    def test_flags_layer2_traffic_it_cannot_analyse(self):
        result = analyse.build(
            NON_IP_FLOWS, DNSMAP, QUERIES,
            {"aa:bb:cc:dd:ee:01": "phone-a"},
            analyse.read_baselines(BASELINES), 1754000000)
        device = result["devices"][0]
        checks = {o["check"]: o for o in device["observations"]}
        self.assertIn("non_ip_not_analysed", checks)
        self.assertIn("2", checks["non_ip_not_analysed"]["detail"])

    def test_does_not_flag_when_every_flow_is_addressed(self):
        result = analyse.build(
            FLOWS, DNSMAP, QUERIES,
            {"aa:bb:cc:dd:ee:01": "phone-a"},
            analyse.read_baselines(BASELINES), 1754000000)
        checks = [o["check"] for o in result["devices"][0]["observations"]]
        self.assertNotIn("non_ip_not_analysed", checks)

    def test_ipv6_traffic_reaches_the_report_as_peers(self):
        result = analyse.build(
            IPV6_FLOWS, DNSMAP, QUERIES,
            {"aa:bb:cc:dd:ee:01": "phone-a"},
            analyse.read_baselines(BASELINES), 1754000000)
        device = result["devices"][0]
        self.assertEqual(device["total_bytes"], 600)
        self.assertEqual([p["ip"] for p in device["peers"]],
                         ["2606:4700::1111"])


if __name__ == "__main__":
    unittest.main()
