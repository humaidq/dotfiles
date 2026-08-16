package main

import (
	"net/netip"
	"strings"
	"testing"
)

// The case that prompted the whole change: Fastly's Dubai POP is registered in
// the US and physically in the UAE, and the page must report the second.
const geoFixture = `1.0.0.0	1.0.0.255	AU
8.8.8.0	8.8.8.255	US
203.0.113.0	203.0.113.255	NL
2a04:4e42:80::	2a04:4e42:80:ffff:ffff:ffff:ffff:ffff	AE
2606:4700::	2606:4700:ffff:ffff:ffff:ffff:ffff:ffff	US
`

func loadGeo(t *testing.T, body string) *GeoTable {
	t.Helper()
	table, err := LoadGeoTable(writeTSV(t, body))
	if err != nil {
		t.Fatalf("LoadGeoTable: %v", err)
	}
	return table
}

func TestGeoLookupBothFamilies(t *testing.T) {
	table := loadGeo(t, geoFixture)
	cases := []struct{ addr, want string }{
		{"1.0.0.5", "AU"},
		{"8.8.8.8", "US"},
		{"203.0.113.10", "NL"},
		{"2a04:4e42:80::158", "AE"},
		{"2606:4700::1111", "US"},
	}
	for _, tc := range cases {
		t.Run(tc.addr, func(t *testing.T) {
			got, ok := table.Lookup(netip.MustParseAddr(tc.addr))
			if !ok || got != tc.want {
				t.Fatalf("Lookup(%s) = %q, %v; want %q", tc.addr, got, ok, tc.want)
			}
		})
	}
}

func TestGeoLookupReportsUnplacedRatherThanGuessing(t *testing.T) {
	table := loadGeo(t, geoFixture)
	// Between two ranges, and outside every one. MaxMind not placing an
	// address is a real answer; inventing the nearest range's country would
	// be the same class of error as printing the registration.
	for _, addr := range []string{"9.9.9.9", "2001:db8::1", "1.0.1.0"} {
		if got, ok := table.Lookup(netip.MustParseAddr(addr)); ok {
			t.Fatalf("Lookup(%s) = %q, want no answer", addr, got)
		}
	}
}

func TestGeoLookupOnNilTable(t *testing.T) {
	// A router that has not fetched the database yet. The column stays empty;
	// nothing panics and nothing falls back to the registration.
	var table *GeoTable
	if got, ok := table.Lookup(netip.MustParseAddr("8.8.8.8")); ok || got != "" {
		t.Fatalf("nil table returned %q, %v", got, ok)
	}
}

func TestGeoLoadSkipsMalformedRows(t *testing.T) {
	table := loadGeo(t, strings.Join([]string{
		"not-an-address\t1.2.3.4\tXX",
		"1.2.3.0\tnot-an-address\tXX",
		"1.2.3.0\t1.2.3.255\tTOOLONG",
		"1.2.3.0\t1.2.3.255\t",
		"two\tfields",
		"8.8.8.0\t8.8.8.255\tUS",
	}, "\n")+"\n")
	got, ok := table.Lookup(netip.MustParseAddr("8.8.8.8"))
	if !ok || got != "US" {
		t.Fatalf("a good row beside malformed ones was lost: %q, %v", got, ok)
	}
	if _, ok := table.Lookup(netip.MustParseAddr("1.2.3.4")); ok {
		t.Fatal("a malformed row was loaded anyway")
	}
}

func TestGeoLoadSortsRegardlessOfInputOrder(t *testing.T) {
	// The converter emits sorted output; the loader must not depend on it,
	// because the binary search silently returns wrong answers on unsorted
	// input rather than failing.
	table := loadGeo(t, strings.Join([]string{
		"203.0.113.0\t203.0.113.255\tNL",
		"1.0.0.0\t1.0.0.255\tAU",
		"8.8.8.0\t8.8.8.255\tUS",
	}, "\n")+"\n")
	for addr, want := range map[string]string{
		"1.0.0.5": "AU", "8.8.8.8": "US", "203.0.113.10": "NL",
	} {
		if got, _ := table.Lookup(netip.MustParseAddr(addr)); got != want {
			t.Fatalf("Lookup(%s) = %q, want %q", addr, got, want)
		}
	}
}
