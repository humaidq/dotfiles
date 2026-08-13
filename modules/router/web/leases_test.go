package main

import (
	"net/netip"
	"os"
	"path/filepath"
	"testing"
)

func writeLeases(t *testing.T, body string) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "dnsmasq.leases")
	if err := os.WriteFile(path, []byte(body), 0o600); err != nil {
		t.Fatalf("write fixture: %v", err)
	}
	return path
}

// Real dnsmasq lease format: expiry, MAC, address, hostname, client id.
const leaseFixture = `1786488539 72:01:04:a8:78:e7 192.168.0.20 device-b 01:72:01:04:a8:78:e7
1786488557 52:ff:a4:45:a1:7d 192.168.0.10 device-a 01:52:ff:a4:45:a1:7d
1786475781 4e:5c:cd:be:b9:6c 192.168.0.30 * 01:4e:5c:cd:be:b9:6c
1786486223 2e:8c:5f:34:ab:f3 203.0.113.10 offlan 01:2e:8c:5f:34:ab:f3
truncated line
1786486224 aa:bb:cc:dd:ee:ff not-an-address bad 01:aa:bb:cc:dd:ee:ff
`

func TestReadLeasesSortsAndFiltersToLAN(t *testing.T) {
	path := writeLeases(t, leaseFixture)
	got, err := readLeases(path, netip.MustParsePrefix("192.168.0.0/24"))
	if err != nil {
		t.Fatalf("readLeases: %v", err)
	}
	if len(got) != 3 {
		t.Fatalf("got %d leases, want 3: %+v", len(got), got)
	}
	want := []lease{
		{Addr: netip.MustParseAddr("192.168.0.10"), Name: "device-a", MAC: "52:ff:a4:45:a1:7d"},
		{Addr: netip.MustParseAddr("192.168.0.20"), Name: "device-b", MAC: "72:01:04:a8:78:e7"},
		{Addr: netip.MustParseAddr("192.168.0.30"), Name: "", MAC: "4e:5c:cd:be:b9:6c"},
	}
	for i, w := range want {
		if got[i] != w {
			t.Fatalf("lease %d = %+v, want %+v", i, got[i], w)
		}
	}
}

func TestReadLeasesDropsOffLANAndMalformed(t *testing.T) {
	path := writeLeases(t, leaseFixture)
	got, err := readLeases(path, netip.MustParsePrefix("192.168.0.0/24"))
	if err != nil {
		t.Fatalf("readLeases: %v", err)
	}
	for _, l := range got {
		if l.Addr.String() == "203.0.113.10" {
			t.Fatal("an address outside the LAN prefix was listed")
		}
		if l.Name == "bad" {
			t.Fatal("a line with an unparseable address was listed")
		}
	}
}

func TestReadLeasesLastEntryWinsPerAddress(t *testing.T) {
	path := writeLeases(t, `1 aa:bb:cc:dd:ee:01 192.168.0.10 old-name 01:aa
2 aa:bb:cc:dd:ee:01 192.168.0.10 new-name 01:aa
`)
	got, err := readLeases(path, netip.MustParsePrefix("192.168.0.0/24"))
	if err != nil {
		t.Fatalf("readLeases: %v", err)
	}
	if len(got) != 1 || got[0].Name != "new-name" {
		t.Fatalf("got %+v, want a single lease named new-name", got)
	}
}

func TestReadLeasesMissingFile(t *testing.T) {
	if _, err := readLeases(filepath.Join(t.TempDir(), "absent"), netip.MustParsePrefix("192.168.0.0/24")); err == nil {
		t.Fatal("a missing lease file returned no error")
	}
}

// The MAC is what identifies a device to the low-trust pool and to the sops
// secret, so it is worth its own assertion rather than only riding along in the
// struct comparison above: a lease line with no hostname must still yield one.
func TestReadLeasesCapturesMAC(t *testing.T) {
	path := writeLeases(t, leaseFixture)
	got, err := readLeases(path, netip.MustParsePrefix("192.168.0.0/24"))
	if err != nil {
		t.Fatalf("readLeases: %v", err)
	}
	macs := map[string]string{}
	for _, l := range got {
		macs[l.Addr.String()] = l.MAC
	}
	if macs["192.168.0.10"] != "52:ff:a4:45:a1:7d" {
		t.Errorf("MAC for 192.168.0.10 = %q, want 52:ff:a4:45:a1:7d", macs["192.168.0.10"])
	}
	if macs["192.168.0.30"] != "4e:5c:cd:be:b9:6c" {
		t.Errorf("nameless lease lost its MAC: got %q", macs["192.168.0.30"])
	}
}
