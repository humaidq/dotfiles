package main

import (
	"context"
	"encoding/json"
	"fmt"
	"html/template"
	"net"
	"net/http"
	"net/http/httptest"
	"net/netip"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

// A peers server whose template renders the reverse-DNS parts of a row, and
// whose resolver is a stub. testPeersServer's template does not carry the
// column, so these tests bring their own rather than widening a fixture eleven
// other tests assert against.
func testRDNSServer(t *testing.T, lookup func(context.Context, netip.Addr) ([]string, error)) *peersServer {
	t.Helper()
	server := testPeersServer(t)
	tmpl, err := template.New("peers.html").Parse(
		`{{range .Peers}}{{.Addr}}[{{.RDNS}}|{{.RDNSKnown}}];{{end}}`)
	if err != nil {
		t.Fatalf("parse template: %v", err)
	}
	server.tmpl = tmpl
	server.rdns.lookup = lookup
	return server
}

func renderPeers(t *testing.T, server *peersServer) string {
	t.Helper()
	rec := httptest.NewRecorder()
	server.mux().ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/peers/192.168.0.10", nil))
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200", rec.Code)
	}
	return rec.Body.String()
}

// The property the whole design rests on: rendering the page issues no reverse
// lookups. A resolver that hangs must cost the page nothing, because the peers
// page is read when the network is already misbehaving.
func TestPeersPageNeverResolvesWhileRendering(t *testing.T) {
	server := testRDNSServer(t, func(context.Context, netip.Addr) ([]string, error) {
		t.Error("page render called the resolver")
		return nil, nil
	})

	body := renderPeers(t, server)
	// Nothing cached, so the row reports the name as not yet known — which is
	// what the template turns into a data-rdns marker for the browser.
	if !strings.Contains(body, "203.0.113.10[|false]") {
		t.Fatalf("uncached peer should render as unknown: %q", body)
	}
}

// The other half of the same property: once the cache holds a name, the name is
// in the HTML the server sends, with no marker for the browser to act on.
func TestPeersPageRendersCachedNamesServerSide(t *testing.T) {
	server := testRDNSServer(t, func(context.Context, netip.Addr) ([]string, error) {
		t.Error("page render called the resolver")
		return nil, nil
	})
	server.rdns.store(netip.MustParseAddr("203.0.113.10"), "host.example.net")

	body := renderPeers(t, server)
	if !strings.Contains(body, "203.0.113.10[host.example.net|true]") {
		t.Fatalf("cached name missing from render: %q", body)
	}
}

// A resolved absence renders as known-with-no-name, not as pending. Getting
// this wrong is what would make the browser re-ask about every address that
// will never have a PTR — the majority of them — on every single page load.
func TestPeersPageTreatsAbsenceAsAnswered(t *testing.T) {
	server := testRDNSServer(t, func(context.Context, netip.Addr) ([]string, error) {
		t.Error("page render called the resolver")
		return nil, nil
	})
	server.rdns.store(netip.MustParseAddr("203.0.113.10"), "")

	body := renderPeers(t, server)
	if !strings.Contains(body, "203.0.113.10[|true]") {
		t.Fatalf("resolved absence should render as known: %q", body)
	}
}

func getRDNS(t *testing.T, server *peersServer, path string) map[string]string {
	t.Helper()
	rec := httptest.NewRecorder()
	server.mux().ServeHTTP(rec, httptest.NewRequest(http.MethodGet, path, nil))
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200: %s", rec.Code, rec.Body.String())
	}
	var names map[string]string
	if err := json.Unmarshal(rec.Body.Bytes(), &names); err != nil {
		t.Fatalf("decode %q: %v", rec.Body.String(), err)
	}
	return names
}

