#!/usr/bin/env python3
import unittest

import certcheck

REAL = {"subject": "CN=example.com", "issuer": "C=US, O=Example CA",
        "serial": "0A1B2C3D4E5F60718293A4B5C6D7E8F9",
        "not_before": "2026-01-01", "not_after": "2026-12-01"}

FORGED = {"subject": "CN=*.example.net", "issuer": "C=US, O=Example CA",
          "serial": "1003",
          "not_before": "2016-03-14", "not_after": "2031-03-14"}

SELF_SIGNED = {"subject": "CN=example.org", "issuer": "CN=example.org",
               "serial": "0A1B2C3D4E5F6071", "not_before": "2026-01-01",
               "not_after": "2026-06-01"}


class TestSuspicious(unittest.TestCase):
    def test_ordinary_certificate_is_not_flagged(self):
        self.assertEqual(certcheck.suspicious(REAL), [])

    def test_flags_absurd_validity_span(self):
        self.assertIn("validity span 15.0 years", certcheck.suspicious(FORGED))

    def test_flags_short_serial(self):
        self.assertIn("serial 1003 is too short for a public CA",
                      certcheck.suspicious(FORGED))

    def test_flags_self_signed(self):
        self.assertIn("issuer equals subject",
                      certcheck.suspicious(SELF_SIGNED))


class TestTargets(unittest.TestCase):
    def test_selects_only_unexplained_peers(self):
        obs = {"devices": [{"peers": [
            {"ip": "192.0.2.10", "port": 443, "explained": True,
             "bytes_out": 999999, "bytes_in": 0},
            {"ip": "192.0.2.99", "port": 443, "explained": False,
             "bytes_out": 999999, "bytes_in": 0},
        ]}]}
        self.assertEqual(certcheck.targets(obs), [("192.0.2.99", 443)])

    def test_ignores_trivial_volume(self):
        obs = {"devices": [{"peers": [
            {"ip": "192.0.2.99", "port": 443, "explained": False,
             "bytes_out": 10, "bytes_in": 0},
        ]}]}
        self.assertEqual(certcheck.targets(obs), [])

    def test_deduplicates_across_devices(self):
        peer = {"ip": "192.0.2.99", "port": 443, "explained": False,
                "bytes_out": 999999, "bytes_in": 0}
        obs = {"devices": [{"peers": [peer]}, {"peers": [peer]}]}
        self.assertEqual(certcheck.targets(obs), [("192.0.2.99", 443)])


if __name__ == "__main__":
    unittest.main()
