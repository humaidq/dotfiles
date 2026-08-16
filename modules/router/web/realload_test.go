package main

import (
	"net/netip"
	"os"
	"testing"
)

func TestRealConvertedTable(t *testing.T) {
	path := os.Getenv("GEO_FIXTURE")
	if path == "" {
		t.Skip("no fixture")
	}
	table, err := LoadGeoTable(path)
	if err != nil {
		t.Fatalf("load: %v", err)
	}
	t.Logf("loaded v4=%d v6=%d", len(table.v4), len(table.v6))
	for _, a := range []string{"8.8.8.8", "2a04:4e42:80::158", "217.164.183.46", "1.1.1.1"} {
		got, ok := table.Lookup(netip.MustParseAddr(a))
		t.Logf("  %-22s -> %q %v", a, got, ok)
	}
}