// The browser's request resolves, answers, and leaves the answer behind so the
// next render of the page needs none of this.
func TestRDNSEndpointResolvesAndCaches(t *testing.T) {
	var calls atomic.Int32
	server := testRDNSServer(t, func(_ context.Context, addr netip.Addr) ([]string, error) {
		calls.Add(1)
		return []string{"host.example.net."}, nil
	})

	names := getRDNS(t, server, "/peers/192.168.0.10/rdns?addr=203.0.113.10")
	if names["203.0.113.10"] != "host.example.net" {
		t.Fatalf("names = %v, want the trailing dot stripped", names)
	}
	// Cached, so the page now renders it without asking again.
	if !strings.Contains(renderPeers(t, server), "203.0.113.10[host.example.net|true]") {
		t.Fatal("the endpoint's answer did not reach the next render")
	}
	if got := calls.Load(); got != 1 {
		t.Fatalf("resolver calls = %d, want 1", got)
	}
}

// NXDOMAIN is an answer about the address and is kept. The second request must
// not reach the resolver at all.
func TestRDNSCachesAResolvedAbsence(t *testing.T) {
	var calls atomic.Int32
	server := testRDNSServer(t, func(context.Context, netip.Addr) ([]string, error) {
		calls.Add(1)
		return nil, &net.DNSError{Err: "no such host", IsNotFound: true}
	})

	names := getRDNS(t, server, "/peers/192.168.0.10/rdns?addr=203.0.113.10")
	name, present := names["203.0.113.10"]
	if !present || name != "" {
		t.Fatalf("names = %v, want an explicit empty answer", names)
	}
	getRDNS(t, server, "/peers/192.168.0.10/rdns?addr=203.0.113.10")
	if got := calls.Load(); got != 1 {
		t.Fatalf("resolver calls = %d, want 1 — the absence was not cached", got)
	}
}

// A timeout says nothing about whether the address has a name, so it is not
// cached: caching it would hide a real PTR for as long as the entry lived.
func TestRDNSDoesNotCacheAFailedLookup(t *testing.T) {
	var calls atomic.Int32
	server := testRDNSServer(t, func(context.Context, netip.Addr) ([]string, error) {
		calls.Add(1)
		return nil, &net.DNSError{Err: "i/o timeout", IsTimeout: true}
	})

	names := getRDNS(t, server, "/peers/192.168.0.10/rdns?addr=203.0.113.10")
	if _, present := names["203.0.113.10"]; present {
		t.Fatalf("names = %v, want the address absent so it is asked about again", names)
	}
	// Still unknown to the page, and the next request retries.
	if !strings.Contains(renderPeers(t, server), "203.0.113.10[|false]") {
		t.Fatal("a failed lookup was recorded as an answer")
	}
	getRDNS(t, server, "/peers/192.168.0.10/rdns?addr=203.0.113.10")
	if got := calls.Load(); got != 2 {
		t.Fatalf("resolver calls = %d, want 2 — the failure was cached", got)
	}
}

// Two callers wanting the same address issue one query, not two. A page reload
// while the first fill-in is still in flight is the ordinary way this happens.
func TestRDNSDeduplicatesConcurrentLookups(t *testing.T) {
	release := make(chan struct{})
	var calls atomic.Int32
	cache := newRDNSCache()
	cache.lookup = func(context.Context, netip.Addr) ([]string, error) {
		calls.Add(1)
		<-release
		return []string{"host.example.net."}, nil
	}

	addr := netip.MustParseAddr("203.0.113.10")
	var wg sync.WaitGroup
	got := make([]string, 8)
	for i := range got {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			name, _ := cache.resolve(context.Background(), addr)
			got[i] = name
		}(i)
	}
	// Let every caller reach the lookup before any of them may finish.
	time.Sleep(50 * time.Millisecond)
	close(release)
	wg.Wait()

	if n := calls.Load(); n != 1 {
		t.Fatalf("resolver calls = %d, want 1", n)
	}
	for i, name := range got {
		if name != "host.example.net" {
			t.Fatalf("caller %d got %q, want every caller to see the answer", i, name)
		}
	}
}

