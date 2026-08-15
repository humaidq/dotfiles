package main

import (
	"context"
	"html/template"
	"net/http"
	"net/http/httptest"
	"net/netip"
	"strings"
	"testing"
)

// One phone: a DHCP lease, a stable SLAAC address, a temporary one, and a
// link-local. The router has spoken to all four, so all four are neighbours.
const neighFixture = `192.168.0.10 dev enp2s0 lladdr aa:bb:cc:dd:ee:01 REACHABLE
2001:db8:1:0::a1 dev enp2s0 lladdr aa:bb:cc:dd:ee:01 STALE
2001:db8:1:0::7f3e dev enp2s0 lladdr aa:bb:cc:dd:ee:01 REACHABLE
fe80::a8bb:ccff:fedd:ee01 dev enp2s0 lladdr aa:bb:cc:dd:ee:01 REACHABLE
192.168.0.20 dev enp2s0 lladdr aa:bb:cc:dd:ee:02 REACHABLE
2001:db8:1:0::b2 dev enp2s0 lladdr aa:bb:cc:dd:ee:03 REACHABLE
192.168.0.77 dev enp2s0  FAILED
`

func TestParseNeighboursTakesBothFamiliesAndSkipsIncomplete(t *testing.T) {
	got := parseNeighbours([]byte(neighFixture))
	if len(got) != 6 {
		t.Fatalf("parsed %d entries, want 6 (the FAILED line has no lladdr)", len(got))
	}
	if got[0].MAC != "aa:bb:cc:dd:ee:01" {
		t.Fatalf("mac = %q", got[0].MAC)
	}
}

func TestAddressesForMACMergesTheFamilies(t *testing.T) {
	got := addressesForMAC([]byte(neighFixture), "AA:BB:CC:DD:EE:01")
	if len(got) != 4 {
		t.Fatalf("got %d addresses, want 4: %v", len(got), got)
	}
	set := newAddrSet(got...)
	for _, want := range []string{
		"192.168.0.10", "2001:db8:1:0::a1", "2001:db8:1:0::7f3e",
		"fe80::a8bb:ccff:fedd:ee01",
	} {
		if !set.has(netip.MustParseAddr(want)) {
			t.Fatalf("missing %s from %v", want, got)
		}
	}
	if addressesForMAC([]byte(neighFixture), "") != nil {
		t.Fatal("an empty MAC must match nothing")
	}
}

// The whole point: a device's IPv6 conversations land on its page.
func TestDevicePageMergesIPv6Peers(t *testing.T) {
	const flows = `ipv4     2 tcp      6 431998 ESTABLISHED src=192.168.0.10 dst=203.0.113.10 sport=1 dport=443 packets=10 bytes=4000 src=203.0.113.10 dst=198.51.100.1 sport=443 dport=1 packets=8 bytes=2000 [ASSURED] mark=0 use=1
ipv6     10 tcp      6 431998 ESTABLISHED src=2001:db8:1:0::7f3e dst=2606:4700::1111 sport=2 dport=443 packets=10 bytes=9000 src=2606:4700::1111 dst=2001:db8:1:0::7f3e sport=443 dport=2 packets=8 bytes=1000 [ASSURED] mark=0 use=1
ipv6     10 udp      17 100 src=2001:db8:1:0::a1 dst=2606:4700::2222 sport=3 dport=51820 packets=4 bytes=800 src=2606:4700::2222 dst=2001:db8:1:0::a1 sport=51820 dport=3 packets=4 bytes=700 [ASSURED] mark=0 use=1
`
	server := testPeersServer(t)
	server.conntrack = func(context.Context) ([]byte, error) { return []byte(flows), nil }
	server.neighbours = newNeighbourCache(func(context.Context) ([]byte, error) {
		return []byte(neighFixture), nil
	})
	var captured peersPageData
	server.tmpl = template.Must(template.New("peers.html").Funcs(template.FuncMap{
		"capture": func(d peersPageData) string { captured = d; return "" },
	}).Parse(`{{capture .}}`))

	rec := httptest.NewRecorder()
	server.mux().ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/peers/192.168.0.10", nil))
	if rec.Code != http.StatusOK {
		t.Fatalf("status %d", rec.Code)
	}

	byAddr := map[string]peerRow{}
	for _, row := range captured.Peers {
		byAddr[row.Addr] = row
	}
	for _, want := range []string{"203.0.113.10", "2606:4700::1111", "2606:4700::2222"} {
		if _, ok := byAddr[want]; !ok {
			t.Fatalf("peer %s missing; page has %v", want, byAddr)
		}
	}
	// Bytes are summed across both families, so the share column means the
	// same thing it always did.
	if got := byAddr["2606:4700::1111"].Bytes; got != "9.8 KiB" {
		t.Fatalf("v6 peer bytes = %q", got)
	}
	// The page says which addresses it merged, so a reader can tell a missing
	// row from one on an address they did not know about.
	if len(captured.AlsoAddrs) != 3 {
		t.Fatalf("AlsoAddrs = %v, want the three non-URL addresses", captured.AlsoAddrs)
	}
}

