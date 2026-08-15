package main

import (
	"bytes"
	"context"
	"encoding/binary"
	"errors"
	"html/template"
	"io"
	"log"
	"net/http"
	"net/http/httptest"
	"net/netip"
	"net/url"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
	"time"
)

var errFake = errors.New("conntrack unavailable")

func testPeersServer(t *testing.T) *peersServer {
	t.Helper()
	tmpl, err := template.New("peers.html").Parse(
		`{{.Device}}|{{range .Peers}}{{.Addr}},{{.ASN}},{{.Org}},{{.Country}},{{.SharePct}},{{.Shape}};{{end}}|{{.Error}}|{{.LowTrust}}`)
	if err != nil {
		t.Fatalf("parse template: %v", err)
	}
	table, err := LoadASNTable(writeTSV(t,
		"203.0.113.0\t203.0.113.255\t64496\tNL\tExample Hosting\n"))
	if err != nil {
		t.Fatalf("LoadASNTable: %v", err)
	}
	indexTmpl, err := template.New("peers-index.html").Parse(
		`{{range .Leases}}{{.Addr}}={{.Name}};{{end}}|{{.Error}}|{{.PriorityError}}`)
	if err != nil {
		t.Fatalf("parse index template: %v", err)
	}
	leases := writeLeases(t, "1 aa:bb:cc:dd:ee:01 192.168.0.10 device-a 01:aa\n"+
		"2 aa:bb:cc:dd:ee:02 192.168.0.20 * 01:bb\n")
	server := newPeersServer(netip.MustParsePrefix("192.168.0.0/24"), table, tmpl, indexTmpl, leases)
	server.conntrack = func(context.Context) ([]byte, error) {
		return []byte(conntrackFixture), nil
	}
	server.runTool = func(string, ...string) (string, error) { return "ok", nil }
	// Non-nil is what enables the low-trust pool, so setting these is what puts
	// the default test server in the enabled state — see
	// testPeersServerWithoutLowTrust for the other one. Stubs rather than the
	// real functions so render() never shells out to ip(8) or nft(8) on
	// whatever machine runs the suite.
	server.neighbours = func(context.Context) ([]byte, error) { return nil, nil }
	server.lowTrust = func(context.Context, string) string { return "" }
	return server
}

// testPeersServerWithoutLowTrust is the shape bongo runs: router-web with the
// pool disabled. Nil is the disabled state for both fields, which is what
// newPeersServer already leaves them at — clearing them explicitly here so the
// intent survives someone re-adding a default in the constructor.
func testPeersServerWithoutLowTrust(t *testing.T) *peersServer {
	t.Helper()
	server := testPeersServer(t)
	server.neighbours = nil
	server.lowTrust = nil
	return server
}

func TestPeersPageListsPeersWithASN(t *testing.T) {
	rec := httptest.NewRecorder()
	testPeersServer(t).mux().ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/peers/192.168.0.10", nil))

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200", rec.Code)
	}
	body := rec.Body.String()
	if !strings.Contains(body, "203.0.113.10,64496,Example Hosting,NL,") {
		t.Fatalf("peer row with ASN attribution missing from body: %q", body)
	}
	// 30800 of 35800 total bytes = 86.0%.
	if !strings.Contains(body, "86.0") {
		t.Fatalf("top-peer share missing from body: %q", body)
	}
}

func TestPeersPageRejectsAddressOutsideLAN(t *testing.T) {
	rec := httptest.NewRecorder()
	testPeersServer(t).mux().ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/peers/203.0.113.10", nil))
	if rec.Code != http.StatusNotFound {
		t.Fatalf("status = %d, want 404", rec.Code)
	}
}

func TestPeersPageRejectsUnparseableAddress(t *testing.T) {
	rec := httptest.NewRecorder()
	testPeersServer(t).mux().ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/peers/not-an-ip", nil))
	if rec.Code != http.StatusNotFound {
		t.Fatalf("status = %d, want 404", rec.Code)
	}
}

func TestPeersPageErrorsWhenConntrackFails(t *testing.T) {
	server := testPeersServer(t)
	server.conntrack = func(context.Context) ([]byte, error) { return nil, errFake }
	rec := httptest.NewRecorder()
	server.mux().ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/peers/192.168.0.10", nil))
	if rec.Code != http.StatusInternalServerError {
		t.Fatalf("status = %d, want 500 — an unreadable table must not look like an idle device", rec.Code)
	}
}

func TestActionThrottlesPeer(t *testing.T) {
	server := testPeersServer(t)
	var gotName string
	var gotArgs []string
	server.runTool = func(name string, args ...string) (string, error) {
		gotName, gotArgs = name, args
		return "throttled: 203.0.113.10", nil
	}

	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodPost, "/peers/192.168.0.10/throttle",
		strings.NewReader("peer=203.0.113.10"))
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	server.mux().ServeHTTP(rec, req)

	if rec.Code != http.StatusSeeOther {
		t.Fatalf("status = %d, want 303", rec.Code)
	}
	if gotName != "tempthrottle" || len(gotArgs) != 2 || gotArgs[0] != "add" || gotArgs[1] != "203.0.113.10" {
		t.Fatalf("ran %s %v, want tempthrottle add 203.0.113.10", gotName, gotArgs)
	}
}

func TestActionBlocksPeer(t *testing.T) {
	server := testPeersServer(t)
	var gotName string
	server.runTool = func(name string, args ...string) (string, error) {
		gotName = name
		return "blocked", nil
	}
	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodPost, "/peers/192.168.0.10/block",
		strings.NewReader("peer=203.0.113.10"))
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	server.mux().ServeHTTP(rec, req)
	if gotName != "tempblock" {
		t.Fatalf("ran %q, want tempblock", gotName)
	}
}

func TestActionRefusesNonPublicPeer(t *testing.T) {
	for _, peer := range []string{"192.168.0.1", "10.10.0.18", "127.0.0.1"} {
		t.Run(peer, func(t *testing.T) {
			server := testPeersServer(t)
			called := false
			server.runTool = func(string, ...string) (string, error) {
				called = true
				return "", nil
			}
			rec := httptest.NewRecorder()
			req := httptest.NewRequest(http.MethodPost, "/peers/192.168.0.10/throttle",
				strings.NewReader("peer="+peer))
			req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
			server.mux().ServeHTTP(rec, req)
			if called {
				t.Fatal("tool was invoked for a non-public peer")
			}
			if rec.Code != http.StatusBadRequest {
				t.Fatalf("status = %d, want 400", rec.Code)
			}
		})
	}
}

func TestActionRejectsGET(t *testing.T) {
	rec := httptest.NewRecorder()
	testPeersServer(t).mux().ServeHTTP(rec,
		httptest.NewRequest(http.MethodGet, "/peers/192.168.0.10/throttle", nil))
	if rec.Code == http.StatusSeeOther || rec.Code == http.StatusOK {
		t.Fatalf("GET on a mutation route returned %d; it must not act", rec.Code)
	}
}

func TestActionLogsToJournal(t *testing.T) {
	var buf strings.Builder
	log.SetOutput(&buf)
	log.SetFlags(0)
	t.Cleanup(func() { log.SetOutput(os.Stderr) })

	server := testPeersServer(t)
	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodPost, "/peers/192.168.0.10/throttle",
		strings.NewReader("peer=203.0.113.10"))
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	server.mux().ServeHTTP(rec, req)

	line := buf.String()
	for _, want := range []string{
		"peer-action",
		"action=throttle",
		`peer="203.0.113.10"`,
		"asn=64496",
		`org="Example Hosting"`,
		"cc=NL",
		`device="192.168.0.10"`,
		`result="ok"`,
	} {
		if !strings.Contains(line, want) {
			t.Fatalf("log line missing %q: %s", want, line)
		}
	}
}