// Entries age out, and an absence ages out sooner than a name — a wrong
// negative held for an hour is a column that stays mysteriously empty.
func TestRDNSEntriesExpire(t *testing.T) {
	now := time.Now()
	cache := newRDNSCache()
	cache.now = func() time.Time { return now }

	named := netip.MustParseAddr("203.0.113.10")
	nameless := netip.MustParseAddr("203.0.113.11")
	cache.store(named, "host.example.net")
	cache.store(nameless, "")

	now = now.Add(rdnsNegativeTTL + time.Second)
	if _, ok := cache.cached(nameless); ok {
		t.Fatal("the absence outlived its shorter TTL")
	}
	if _, ok := cache.cached(named); !ok {
		t.Fatal("the name expired on the negative TTL")
	}

	now = now.Add(rdnsTTL)
	if _, ok := cache.cached(named); ok {
		t.Fatal("the name outlived its TTL")
	}
}

// The map is bounded. A peers page can see a great many distinct addresses,
// and a cache that only ever grew would be a slow leak in a long-lived process.
func TestRDNSCacheIsBounded(t *testing.T) {
	cache := newRDNSCache()
	for i := range rdnsMaxEntries + 64 {
		cache.store(netip.MustParseAddr(fmt.Sprintf("203.0.%d.%d", i/256, i%256)), "host")
	}
	if len(cache.entries) > rdnsMaxEntries {
		t.Fatalf("entries = %d, want at most %d", len(cache.entries), rdnsMaxEntries)
	}
}

// One malformed address must not blank every other cell in the table.
func TestRDNSEndpointSkipsUnparseableAddresses(t *testing.T) {
	server := testRDNSServer(t, func(_ context.Context, addr netip.Addr) ([]string, error) {
		return []string{"host.example.net."}, nil
	})

	names := getRDNS(t, server,
		"/peers/192.168.0.10/rdns?addr=not-an-ip&addr=203.0.113.10")
	if names["203.0.113.10"] != "host.example.net" {
		t.Fatalf("names = %v, want the parseable address still answered", names)
	}
	if len(names) != 1 {
		t.Fatalf("names = %v, want only the parseable address", names)
	}
}

// The per-request cap bounds the work one request can ask for. The script sends
// batches of this size, so nothing is lost — the rest arrive in the next batch.
func TestRDNSEndpointCapsABatch(t *testing.T) {
	server := testRDNSServer(t, func(_ context.Context, addr netip.Addr) ([]string, error) {
		return []string{addr.String() + ".example.net."}, nil
	})

	query := make([]string, 0, rdnsBatchLimit+16)
	for i := range rdnsBatchLimit + 16 {
		query = append(query, fmt.Sprintf("addr=203.0.113.%d", i))
	}
	names := getRDNS(t, server, "/peers/192.168.0.10/rdns?"+strings.Join(query, "&"))
	if len(names) != rdnsBatchLimit {
		t.Fatalf("names = %d entries, want %d", len(names), rdnsBatchLimit)
	}
}

// The route is vetted like every other route under /peers: it cannot be pointed
// at something that is not a device on this LAN.
func TestRDNSEndpointRejectsAddressOutsideLAN(t *testing.T) {
	server := testRDNSServer(t, func(context.Context, netip.Addr) ([]string, error) {
		t.Error("resolved for a rejected device")
		return nil, nil
	})
	rec := httptest.NewRecorder()
	server.mux().ServeHTTP(rec,
		httptest.NewRequest(http.MethodGet, "/peers/203.0.113.10/rdns?addr=203.0.113.10", nil))
	if rec.Code != http.StatusNotFound {
		t.Fatalf("status = %d, want 404", rec.Code)
	}
}

func TestRDNSEndpointRefusesCrossSite(t *testing.T) {
	server := testRDNSServer(t, func(context.Context, netip.Addr) ([]string, error) {
		t.Error("resolved for a cross-site request")
		return nil, nil
	})
	req := httptest.NewRequest(http.MethodGet, "/peers/192.168.0.10/rdns?addr=203.0.113.10", nil)
	req.Header.Set("Sec-Fetch-Site", "cross-site")
	rec := httptest.NewRecorder()
	server.mux().ServeHTTP(rec, req)
	if rec.Code != http.StatusForbidden {
		t.Fatalf("status = %d, want 403", rec.Code)
	}
}

