package main

import (
	"net/netip"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func writeReservations(t *testing.T, body string) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "dhcp-hosts")
	if err := os.WriteFile(path, []byte(body), 0o600); err != nil {
		t.Fatalf("write fixture: %v", err)
	}
	return path
}

// The real shape of the file on the routers: MAC, address, name, lease time.
const reservationFixture = `72:16:2b:79:40:ff,192.168.0.40,device-d,infinite
d8:38:0d:22:99:d0,192.168.0.50,ap-first-floor,infinite
`

func TestReservationsAreFoundByMAC(t *testing.T) {
	got := newReservationFile(writeReservations(t, reservationFixture)).load()
	if name := got.name("72:16:2b:79:40:ff", netip.Addr{}); name != "device-d" {
		t.Fatalf("name = %q, want device-d", name)
	}
}

func TestReservationsMatchTheMACCaseInsensitively(t *testing.T) {
	got := parseReservations(strings.NewReader("D8:38:0D:22:99:D0,192.168.0.50,ap-first-floor,infinite\n"))
	if name := got.name("d8:38:0d:22:99:d0", netip.Addr{}); name != "ap-first-floor" {
		t.Fatalf("name = %q, want ap-first-floor", name)
	}
}

// A known MAC that no reservation names must not pick up the name of whichever
// reservation pins the address it currently holds — see reservations.name.
func TestReservationsDoNotNameTheWrongDeviceByAddress(t *testing.T) {
	got := parseReservations(strings.NewReader(reservationFixture))
	if name := got.name("aa:bb:cc:dd:ee:ff", netip.MustParseAddr("192.168.0.40")); name != "" {
		t.Fatalf("name = %q, want empty: the address is reserved for a different MAC", name)
	}
}

// With no MAC anywhere the address is all there is, so it is used.
func TestReservationsFallBackToTheAddressWithNoMAC(t *testing.T) {
	got := parseReservations(strings.NewReader(reservationFixture))
	if name := got.name("", netip.MustParseAddr("192.168.0.40")); name != "device-d" {
		t.Fatalf("name = %q, want device-d", name)
	}
}

func TestReservationsParseTheFullOptionalSyntax(t *testing.T) {
	got := parseReservations(strings.NewReader(
		"# a comment\n" +
			"\n" +
			"id:*,set:kids,aa:bb:cc:dd:ee:01,tag:known,192.168.0.11,tablet,45m\n" +
			"aa:bb:cc:dd:ee:02,aa:bb:cc:dd:ee:03,laptop\n" +
			"aa:bb:cc:dd:ee:04,[2001:db8::1],phone-v6,infinite\n"))

	for _, want := range []struct {
		mac  string
		name string
	}{
		{"aa:bb:cc:dd:ee:01", "tablet"},
		// Two MACs on one line means "either", so both carry the name.
		{"aa:bb:cc:dd:ee:02", "laptop"},
		{"aa:bb:cc:dd:ee:03", "laptop"},
		{"aa:bb:cc:dd:ee:04", "phone-v6"},
	} {
		if name := got.name(want.mac, netip.Addr{}); name != want.name {
			t.Errorf("name(%s) = %q, want %q", want.mac, name, want.name)
		}
	}
	if entry, ok := got.byAddr[netip.MustParseAddr("2001:db8::1")]; !ok || entry.Name != "phone-v6" {
		t.Errorf("bracketed IPv6 address not indexed: %+v", got.byAddr)
	}
}

// A lease time in the last field is not a hostname, and neither is `ignore`.
func TestReservationsDoNotMistakeALeaseTimeForAName(t *testing.T) {
	got := parseReservations(strings.NewReader(
		"aa:bb:cc:dd:ee:05,192.168.0.12,12h\n" +
			"aa:bb:cc:dd:ee:06,ignore\n"))
	if name := got.name("aa:bb:cc:dd:ee:05", netip.Addr{}); name != "" {
		t.Errorf("name = %q, want empty: 12h is a lease time", name)
	}
	if name := got.name("aa:bb:cc:dd:ee:06", netip.Addr{}); name != "" {
		t.Errorf("name = %q, want empty: ignore is a keyword", name)
	}
}

// A wildcard MAC names a class of device, not a device — see isMACAddr.
func TestReservationsSkipWildcardMACs(t *testing.T) {
	got := parseReservations(strings.NewReader("11:22:33:*:*:*,vendor-thing\n"))
	if len(got.byMAC) != 0 {
		t.Fatalf("byMAC = %+v, want empty", got.byMAC)
	}
}

// An unreadable file is the failure that actually happens — the real file is a
// sops secret — and it must cost a name and nothing else.
func TestReservationsSurviveAnUnreadableFile(t *testing.T) {
	got := newReservationFile(filepath.Join(t.TempDir(), "does-not-exist")).load()
	if name := got.name("72:16:2b:79:40:ff", netip.MustParseAddr("192.168.0.40")); name != "" {
		t.Fatalf("name = %q, want empty", name)
	}
}

func TestReservationFileIsNilWithoutAPath(t *testing.T) {
	if file := newReservationFile("  "); file != nil {
		t.Fatalf("newReservationFile(blank) = %+v, want nil", file)
	}
	// The nil receiver is the configured-off case and must be usable.
	var file *reservationFile
	if name := file.load().name("72:16:2b:79:40:ff", netip.Addr{}); name != "" {
		t.Fatalf("name = %q, want empty", name)
	}
}