func TestActionRefusesZonedPeerAndLogsOneLine(t *testing.T) {
	var buf strings.Builder
	log.SetOutput(&buf)
	log.SetFlags(0)
	t.Cleanup(func() { log.SetOutput(os.Stderr) })

	server := testPeersServer(t)
	called := false
	server.runTool = func(string, ...string) (string, error) {
		called = true
		return "", nil
	}

	form := url.Values{"peer": {"2001:db8::1%evil\nFORGED peer-action action=block"}}
	req := httptest.NewRequest(http.MethodPost, "/peers/192.168.0.10/throttle",
		strings.NewReader(form.Encode()))
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	rec := httptest.NewRecorder()
	server.mux().ServeHTTP(rec, req)

	if called {
		t.Fatal("tool was invoked for a zoned address")
	}
	if got := strings.Count(strings.TrimRight(buf.String(), "\n"), "\n"); got != 0 {
		t.Fatalf("log emitted %d extra newlines; a single action must produce a single line:\n%s", got, buf.String())
	}
	if strings.Contains(buf.String(), "FORGED") && !strings.Contains(buf.String(), `\n`) {
		t.Fatalf("attacker text reached the log unescaped:\n%s", buf.String())
	}
}

func TestActionRefusesCrossSiteRequest(t *testing.T) {
	server := testPeersServer(t)
	called := false
	server.runTool = func(string, ...string) (string, error) { called = true; return "", nil }

	req := httptest.NewRequest(http.MethodPost, "/peers/192.168.0.10/throttle",
		strings.NewReader("peer=203.0.113.10"))
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	req.Header.Set("Sec-Fetch-Site", "cross-site")
	rec := httptest.NewRecorder()
	server.mux().ServeHTTP(rec, req)

	if called {
		t.Fatal("tool was invoked for a cross-site request")
	}
	if rec.Code != http.StatusForbidden {
		t.Fatalf("status = %d, want 403", rec.Code)
	}
}

func TestLANMuxHasNoPeersRoutes(t *testing.T) {
	tmpl, err := template.New("index.html").Parse("landing")
	if err != nil {
		t.Fatalf("parse: %v", err)
	}
	lan := landingMux(pageData{}, tmpl, nil)

	for _, path := range []string{"/peers/192.168.0.10", "/peers/192.168.0.10/throttle"} {
		rec := httptest.NewRecorder()
		lan.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, path, nil))
		if rec.Code != http.StatusNotFound {
			t.Fatalf("LAN mux served %s with %d; peers routes must be mesh-only", path, rec.Code)
		}
	}
}

func TestMeshListenAddrRejectsWildcard(t *testing.T) {
	for _, raw := range []string{":80", "0.0.0.0:80", "[::]:80"} {
		if _, err := meshListenAddr(raw); err == nil {
			t.Fatalf("meshListenAddr(%q) accepted a wildcard address", raw)
		}
	}
}

func TestMeshListenAddrAcceptsSpecificAddress(t *testing.T) {
	for _, raw := range []string{"192.168.0.10:80", "[2001:db8::1]:80"} {
		got, err := meshListenAddr(raw)
		if err != nil {
			t.Fatalf("meshListenAddr(%q) rejected a specific address: %v", raw, err)
		}
		if got != raw {
			t.Fatalf("meshListenAddr(%q) = %q, want it returned unchanged", raw, got)
		}
	}
}

func TestMeshListenAddrRejectsMalformed(t *testing.T) {
	for _, raw := range []string{"", "notanaddress", "192.168.0.10", "host.example:80"} {
		if _, err := meshListenAddr(raw); err == nil {
			t.Fatalf("meshListenAddr(%q) accepted malformed input", raw)
		}
	}
}

func TestIndexListsLeasesWithLinks(t *testing.T) {
	rec := httptest.NewRecorder()
	testPeersServer(t).mux().ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/peers", nil))

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200", rec.Code)
	}
	body := rec.Body.String()
	if !strings.Contains(body, "192.168.0.10=device-a") {
		t.Fatalf("named lease missing from index: %q", body)
	}
	if !strings.Contains(body, "192.168.0.20=;") {
		t.Fatalf("unnamed lease should render with an empty name: %q", body)
	}
}

func TestIndexReportsUnreadableLeaseFile(t *testing.T) {
	server := testPeersServer(t)
	server.leasesPath = filepath.Join(t.TempDir(), "absent")
	rec := httptest.NewRecorder()
	server.mux().ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/peers", nil))

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200 — a missing lease file must not fail the page", rec.Code)
	}
	if !strings.Contains(rec.Body.String(), "Cannot read the DHCP lease file") {
		t.Fatalf("no notice shown for an unreadable lease file: %q", rec.Body.String())
	}
}

func TestIndexDoesNotSwallowOtherPaths(t *testing.T) {
	rec := httptest.NewRecorder()
	testPeersServer(t).mux().ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/nonsense", nil))
	if rec.Code != http.StatusNotFound {
		t.Fatalf("status = %d, want 404 — the index must not act as a catch-all", rec.Code)
	}
}

func TestLANMuxHasNoIndexRoute(t *testing.T) {
	tmpl, err := template.New("index.html").Parse("landing")
	if err != nil {
		t.Fatalf("parse: %v", err)
	}
	rec := httptest.NewRecorder()
	landingMux(pageData{}, tmpl, nil).ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/peers/192.168.0.10", nil))
	if rec.Code != http.StatusNotFound {
		t.Fatalf("LAN mux served a peers path with %d", rec.Code)
	}
}

func TestPeersPageShowsShapingStatus(t *testing.T) {
	server := testPeersServer(t)
	server.shapes = &shapeCache{
		ttl: time.Hour,
		read: func(_ context.Context, set string) ([]byte, error) {
			if set == "throttle4" {
				return setDoc(`"203.0.113.10"`), nil
			}
			return nil, errors.New("absent")
		},
	}
	rec := httptest.NewRecorder()
	server.mux().ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/peers/192.168.0.10", nil))
	if !strings.Contains(rec.Body.String(), "throttled") {
		t.Fatalf("already-throttled peer not marked in the page: %q", rec.Body.String())
	}
}

// The other tests render a stub template, so nothing here would otherwise
// notice a syntax error in the real peers.html — and a template that fails to
// parse takes the whole peers page down at startup, not just one column.
func TestRealTemplateRendersTrafficColumn(t *testing.T) {
	tmpl, err := template.ParseFiles("peers.html")
	if err != nil {
		t.Fatalf("parse peers.html: %v", err)
	}
	data := peersPageData{
		Device: "192.168.0.10",
		Peers: []peerRow{
			{
				Addr: "203.0.113.10", Bytes: "30.8 kB", Up: "1.2 kB", Down: "29.6 kB",
				SharePct: "80.0", High: true,
				Traffic: traffic{
					Label: "call", Call: true,
					Ports: []portChip{{Text: "udp/3478"}, {Text: "tcp/889", Suspect: true}},
					More:  2,
				},
			},
			// A peer with nothing recorded: the column must still render a cell.
			{Addr: "203.0.113.20", Bytes: "1 kB", SharePct: "20.0"},
		},
	}
	var out strings.Builder
	if err := tmpl.Execute(&out, data); err != nil {
		t.Fatalf("execute peers.html: %v", err)
	}
	body := out.String()
	for _, want := range []string{
		`<span class="label call">call</span>`,
		`&uarr; 1.2 kB &nbsp;&darr; 29.6 kB`,
		`<code class="port">udp/3478</code>`,
		`<code class="port suspect">tcp/889</code>`,
		`<span class="more">+2</span>`,
	} {
		if !strings.Contains(body, want) {
			t.Fatalf("rendered page is missing %s\n%s", want, body)
		}
	}
	// Every row keeps the same cell count, or the table skews from here down.
	if got, want := strings.Count(body, "<tr"), 3; got != want {
		t.Fatalf("got %d rows (including the header), want %d", got, want)
	}
	for _, row := range strings.Split(body, "<tr")[1:] {
		if got := strings.Count(row, "<td"); got != 0 && got != 9 {
			t.Fatalf("row has %d cells, want 9:\n%s", got, row)
		}
	}
}