// A nil cache disables the feature completely, including the route — the same
// idiom the capture and low-trust routes use.
func TestRDNSRouteAbsentWhenDisabled(t *testing.T) {
	server := testPeersServer(t)
	server.rdns = nil
	rec := httptest.NewRecorder()
	server.mux().ServeHTTP(rec,
		httptest.NewRequest(http.MethodGet, "/peers/192.168.0.10/rdns?addr=203.0.113.10", nil))
	if rec.Code != http.StatusNotFound {
		t.Fatalf("status = %d, want 404", rec.Code)
	}
	// And the page still renders, with every row simply unnamed.
	rec = httptest.NewRecorder()
	server.mux().ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/peers/192.168.0.10", nil))
	if rec.Code != http.StatusOK {
		t.Fatalf("page status = %d, want 200", rec.Code)
	}
}

// The real template, not a fixture: the attributes the browser and the card
// layout depend on are markup, and a fixture template cannot catch losing them.
func TestRealTemplateRendersRDNSAndCardLabels(t *testing.T) {
	tmpl, err := template.ParseFiles("peers.html", "nav.html")
	if err != nil {
		t.Fatalf("parse peers.html: %v", err)
	}
	var out strings.Builder
	err = tmpl.Execute(&out, peersPageData{
		Device: "192.168.0.10",
		Peers: []peerRow{
			// Known, with a name: rendered server-side and not marked for the
			// browser to ask about. Also carries a resolved name, so both
			// lines appear at once — the case the two labels exist for.
			{Addr: "203.0.113.10", Bytes: "1 kB", SharePct: "0.0",
				RDNS: "host.example.net", RDNSKnown: true,
				DNSName: "cdn.example.com"},
			// Known to have none: also not marked. This is the case that would
			// otherwise have the browser re-asking on every single load. The
			// resolved name is the only handle on it, which is the whole point
			// of the answer log — an in-ISP cache looks exactly like this.
			{Addr: "203.0.113.20", Bytes: "1 kB", SharePct: "0.0", RDNSKnown: true,
				DNSName: "scontent.example.net"},
			// Not yet known: the one the script fills in.
			{Addr: "203.0.113.30", Bytes: "1 kB", SharePct: "0.0"},
		},
	})
	if err != nil {
		t.Fatalf("execute peers.html: %v", err)
	}
	body := out.String()

	for _, want := range []string{
		// Both names, under their address, in the HTML the server sent. The
		// separate classes are what the ptr/dns labels hang off — collapsing
		// them into one would present a resolved name as a PTR.
		`class="rdns" title=`,
		`>host.example.net</span>`,
		`class="qname" title=`,
		`>cdn.example.com</span>`,
		// An address with no PTR still gets named by the answer log.
		`>scontent.example.net</span>`,
		// Only the unresolved address is offered to the script.
		`data-rdns="203.0.113.30"`,
		// The card layout's labels and the roles that keep the collapsed table
		// a table to a screen reader.
		// Short enough for the card layout's fixed label gutter — the column
		// head above still reads "Organisation", and the full word overflowed.
		`data-label="Org"`,
		`class="table-cards" role="table"`,
		`<td role="cell" class="cell-key"`,
	} {
		if !strings.Contains(body, want) {
			t.Fatalf("rendered page is missing %s\n%s", want, body)
		}
	}
	for _, unwanted := range []string{
		`data-rdns="203.0.113.10"`,
		`data-rdns="203.0.113.20"`,
	} {
		if strings.Contains(body, unwanted) {
			t.Fatalf("resolved address %s was still offered to the script", unwanted)
		}
	}
}

func TestPickName(t *testing.T) {
	cases := []struct {
		name string
		in   []string
		want string
	}{
		{"trailing dot stripped", []string{"host.example.net."}, "host.example.net"},
		{"empty answer", nil, ""},
		{"blank entries ignored", []string{"", ".", " "}, ""},
		// Several PTRs on one address is legal. The choice must not depend on
		// the order the resolver happened to return them in, or the name would
		// appear to change between refreshes for no reason.
		{"lowest of several", []string{"z.example.net.", "a.example.net."}, "a.example.net"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := pickName(tc.in); got != tc.want {
				t.Fatalf("pickName(%q) = %q, want %q", tc.in, got, tc.want)
			}
		})
	}
}