func TestDevicePageStillWorksWithNoNeighbourEntry(t *testing.T) {
	// A sleeping device: the kernel has evicted it, so the page falls back to
	// the IPv4 half rather than 404ing or emptying.
	server := testPeersServer(t)
	server.neighbours = newNeighbourCache(func(context.Context) ([]byte, error) {
		return []byte(""), nil
	})
	var captured peersPageData
	server.tmpl = template.Must(template.New("peers.html").Funcs(template.FuncMap{
		"capture": func(d peersPageData) string { captured = d; return "" },
	}).Parse(`{{capture .}}`))
	rec := httptest.NewRecorder()
	server.mux().ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/peers/192.168.0.10", nil))
	if rec.Code != http.StatusOK {
		t.Fatalf("status %d", rec.Code)
	}
	if len(captured.Peers) == 0 {
		t.Fatal("the IPv4 peers vanished with the neighbour table")
	}
	if captured.AlsoAddrs != nil {
		t.Fatalf("AlsoAddrs = %v, want none", captured.AlsoAddrs)
	}
}

// An IPv6-only device is reachable by URL, and an internet address still is
// not. That guard is the reason this page is not a way to ask what the LAN is
// doing with an arbitrary address.
func TestDeviceGuardAdmitsNeighboursAndNothingElse(t *testing.T) {
	server := testPeersServer(t)
	server.neighbours = newNeighbourCache(func(context.Context) ([]byte, error) {
		return []byte(neighFixture), nil
	})
	server.tmpl = template.Must(template.New("peers.html").Parse("ok"))

	cases := []struct {
		path string
		want int
	}{
		{"/peers/192.168.0.10", http.StatusOK},          // in the DHCP range
		{"/peers/2001:db8:1:0::b2", http.StatusOK},      // v6-only neighbour
		{"/peers/203.0.113.10", http.StatusNotFound},    // an internet address
		{"/peers/2606:4700::1111", http.StatusNotFound}, // an internet address, v6
		{"/peers/10.9.9.9", http.StatusNotFound},        // private, but not here
	}
	for _, tc := range cases {
		t.Run(tc.path, func(t *testing.T) {
			rec := httptest.NewRecorder()
			server.mux().ServeHTTP(rec, httptest.NewRequest(http.MethodGet, tc.path, nil))
			if rec.Code != tc.want {
				t.Fatalf("status = %d, want %d", rec.Code, tc.want)
			}
		})
	}
}