func TestIndexListsPrioritisedConversations(t *testing.T) {
	server := testPeersServer(t)
	server.namer = namer{callMark: 2}
	server.conntrack = func(context.Context) ([]byte, error) {
		return []byte(markedFixture), nil
	}
	server.indexTmpl = template.Must(template.New("peers-index.html").Parse(
		`{{range .Priority}}{{.Device}}/{{.DeviceName}}>{{.Peer}}:{{.Traffic.Label}},{{.Bytes}},{{.Up}},{{.Down}};{{end}}|{{.PriorityError}}`))

	rec := httptest.NewRecorder()
	server.mux().ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/peers", nil))
	body := rec.Body.String()

	// The device's lease name is carried through, so the row is readable
	// without cross-referencing the table below it.
	if !strings.Contains(body, "192.168.0.10/device-a>203.0.113.10:call,18.6 KiB,8.6 KiB,10.0 KiB;") {
		t.Fatalf("prioritised call missing or malformed: %q", body)
	}
	// A device with no hostname still appears, with an empty name.
	if !strings.Contains(body, "192.168.0.20/>203.0.113.20:call") {
		t.Fatalf("unnamed device missing from the prioritised list: %q", body)
	}
	// Marked DNS is listed, but as DoT rather than as a call.
	if !strings.Contains(body, "203.0.113.30:DoT") {
		t.Fatalf("marked DoT should be listed under its own label: %q", body)
	}
}

func TestIndexSurvivesUnreadableConntrack(t *testing.T) {
	server := testPeersServer(t)
	server.namer = namer{callMark: 2}
	server.conntrack = func(context.Context) ([]byte, error) { return nil, errFake }

	rec := httptest.NewRecorder()
	server.mux().ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/peers", nil))
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200 — the device list must survive a dead connection table", rec.Code)
	}
	// The lease list is still there, and the failure is reported rather than
	// rendered as "nothing is prioritised".
	body := rec.Body.String()
	if !strings.Contains(body, "192.168.0.10=device-a") {
		t.Fatalf("lease list lost when conntrack failed: %q", body)
	}
	if !strings.Contains(body, "Cannot read the connection table") {
		t.Fatalf("no notice shown for an unreadable connection table: %q", body)
	}
}

func TestIndexWithoutCallMarkCollectsNothing(t *testing.T) {
	// The zero namer is what a router that passes no ROUTER_CALL_MARK gets.
	// It must not read conntrack at all, rather than reading it and finding
	// nothing.
	server := testPeersServer(t)
	called := false
	server.conntrack = func(context.Context) ([]byte, error) {
		called = true
		return []byte(markedFixture), nil
	}
	rec := httptest.NewRecorder()
	server.mux().ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/peers", nil))
	if called {
		t.Fatal("conntrack was read even though no priority mark is configured")
	}
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200", rec.Code)
	}
}

// The stub templates elsewhere would not catch a syntax error in the real
// index, and a template that fails to parse takes the whole peers page down.
func TestRealIndexTemplateRendersPriority(t *testing.T) {
	tmpl, err := template.ParseFiles("peers-index.html")
	if err != nil {
		t.Fatalf("parse peers-index.html: %v", err)
	}
	data := indexPageData{
		Leases: []lease{{Addr: netip.MustParseAddr("192.168.0.10"), Name: "device-a"}},
		Priority: []priorityRow{{
			Device: "192.168.0.10", DeviceName: "device-a", Peer: "203.0.113.10",
			ASN: 64496, Org: "Example Hosting", Country: "NL",
			Bytes: "18.6 KiB", Up: "8.6 KiB", Down: "10.0 KiB",
			Traffic: traffic{Label: "call", Call: true, Ports: []portChip{{Text: "udp/3478"}}},
		}},
	}
	var out strings.Builder
	if err := tmpl.Execute(&out, data); err != nil {
		t.Fatalf("execute peers-index.html: %v", err)
	}
	body := out.String()
	for _, want := range []string{
		`<span class="label call">call</span>`,
		`<a href="/peers/192.168.0.10">192.168.0.10</a>`,
		`&uarr; 8.6 KiB &nbsp;&darr; 10.0 KiB`,
		`<code class="port">udp/3478</code>`,
	} {
		if !strings.Contains(body, want) {
			t.Fatalf("rendered index is missing %s\n%s", want, body)
		}
	}
}

func TestRealIndexTemplateSaysWhenNothingIsPrioritised(t *testing.T) {
	tmpl := template.Must(template.ParseFiles("peers-index.html"))
	var out strings.Builder
	if err := tmpl.Execute(&out, indexPageData{}); err != nil {
		t.Fatalf("execute: %v", err)
	}
	if !strings.Contains(out.String(), "Nothing is being prioritised right now") {
		t.Fatalf("an empty priority list must say so:\n%s", out.String())
	}
}

func TestActionDropsPeerScopedToTheDevice(t *testing.T) {
	server := testPeersServer(t)
	var gotName string
	var gotArgs []string
	server.runTool = func(name string, args ...string) (string, error) {
		gotName, gotArgs = name, args
		return "killed 3 flow(s): 203.0.113.10 from 192.168.0.10", nil
	}

	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodPost, "/peers/192.168.0.10/drop",
		strings.NewReader("peer=203.0.113.10"))
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	server.mux().ServeHTTP(rec, req)

	if rec.Code != http.StatusSeeOther {
		t.Fatalf("status = %d, want 303", rec.Code)
	}
	want := []string{"203.0.113.10", "from", "192.168.0.10"}
	if gotName != "killconn" || !slices.Equal(gotArgs, want) {
		t.Fatalf("ran %s %v, want killconn %v", gotName, gotArgs, want)
	}
}

func TestActionDropRefusesNonPublicPeer(t *testing.T) {
	server := testPeersServer(t)
	called := false
	server.runTool = func(string, ...string) (string, error) { called = true; return "", nil }
	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodPost, "/peers/192.168.0.10/drop",
		strings.NewReader("peer=192.168.0.1"))
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	server.mux().ServeHTTP(rec, req)
	if rec.Code != http.StatusBadRequest {
		t.Fatalf("status = %d, want 400", rec.Code)
	}
	if called {
		t.Fatal("killconn was run against a non-public address")
	}
}

func TestActionDropRefusesCrossSiteRequest(t *testing.T) {
	server := testPeersServer(t)
	called := false
	server.runTool = func(string, ...string) (string, error) { called = true; return "", nil }
	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodPost, "/peers/192.168.0.10/drop",
		strings.NewReader("peer=203.0.113.10"))
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	req.Header.Set("Sec-Fetch-Site", "cross-site")
	server.mux().ServeHTTP(rec, req)
	if rec.Code != http.StatusForbidden {
		t.Fatalf("status = %d, want 403", rec.Code)
	}
	if called {
		t.Fatal("killconn was run for a cross-site POST")
	}
}

