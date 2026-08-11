package main

import (
	"net/netip"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func writeTSV(t *testing.T, body string) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "ip2asn.tsv")
	if err := os.WriteFile(path, []byte(body), 0o600); err != nil {
		t.Fatalf("write fixture: %v", err)
	}
	return path
}

func TestASNLookup(t *testing.T) {
	path := writeTSV(t, strings.Join([]string{
		"203.0.113.0\t203.0.113.255\t64496\tNL\tExample Hosting",
		"198.51.100.0\t198.51.100.127\t64497\tDE\tOther Hosting",
		"2001:db8::\t2001:db8::ffff\t64498\tFR\tExample Six",
		"",
	}, "\n"))

	table, err := LoadASNTable(path)
	if err != nil {
		t.Fatalf("LoadASNTable: %v", err)
	}

	cases := []struct {
		name  string
		addr  string
		want  ASNInfo
		found bool
	}{
		{"first address in range", "203.0.113.0", ASNInfo{64496, "Example Hosting", "NL"}, true},
		{"last address in range", "203.0.113.255", ASNInfo{64496, "Example Hosting", "NL"}, true},
		{"middle of range", "203.0.113.10", ASNInfo{64496, "Example Hosting", "NL"}, true},
		{"second range", "198.51.100.5", ASNInfo{64497, "Other Hosting", "DE"}, true},
		{"just past a range", "198.51.100.128", ASNInfo{}, false},
		{"unmatched", "192.0.2.1", ASNInfo{}, false},
		{"ipv6 in range", "2001:db8::1", ASNInfo{64498, "Example Six", "FR"}, true},
		{"ipv6 unmatched", "2001:db9::1", ASNInfo{}, false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got, ok := table.Lookup(netip.MustParseAddr(tc.addr))
			if ok != tc.found {
				t.Fatalf("found = %v, want %v", ok, tc.found)
			}
			if ok && got != tc.want {
				t.Fatalf("got %+v, want %+v", got, tc.want)
			}
		})
	}
}

func TestASNNilTableIsSafe(t *testing.T) {
	var table *ASNTable
	if _, ok := table.Lookup(netip.MustParseAddr("203.0.113.1")); ok {
		t.Fatal("nil table returned a result")
	}
}

func TestASNSkipsMalformedRows(t *testing.T) {
	path := writeTSV(t, strings.Join([]string{
		"not-an-address\t203.0.113.255\t64496\tNL\tBroken",
		"203.0.113.0\t203.0.113.255\t64496\tNL\tExample Hosting",
		"too\tfew\tcolumns",
		"",
	}, "\n"))
	table, err := LoadASNTable(path)
	if err != nil {
		t.Fatalf("LoadASNTable: %v", err)
	}
	if _, ok := table.Lookup(netip.MustParseAddr("203.0.113.1")); !ok {
		t.Fatal("good row was not loaded alongside malformed ones")
	}
}