func TestIndexListsDevicesWithNoLease(t *testing.T) {
	server := testPeersServer(t)
	server.neighbours = newNeighbourCache(func(context.Context) ([]byte, error) {
		return []byte(neighFixture), nil
	})
	server.indexTmpl = template.Must(template.New("peers-index.html").Parse(
		`{{range .Leases}}{{.Addr}}/{{.MAC}};{{end}}`))
	rec := httptest.NewRecorder()
	server.mux().ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/peers", nil))
	body := rec.Body.String()

	// ...ee:03 holds only an IPv6 address and has no lease. Nothing hands out
	// an IPv6 address here, so no lease file could ever have listed it.
	if !strings.Contains(body, "2001:db8:1::b2/aa:bb:cc:dd:ee:03;") {
		t.Fatalf("lease-less IPv6 device missing: %q", body)
	}
	// The leased devices appear once each, not once per address.
	if got := strings.Count(body, "192.168.0.10/"); got != 1 {
		t.Fatalf("leased device appeared %d times: %q", got, body)
	}
	if strings.Contains(body, "2001:db8:1::a1/") {
		t.Fatalf("a leased device's v6 address became its own row: %q", body)
	}
}

func TestIndexDatesADeviceByItsBusiestFamily(t *testing.T) {
	// IPv4 has been quiet for days; IPv6 moved two seconds ago. The device is
	// awake, and dating the lease address alone said the opposite.
	const flows = `ipv4     2 tcp      6 200000 ESTABLISHED src=192.168.0.10 dst=203.0.113.10 sport=1 dport=443 packets=2 bytes=100 src=203.0.113.10 dst=198.51.100.1 sport=443 dport=1 packets=2 bytes=100 [ASSURED] mark=0 use=1
ipv6     10 tcp      6 431998 ESTABLISHED src=2001:db8:1:0::7f3e dst=2606:4700::1111 sport=2 dport=443 packets=2 bytes=100 src=2606:4700::1111 dst=2001:db8:1:0::7f3e sport=443 dport=2 packets=2 bytes=100 [ASSURED] mark=0 use=1
`
	server := testPeersServer(t)
	server.conntrack = func(context.Context) ([]byte, error) { return []byte(flows), nil }
	server.neighbours = newNeighbourCache(func(context.Context) ([]byte, error) {
		return []byte(neighFixture), nil
	})
	server.timeouts = fakeTimeouts(map[string]string{
		"nf_conntrack_tcp_timeout_established":    "432000",
		"nf_conntrack_tcp_timeout_unacknowledged": "300",
	}, nil)
	server.indexTmpl = template.Must(template.New("peers-index.html").Parse(
		`{{range .Leases}}{{.Addr}}={{.LastSeen}}/{{.Stale}};{{end}}`))
	rec := httptest.NewRecorder()
	server.mux().ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/peers", nil))
	if !strings.Contains(rec.Body.String(), "192.168.0.10=2s/false;") {
		t.Fatalf("device dated by its stale family: %q", rec.Body.String())
	}
}

func TestPickDeviceAddrIsStableAndPrefersARoutableAddress(t *testing.T) {
	ll := netip.MustParseAddr("fe80::a8bb:ccff:fedd:ee01")
	v6 := netip.MustParseAddr("2001:db8::5")
	v4 := netip.MustParseAddr("192.168.0.10")

	if got := pickDeviceAddr([]netip.Addr{ll, v6}); got != v6 {
		t.Fatalf("got %s, want the routable address", got)
	}
	if got := pickDeviceAddr([]netip.Addr{ll, v6, v4}); got != v4 {
		t.Fatalf("got %s, want the IPv4 address", got)
	}
	if got := pickDeviceAddr([]netip.Addr{ll}); got != ll {
		t.Fatalf("got %s, want the only address there is", got)
	}
	// Same inputs in a different order must give the same answer, or the link
	// moves between renders.
	a := pickDeviceAddr([]netip.Addr{netip.MustParseAddr("2001:db8::9"), v6})
	b := pickDeviceAddr([]netip.Addr{v6, netip.MustParseAddr("2001:db8::9")})
	if a != b {
		t.Fatalf("unstable: %s vs %s", a, b)
	}
}