func TestActionDropsEveryFlowForTheDevice(t *testing.T) {
	server := testPeersServer(t)
	var gotName string
	var gotArgs []string
	server.runTool = func(name string, args ...string) (string, error) {
		gotName, gotArgs = name, args
		return "killed 12 flow(s): everything from 192.168.0.10", nil
	}

	rec := httptest.NewRecorder()
	// No peer field at all: this action is about the device.
	req := httptest.NewRequest(http.MethodPost, "/peers/192.168.0.10/drop-all", nil)
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	server.mux().ServeHTTP(rec, req)

	if rec.Code != http.StatusSeeOther {
		t.Fatalf("status = %d, want 303", rec.Code)
	}
	want := []string{"from", "192.168.0.10"}
	if gotName != "killconn" || !slices.Equal(gotArgs, want) {
		t.Fatalf("ran %s %v, want killconn %v", gotName, gotArgs, want)
	}
}

func TestActionDropAllIgnoresASubmittedPeer(t *testing.T) {
	// The route is device-wide by construction. A peer field posted to it — by
	// a stale form or by hand — must not narrow or redirect the action, or the
	// button would silently do something other than what it says.
	server := testPeersServer(t)
	var gotArgs []string
	server.runTool = func(_ string, args ...string) (string, error) {
		gotArgs = args
		return "", nil
	}
	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodPost, "/peers/192.168.0.10/drop-all",
		strings.NewReader("peer=203.0.113.10"))
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	server.mux().ServeHTTP(rec, req)
	if !slices.Equal(gotArgs, []string{"from", "192.168.0.10"}) {
		t.Fatalf("ran killconn %v, want [from 192.168.0.10]", gotArgs)
	}
}

func TestActionDropAllRefusesANonLANDevice(t *testing.T) {
	// The peer guard does not apply to this route, so the device guard is the
	// only thing standing between it and an arbitrary address. Asserting 404
	// on the out-of-LAN address alone would also pass if the /drop-all route
	// were never registered at all — any unrouted path 404s. So this first
	// proves the route is live and working for an in-LAN device, then checks
	// the out-of-LAN address is rejected and never reaches the tool. Only
	// with the first half established does the second half's 404 mean the
	// device guard, specifically, did the rejecting.
	server := testPeersServer(t)
	called := false
	server.runTool = func(string, ...string) (string, error) { called = true; return "ok", nil }
	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodPost, "/peers/192.168.0.10/drop-all", nil)
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	server.mux().ServeHTTP(rec, req)
	if rec.Code != http.StatusSeeOther {
		t.Fatalf("status = %d, want 303 — the route must work for an in-LAN device", rec.Code)
	}
	if !called {
		t.Fatal("killconn was not run for an in-LAN device")
	}

	called = false
	rec = httptest.NewRecorder()
	req = httptest.NewRequest(http.MethodPost, "/peers/203.0.113.10/drop-all", nil)
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	server.mux().ServeHTTP(rec, req)
	if rec.Code != http.StatusNotFound {
		t.Fatalf("status = %d, want 404", rec.Code)
	}
	if called {
		t.Fatal("killconn was run against an address outside the LAN")
	}
}

func TestActionDropAllRefusesCrossSiteRequest(t *testing.T) {
	server := testPeersServer(t)
	called := false
	server.runTool = func(string, ...string) (string, error) { called = true; return "", nil }
	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodPost, "/peers/192.168.0.10/drop-all", nil)
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	req.Header.Set("Sec-Fetch-Site", "cross-site")
	server.mux().ServeHTTP(rec, req)
	if rec.Code != http.StatusForbidden {
		t.Fatalf("status = %d, want 403", rec.Code)
	}
	if called {
		t.Fatal("killconn was run for a cross-site POST")
	}
}

func TestActionDropAllLogsWithoutAPeer(t *testing.T) {
	// Follows TestActionLogsToJournal's capture idiom (strings.Builder,
	// t.Cleanup) rather than the bytes.Buffer/defer form, so the two tests
	// don't disagree about how to borrow the global logger.
	var buf strings.Builder
	log.SetOutput(&buf)
	t.Cleanup(func() { log.SetOutput(os.Stderr) })

	server := testPeersServer(t)
	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodPost, "/peers/192.168.0.10/drop-all", nil)
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	server.mux().ServeHTTP(rec, req)

	line := buf.String()
	for _, want := range []string{`action=drop-all`, `peer="-"`, `device="192.168.0.10"`, `result="ok"`} {
		if !strings.Contains(line, want) {
			t.Fatalf("journal line is missing %s: %q", want, line)
		}
	}
	if strings.Contains(line, "invalid IP") {
		t.Fatalf("zero address leaked into the journal: %q", line)
	}
}

func TestActionAddsDeviceToLowTrustPool(t *testing.T) {
	server := testPeersServer(t)
	var gotName string
	var gotArgs []string
	server.runTool = func(name string, args ...string) (string, error) {
		gotName, gotArgs = name, args
		return "lowtrust: added aa:bb:cc:dd:ee:01", nil
	}

	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodPost, "/peers/192.168.0.10/lowtrust", nil)
	server.mux().ServeHTTP(rec, req)

	if rec.Code != http.StatusSeeOther {
		t.Fatalf("status = %d, want 303", rec.Code)
	}
	if gotName != "lowtrust" || len(gotArgs) != 2 || gotArgs[0] != "add" || gotArgs[1] != "192.168.0.10" {
		t.Fatalf("ran %s %v, want lowtrust add 192.168.0.10", gotName, gotArgs)
	}
}

func TestActionRemovesDeviceFromLowTrustPool(t *testing.T) {
	server := testPeersServer(t)
	var gotName string
	var gotArgs []string
	server.runTool = func(name string, args ...string) (string, error) {
		gotName, gotArgs = name, args
		return "lowtrust: removed aa:bb:cc:dd:ee:01", nil
	}

	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodPost, "/peers/192.168.0.10/lowtrust/remove", nil)
	server.mux().ServeHTTP(rec, req)

	// The tool name is asserted, not discarded: this is the only test covering
	// this route, so a typo in its `tool:` field would otherwise ship silently
	// and the button would 500 on the router.
	if gotName != "lowtrust" || len(gotArgs) != 2 || gotArgs[0] != "del" || gotArgs[1] != "192.168.0.10" {
		t.Fatalf("ran %s %v, want lowtrust del 192.168.0.10", gotName, gotArgs)
	}
}

// TestLowTrustRoutesAbsentWhenDisabled is the bongo case: the pool is off, so
// the two routes must answer exactly as they did before the feature existed.
// A 500 from a registered route would mean the page offered an action the
// router cannot perform.
func TestLowTrustRoutesAbsentWhenDisabled(t *testing.T) {
	for _, path := range []string{
		"/peers/192.168.0.10/lowtrust",
		"/peers/192.168.0.10/lowtrust/remove",
	} {
		server := testPeersServerWithoutLowTrust(t)
		ran := false
		server.runTool = func(string, ...string) (string, error) { ran = true; return "", nil }

		rec := httptest.NewRecorder()
		server.mux().ServeHTTP(rec, httptest.NewRequest(http.MethodPost, path, nil))

		if rec.Code != http.StatusNotFound {
			t.Errorf("POST %s: status = %d, want 404", path, rec.Code)
		}
		if ran {
			t.Errorf("POST %s invoked a tool on a router without the pool", path)
		}
	}
}

// TestLowTrustRoutesPresentWhenEnabled is the other half of the pair: the same
// mux with the feature on must register both routes. Without it, gating the
// routes could regress into gating them away entirely and nothing would fail.
func TestLowTrustRoutesPresentWhenEnabled(t *testing.T) {
	for _, path := range []string{
		"/peers/192.168.0.10/lowtrust",
		"/peers/192.168.0.10/lowtrust/remove",
	} {
		rec := httptest.NewRecorder()
		testPeersServer(t).mux().ServeHTTP(rec, httptest.NewRequest(http.MethodPost, path, nil))
		if rec.Code != http.StatusSeeOther {
			t.Errorf("POST %s: status = %d, want 303", path, rec.Code)
		}
	}
}

// TestPageOmitsLowTrustBlockWhenDisabled covers the render() half: with the
// feature off the page must carry no membership state, and must not consult
// the neighbour table or nft at all — on bongo those are a fork per page load
// that can only fail.
func TestPageOmitsLowTrustBlockWhenDisabled(t *testing.T) {
	server := testPeersServerWithoutLowTrust(t)
	tmpl, err := template.New("peers.html").Parse(`{{.Device}}|{{.LowTrustEnabled}}|{{.LowTrust}}`)
	if err != nil {
		t.Fatalf("parse template: %v", err)
	}
	server.tmpl = tmpl

	rec := httptest.NewRecorder()
	server.mux().ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/peers/192.168.0.10", nil))
	if got, want := rec.Body.String(), "192.168.0.10|false|"; got != want {
		t.Fatalf("page data = %q, want %q", got, want)
	}
}

// TestPageShowsLowTrustMembership exercises the wiring inside render(): the
// handler resolves the device's MAC from the neighbour table, then asks
// lowTrust about that MAC — not the address, which is the caller's key but
// not the pool's. Both steps are injected, so this never shells out.
func TestPageShowsLowTrustMembership(t *testing.T) {
	server := testPeersServer(t)
	server.neighbours = func(context.Context) ([]byte, error) {
		return []byte("192.168.0.10 dev lan0 lladdr aa:bb:cc:dd:ee:01 REACHABLE\n"), nil
	}
	server.lowTrust = func(_ context.Context, mac string) string {
		if mac != "aa:bb:cc:dd:ee:01" {
			t.Fatalf("looked up membership for %q, want aa:bb:cc:dd:ee:01", mac)
		}
		return "temp"
	}

	rec := httptest.NewRecorder()
	server.mux().ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/peers/192.168.0.10", nil))
	if !strings.HasSuffix(rec.Body.String(), "|temp") {
		t.Fatalf("LowTrust not carried into the page data: %q", rec.Body.String())
	}
}

// TestPageOmitsLowTrustWhenMACUnknown covers a device with no neighbour-table
// entry (asleep, or the table was just flushed): lowTrust must not be asked
// about an empty MAC, and the page must not claim membership it never checked.
func TestPageOmitsLowTrustWhenMACUnknown(t *testing.T) {
	server := testPeersServer(t)
	server.neighbours = func(context.Context) ([]byte, error) { return []byte(""), nil }
	called := false
	server.lowTrust = func(context.Context, string) string { called = true; return "permanent" }

	rec := httptest.NewRecorder()
	server.mux().ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/peers/192.168.0.10", nil))
	if called {
		t.Fatal("lowTrust was consulted for a device with no MAC")
	}
	if !strings.HasSuffix(rec.Body.String(), "||") {
		t.Fatalf("LowTrust should be empty when the MAC is unknown: %q", rec.Body.String())
	}
}

func TestLowTrustBadgeHidesRemoveForPermanent(t *testing.T) {
	var buf bytes.Buffer
	tmpl := template.Must(template.ParseFiles("peers.html"))
	data := peersPageData{Device: "192.168.50.10", LowTrustEnabled: true, LowTrust: "permanent"}
	if err := tmpl.Execute(&buf, data); err != nil {
		t.Fatal(err)
	}
	body := buf.String()
	if !strings.Contains(body, "low-trust") {
		t.Error("permanent member should show the low-trust badge")
	}
	if strings.Contains(body, "/lowtrust/remove") {
		t.Error("permanent member must not offer a remove button")
	}
}

func TestLowTrustBadgeOffersRemoveForTemp(t *testing.T) {
	var buf bytes.Buffer
	tmpl := template.Must(template.ParseFiles("peers.html"))
	data := peersPageData{Device: "192.168.50.10", LowTrustEnabled: true, LowTrust: "temp"}
	if err := tmpl.Execute(&buf, data); err != nil {
		t.Fatal(err)
	}
	body := buf.String()
	if !strings.Contains(body, `action="/peers/192.168.50.10/lowtrust/remove"`) {
		t.Errorf("temp member should offer a remove button:\n%s", body)
	}
}

func TestLowTrustBadgeAbsentByDefault(t *testing.T) {
	// A pool router, device not in it: an add button and no remove button, no
	// badge text. LowTrustEnabled is what separates this from "no pool on this
	// router at all" below — the two used to share the zero value, which is how
	// bongo ended up rendering a button for drops it does not implement.
	var buf bytes.Buffer
	tmpl := template.Must(template.ParseFiles("peers.html"))
	if err := tmpl.Execute(&buf, peersPageData{Device: "192.168.50.10", LowTrustEnabled: true}); err != nil {
		t.Fatal(err)
	}
	body := buf.String()
	if !strings.Contains(body, `action="/peers/192.168.50.10/lowtrust"`) {
		t.Errorf("device not in the pool should offer to add it:\n%s", body)
	}
	if strings.Contains(body, "/lowtrust/remove") {
		t.Errorf("device not in the pool must not offer a remove button:\n%s", body)
	}
}

// TestLowTrustBlockAbsentWhenFeatureDisabled is the zero value — what every
// pre-existing template test constructs, and what bongo renders. Not one word
// of the block may appear: the routes are not registered there, so every
// control in it is a 500 waiting to be clicked.
func TestLowTrustBlockAbsentWhenFeatureDisabled(t *testing.T) {
	var buf bytes.Buffer
	tmpl := template.Must(template.ParseFiles("peers.html"))
	if err := tmpl.Execute(&buf, peersPageData{Device: "192.168.50.10"}); err != nil {
		t.Fatal(err)
	}
	body := buf.String()
	for _, unwanted := range []string{"lowtrust", "low-trust"} {
		if strings.Contains(body, unwanted) {
			t.Errorf("page mentions %q with the pool disabled:\n%s", unwanted, body)
		}
	}
	// The rest of the page is untouched by the gate.
	if !strings.Contains(body, `action="/peers/192.168.50.10/drop-all"`) {
		t.Errorf("gating the pool block took the drop-all button with it:\n%s", body)
	}
}

func TestRealTemplateRendersAllThreeActions(t *testing.T) {
	tmpl, err := template.ParseFiles("peers.html")
	if err != nil {
		t.Fatalf("parse peers.html: %v", err)
	}
	var out strings.Builder
	if err := tmpl.Execute(&out, peersPageData{
		Device: "192.168.0.10",
		Peers:  []peerRow{{Addr: "203.0.113.10", Bytes: "1 kB", SharePct: "100.0"}},
	}); err != nil {
		t.Fatalf("execute peers.html: %v", err)
	}
	body := out.String()
	for _, want := range []string{
		`action="/peers/192.168.0.10/drop"`,
		`action="/peers/192.168.0.10/throttle"`,
		`action="/peers/192.168.0.10/block"`,
		`action="/peers/192.168.0.10/drop-all"`,
	} {
		if !strings.Contains(body, want) {
			t.Fatalf("rendered page is missing %s\n%s", want, body)
		}
	}
	// Each per-row form carries the peer, or the button posts an empty address.
	// drop-all is not among them: it is device-wide and must not carry one.
	if got, want := strings.Count(body, `name="peer" value="203.0.113.10"`), 3; got != want {
		t.Fatalf("%d forms carry the peer address, want %d", got, want)
	}
}

func TestDropAllRendersWithNoPeers(t *testing.T) {
	// The button is the device's, not the table's. An idle device renders "No
	// current peers." and no table at all, and the button has to survive that —
	// a device with nothing listed is exactly when you want to reset it.
	tmpl, err := template.ParseFiles("peers.html")
	if err != nil {
		t.Fatalf("parse peers.html: %v", err)
	}
	var out strings.Builder
	if err := tmpl.Execute(&out, peersPageData{Device: "192.168.0.10"}); err != nil {
		t.Fatalf("execute peers.html: %v", err)
	}
	if !strings.Contains(out.String(), `action="/peers/192.168.0.10/drop-all"`) {
		t.Fatalf("drop-all button absent from an empty page:\n%s", out.String())
	}
}

func TestActionInvalidatesTheShapeCacheOnlyWhenItChangedSomething(t *testing.T) {
	// killconn touches no firewall state, so invalidating for it would force a
	// needless re-read of feeds running to tens of thousands of elements.
	for _, tc := range []struct {
		path string
		want int
	}{
		{"/peers/192.168.0.10/block", 2},
		{"/peers/192.168.0.10/throttle", 2},
		{"/peers/192.168.0.10/drop", 1},
	} {
		t.Run(tc.path, func(t *testing.T) {
			reads := 0
			server := testPeersServer(t)
			server.shapes = &shapeCache{
				ttl: time.Hour,
				read: func(_ context.Context, set string) ([]byte, error) {
					if set == "throttle4" {
						reads++
					}
					return nil, errors.New("absent")
				},
			}
			// Prime the cache so the count below measures re-reads.
			server.shapes.get(context.Background())

			rec := httptest.NewRecorder()
			req := httptest.NewRequest(http.MethodPost, tc.path,
				strings.NewReader("peer=203.0.113.10"))
			req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
			server.mux().ServeHTTP(rec, req)
			if rec.Code != http.StatusSeeOther {
				t.Fatalf("status = %d, want 303", rec.Code)
			}

			server.shapes.get(context.Background())
			if reads != tc.want {
				t.Fatalf("throttle4 read %d times, want %d", reads, tc.want)
			}
		})
	}
}

// testPeersServerWithCaptures is testPeersServer with a capture manager whose
// captures come from a canned stream rather than a real interface.
func testPeersServerWithCaptures(t *testing.T) *peersServer {
	t.Helper()
	server := testPeersServer(t)
	server.captures = testManager(t, pcapStream(t, binary.LittleEndian, 0xa1b2c3d4, 100, 100))
	return server
}

func postForm(path string) *http.Request {
	req := httptest.NewRequest(http.MethodPost, path, nil)
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	return req
}

func TestCaptureStartRouteRedirectsToThePage(t *testing.T) {
	server := testPeersServerWithCaptures(t)
	t.Cleanup(func() { _ = server.captures.Stop(testDevice) })

	rec := httptest.NewRecorder()
	server.mux().ServeHTTP(rec, postForm("/peers/192.168.0.10/capture/start"))

	if rec.Code != http.StatusSeeOther {
		t.Fatalf("status = %d, want 303\n%s", rec.Code, rec.Body.String())
	}
	if got := rec.Header().Get("Location"); got != "/peers/192.168.0.10" {
		t.Fatalf("Location = %q, want /peers/192.168.0.10", got)
	}
	if state := server.captures.Get(testDevice).State; state != captureRunning {
		t.Fatalf("state = %q, want %q", state, captureRunning)
	}
}

func TestCaptureStopRouteRedirectsToTheDownload(t *testing.T) {
	// One click stops and downloads: the redirect target is the file, not the
	// page. The file stays on disk so a cancelled download is still there.
	server := testPeersServerWithCaptures(t)
	if err := server.captures.Start(testDevice); err != nil {
		t.Fatalf("Start: %v", err)
	}

	rec := httptest.NewRecorder()
	server.mux().ServeHTTP(rec, postForm("/peers/192.168.0.10/capture/stop"))

	if rec.Code != http.StatusSeeOther {
		t.Fatalf("status = %d, want 303\n%s", rec.Code, rec.Body.String())
	}
	if got := rec.Header().Get("Location"); got != "/peers/192.168.0.10/capture.pcap" {
		t.Fatalf("Location = %q, want /peers/192.168.0.10/capture.pcap", got)
	}
}

func TestCaptureDownloadServesThePcapAsAnAttachment(t *testing.T) {
	server := testPeersServerWithCaptures(t)
	if err := server.captures.Start(testDevice); err != nil {
		t.Fatalf("Start: %v", err)
	}
	if err := server.captures.Stop(testDevice); err != nil {
		t.Fatalf("Stop: %v", err)
	}

	rec := httptest.NewRecorder()
	server.mux().ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/peers/192.168.0.10/capture.pcap", nil))

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200\n%s", rec.Code, rec.Body.String())
	}
	disposition := rec.Header().Get("Content-Disposition")
	if !strings.HasPrefix(disposition, `attachment; filename="192.168.0.10-`) {
		t.Fatalf("Content-Disposition = %q, want an attachment named after the device", disposition)
	}
	if !strings.HasSuffix(disposition, `.pcap"`) {
		t.Fatalf("Content-Disposition = %q, want a .pcap filename", disposition)
	}
	if got := rec.Header().Get("Content-Type"); got != "application/vnd.tcpdump.pcap" {
		t.Fatalf("Content-Type = %q, want application/vnd.tcpdump.pcap", got)
	}
	// The magic, not just a length floor: 24 arbitrary bytes or the wrong file
	// entirely would also satisfy "at least a pcap header".
	body := rec.Body.Bytes()
	if len(body) < pcapGlobalHeaderLen {
		t.Fatalf("body is %d bytes, want at least a pcap header", len(body))
	}
	if magic := binary.LittleEndian.Uint32(body[:4]); magic != 0xa1b2c3d4 {
		t.Fatalf("body magic = %#x, want the fixture's 0xa1b2c3d4", magic)
	}
}

func TestCaptureDownloadOfARunningCaptureIs409(t *testing.T) {
	// Not 404: an operator who bookmarks or reloads this URL mid-capture must
	// not be told the capture doesn't exist when the page they came from says
	// it's running.
	server := testPeersServerWithCaptures(t)
	if err := server.captures.Start(testDevice); err != nil {
		t.Fatalf("Start: %v", err)
	}
	t.Cleanup(func() { _ = server.captures.Stop(testDevice) })

	rec := httptest.NewRecorder()
	server.mux().ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/peers/192.168.0.10/capture.pcap", nil))
	if rec.Code != http.StatusConflict {
		t.Fatalf("status = %d, want 409", rec.Code)
	}
}

func TestCaptureDownloadOfNothingIs404(t *testing.T) {
	rec := httptest.NewRecorder()
	testPeersServerWithCaptures(t).mux().ServeHTTP(rec,
		httptest.NewRequest(http.MethodGet, "/peers/192.168.0.10/capture.pcap", nil))
	if rec.Code != http.StatusNotFound {
		t.Fatalf("status = %d, want 404", rec.Code)
	}
}

func TestCaptureDiscardRouteReturnsToThePage(t *testing.T) {
	server := testPeersServerWithCaptures(t)
	if err := server.captures.Start(testDevice); err != nil {
		t.Fatalf("Start: %v", err)
	}
	if err := server.captures.Stop(testDevice); err != nil {
		t.Fatalf("Stop: %v", err)
	}

	rec := httptest.NewRecorder()
	server.mux().ServeHTTP(rec, postForm("/peers/192.168.0.10/capture/discard"))

	if rec.Code != http.StatusSeeOther {
		t.Fatalf("status = %d, want 303\n%s", rec.Code, rec.Body.String())
	}
	if state := server.captures.Get(testDevice).State; state != captureIdle {
		t.Fatalf("state = %q, want %q", state, captureIdle)
	}
}

func TestCaptureRoutesRefuseCrossSiteRequests(t *testing.T) {
	for _, path := range []string{
		"/peers/192.168.0.10/capture/start",
		"/peers/192.168.0.10/capture/stop",
		"/peers/192.168.0.10/capture/discard",
	} {
		t.Run(path, func(t *testing.T) {
			req := postForm(path)
			req.Header.Set("Sec-Fetch-Site", "cross-site")
			rec := httptest.NewRecorder()
			testPeersServerWithCaptures(t).mux().ServeHTTP(rec, req)
			if rec.Code != http.StatusForbidden {
				t.Fatalf("status = %d, want 403", rec.Code)
			}
		})
	}
}

func TestCaptureDownloadRefusesCrossSiteRequests(t *testing.T) {
	// A capture is packet payloads. The download gets the same guard as the
	// buttons rather than a weaker one because it is a GET.
	req := httptest.NewRequest(http.MethodGet, "/peers/192.168.0.10/capture.pcap", nil)
	req.Header.Set("Sec-Fetch-Site", "cross-site")
	rec := httptest.NewRecorder()
	testPeersServerWithCaptures(t).mux().ServeHTTP(rec, req)
	if rec.Code != http.StatusForbidden {
		t.Fatalf("status = %d, want 403", rec.Code)
	}
}

func TestCaptureDownloadAllowsSecFetchSiteNone(t *testing.T) {
	// "none" is what a browser sends for a typed URL or a bookmark — exactly
	// how an operator reaches this route days after starting the capture — and
	// no cross-site page can produce it, unlike "cross-site" above.
	server := testPeersServerWithCaptures(t)
	if err := server.captures.Start(testDevice); err != nil {
		t.Fatalf("Start: %v", err)
	}
	if err := server.captures.Stop(testDevice); err != nil {
		t.Fatalf("Stop: %v", err)
	}

	req := httptest.NewRequest(http.MethodGet, "/peers/192.168.0.10/capture.pcap", nil)
	req.Header.Set("Sec-Fetch-Site", "none")
	rec := httptest.NewRecorder()
	server.mux().ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200 — Sec-Fetch-Site: none must not be refused", rec.Code)
	}
}

func TestCaptureRoutesRefuseADeviceOutsideTheLAN(t *testing.T) {
	for _, path := range []string{
		"/peers/203.0.113.10/capture/start",
		"/peers/203.0.113.10/capture/stop",
		"/peers/203.0.113.10/capture/discard",
	} {
		t.Run(path, func(t *testing.T) {
			rec := httptest.NewRecorder()
			testPeersServerWithCaptures(t).mux().ServeHTTP(rec, postForm(path))
			if rec.Code != http.StatusNotFound {
				t.Fatalf("status = %d, want 404", rec.Code)
			}
		})
	}
	rec := httptest.NewRecorder()
	testPeersServerWithCaptures(t).mux().ServeHTTP(rec,
		httptest.NewRequest(http.MethodGet, "/peers/203.0.113.10/capture.pcap", nil))
	if rec.Code != http.StatusNotFound {
		t.Fatalf("download status = %d, want 404", rec.Code)
	}
}

func TestCaptureStartFailureRendersTheNoticeNotAnError(t *testing.T) {
	// A failed start must leave the peers page working: the device's peers are
	// the reason the operator is on this page at all.
	server := testPeersServer(t)
	server.captures = newCaptureManager(t.TempDir(), "lan0")
	server.captures.start = func(context.Context, string, netip.Addr) (io.ReadCloser, error) {
		return nil, errors.New("tcpdump not found")
	}

	rec := httptest.NewRecorder()
	server.mux().ServeHTTP(rec, postForm("/peers/192.168.0.10/capture/start"))

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200 with a notice", rec.Code)
	}
	if !strings.Contains(rec.Body.String(), "tcpdump not found") {
		t.Fatalf("notice missing from the page: %q", rec.Body.String())
	}
	if !strings.Contains(rec.Body.String(), "203.0.113.10") {
		t.Fatalf("peer table missing from a page that failed to start a capture: %q", rec.Body.String())
	}
}

func TestCaptureRoutesAbsentWithoutAManager(t *testing.T) {
	// A router with no capture directory configured behaves exactly as it did
	// before this feature. All four routes are covered, not just start: an
	// unconditional registration of only capture.pcap would nil-deref in
	// production, and a loop that stopped at start would miss it.
	for _, path := range []string{
		"/peers/192.168.0.10/capture/start",
		"/peers/192.168.0.10/capture/stop",
		"/peers/192.168.0.10/capture/discard",
	} {
		t.Run(path, func(t *testing.T) {
			rec := httptest.NewRecorder()
			testPeersServer(t).mux().ServeHTTP(rec, postForm(path))
			if rec.Code != http.StatusNotFound {
				t.Fatalf("status = %d, want 404", rec.Code)
			}
		})
	}
	t.Run("/peers/192.168.0.10/capture.pcap", func(t *testing.T) {
		rec := httptest.NewRecorder()
		testPeersServer(t).mux().ServeHTTP(rec,
			httptest.NewRequest(http.MethodGet, "/peers/192.168.0.10/capture.pcap", nil))
		if rec.Code != http.StatusNotFound {
			t.Fatalf("status = %d, want 404", rec.Code)
		}
	})
}

func TestLANMuxHasNoCaptureRoutes(t *testing.T) {
	// The capture routes are mesh-only, like every other peers route.
	//
	// Asserted on the matched pattern, not the response status: a status check
	// would pass even if capture.pcap were mistakenly registered on this mux,
	// because handleCaptureDownload itself answers a missing file with 404 —
	// the same code a genuinely absent route produces. Handler's pattern names
	// which handler actually matched, which the handler's own response cannot
	// fake. Do not "simplify" this back to a status check.
	config := loadConfig()
	tmpl := template.Must(template.New("index").Parse("landing"))
	lan := landingMux(config, tmpl, nil)
	for _, tc := range []struct {
		method string
		path   string
	}{
		{http.MethodPost, "/peers/192.168.0.10/capture/start"},
		{http.MethodPost, "/peers/192.168.0.10/capture/stop"},
		{http.MethodPost, "/peers/192.168.0.10/capture/discard"},
		{http.MethodGet, "/peers/192.168.0.10/capture.pcap"},
	} {
		t.Run(tc.path, func(t *testing.T) {
			_, pattern := lan.Handler(httptest.NewRequest(tc.method, tc.path, nil))
			if pattern != "/" {
				t.Fatalf("landing mux matched %s with pattern %q, want the catch-all", tc.path, pattern)
			}
		})
	}
}

func TestCaptureActionsAreLogged(t *testing.T) {
	var out strings.Builder
	log.SetOutput(&out)
	t.Cleanup(func() { log.SetOutput(os.Stderr) })

	server := testPeersServerWithCaptures(t)
	server.mux().ServeHTTP(httptest.NewRecorder(), postForm("/peers/192.168.0.10/capture/start"))
	server.mux().ServeHTTP(httptest.NewRecorder(), postForm("/peers/192.168.0.10/capture/stop"))
	// The download is what actually hands packet payloads out of the router —
	// a more invasive act than any of the three above — so it gets a journal
	// line too, not just the mutations.
	server.mux().ServeHTTP(httptest.NewRecorder(),
		httptest.NewRequest(http.MethodGet, "/peers/192.168.0.10/capture.pcap", nil))

	body := out.String()
	for _, want := range []string{
		`action=capture-start peer="-" device="192.168.0.10" result="ok"`,
		`action=capture-stop peer="-" device="192.168.0.10" result="ok"`,
		`action=capture-download peer="-" device="192.168.0.10" result="ok"`,
	} {
		if !strings.Contains(body, want) {
			t.Fatalf("journal is missing %s\n%s", want, body)
		}
	}
}

func TestRealTemplateRendersTheIdleCaptureButton(t *testing.T) {
	tmpl := template.Must(template.ParseFiles("peers.html"))
	var out strings.Builder
	if err := tmpl.Execute(&out, peersPageData{
		Device:  "192.168.0.10",
		Capture: captureSlot{State: captureIdle},
	}); err != nil {
		t.Fatalf("execute peers.html: %v", err)
	}
	body := out.String()
	if !strings.Contains(body, `action="/peers/192.168.0.10/capture/start"`) {
		t.Fatalf("start button absent:\n%s", body)
	}
	for _, unwanted := range []string{"capture/stop", "capture.pcap", "capture/discard"} {
		if strings.Contains(body, unwanted) {
			t.Fatalf("idle page offers %s:\n%s", unwanted, body)
		}
	}
}

func TestRealTemplateRendersTheRunningCaptureBanner(t *testing.T) {
	tmpl := template.Must(template.ParseFiles("peers.html"))
	var out strings.Builder
	if err := tmpl.Execute(&out, peersPageData{
		Device: "192.168.0.10",
		Capture: captureSlot{
			State:   captureRunning,
			Bytes:   "12.4 MiB",
			Limit:   "200.0 MiB",
			Elapsed: "3m 12s",
		},
	}); err != nil {
		t.Fatalf("execute peers.html: %v", err)
	}
	body := out.String()
	if !strings.Contains(body, `action="/peers/192.168.0.10/capture/stop"`) {
		t.Fatalf("stop button absent:\n%s", body)
	}
	for _, want := range []string{"12.4 MiB", "200.0 MiB", "3m 12s"} {
		if !strings.Contains(body, want) {
			t.Fatalf("running banner is missing %q:\n%s", want, body)
		}
	}
	if strings.Contains(body, "capture/start") {
		t.Fatalf("running page still offers to start a capture:\n%s", body)
	}
}

func TestRealTemplateRendersTheReadyCaptureBanner(t *testing.T) {
	tmpl := template.Must(template.ParseFiles("peers.html"))
	var out strings.Builder
	if err := tmpl.Execute(&out, peersPageData{
		Device: "192.168.0.10",
		Capture: captureSlot{
			State:   captureReady,
			Bytes:   "43.1 MiB",
			Stopped: "14:02",
			Reason:  stopReasonLimit,
		},
	}); err != nil {
		t.Fatalf("execute peers.html: %v", err)
	}
	body := out.String()
	for _, want := range []string{
		`href="/peers/192.168.0.10/capture.pcap"`,
		`action="/peers/192.168.0.10/capture/discard"`,
		"43.1 MiB",
		"14:02",
		stopReasonLimit,
	} {
		if !strings.Contains(body, want) {
			t.Fatalf("ready banner is missing %q:\n%s", want, body)
		}
	}
}

func TestRealTemplateOmitsTheBannerWithoutAManager(t *testing.T) {
	// A router with no capture directory renders the page it always did.
	// Asserted on the routes rather than on the word "capture", which the
	// stylesheet carries on every render.
	tmpl := template.Must(template.ParseFiles("peers.html"))
	var out strings.Builder
	if err := tmpl.Execute(&out, peersPageData{Device: "192.168.0.10"}); err != nil {
		t.Fatalf("execute peers.html: %v", err)
	}
	for _, unwanted := range []string{
		"capture/start", "capture/stop", "capture/discard", "capture.pcap",
	} {
		if strings.Contains(out.String(), unwanted) {
			t.Fatalf("page offers %s without a manager:\n%s", unwanted, out.String())
		}
	}
}

// The device page identifies the device the way the index table does — DHCP
// name, and now the MAC alongside it. Rendered against the real peers.html so a
// template that drops either field fails here rather than on the router.
func TestDevicePageShowsDHCPNameAndMAC(t *testing.T) {
	tmpl := template.Must(template.ParseFiles("peers.html"))
	var buf bytes.Buffer
	data := peersPageData{
		Device: "192.168.0.10",
		Name:   "device-a",
		MAC:    "52:ff:a4:45:a1:7d",
	}
	if err := tmpl.Execute(&buf, data); err != nil {
		t.Fatalf("render: %v", err)
	}
	body := buf.String()
	if !strings.Contains(body, "device-a") {
		t.Error("device page did not show the DHCP name")
	}
	if !strings.Contains(body, "52:ff:a4:45:a1:7d") {
		t.Error("device page did not show the MAC")
	}
}

// A device with a static address has no lease, so both fields are empty. It
// must render the same em-dash the index table uses for a nameless lease rather
// than a blank gap or the word "unknown".
func TestDevicePageShowsDashWithoutALease(t *testing.T) {
	tmpl := template.Must(template.ParseFiles("peers.html"))
	var buf bytes.Buffer
	if err := tmpl.Execute(&buf, peersPageData{Device: "192.168.0.99"}); err != nil {
		t.Fatalf("render: %v", err)
	}
	if !strings.Contains(buf.String(), "&mdash;") && !strings.Contains(buf.String(), "—") {
		t.Error("a device with no lease showed no em-dash placeholder")
	}
}

// The page must fill those fields from the lease file, not merely be capable of
// rendering them: a handler that never looks the device up would pass the two
// template tests above and still show nothing on the router.
//
// Rendered through the REAL peers.html rather than the stub the other tests
// use, because the stub renders neither field — asserting against it would pass
// on a substring appearing elsewhere in the output and prove nothing.
func TestDevicePagePopulatesNameAndMACFromLeases(t *testing.T) {
	server := testPeersServer(t)
	real, err := template.ParseFiles("peers.html")
	if err != nil {
		t.Fatalf("parse peers.html: %v", err)
	}
	server.tmpl = real

	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/peers/192.168.0.10", nil)
	server.mux().ServeHTTP(rec, req)

	body := rec.Body.String()
	if !strings.Contains(body, "device-a") {
		t.Error("page did not carry the DHCP name from the lease file")
	}
	if !strings.Contains(body, "aa:bb:cc:dd:ee:01") {
		t.Error("page did not carry the MAC from the lease file")
	}
}

// A device with a lease but no hostname must still show its MAC — the MAC is
// the value someone needs, and dnsmasq's "*" for a nameless device must not
// suppress it.
func TestDevicePageShowsMACForNamelessLease(t *testing.T) {
	server := testPeersServer(t)
	real, err := template.ParseFiles("peers.html")
	if err != nil {
		t.Fatalf("parse peers.html: %v", err)
	}
	server.tmpl = real

	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/peers/192.168.0.20", nil)
	server.mux().ServeHTTP(rec, req)

	if !strings.Contains(rec.Body.String(), "aa:bb:cc:dd:ee:02") {
		t.Error("a nameless lease lost its MAC on the page")
	}
}
