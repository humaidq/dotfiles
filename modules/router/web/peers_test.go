package main

import (
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
		`{{.Device}}|{{range .Peers}}{{.Addr}},{{.ASN}},{{.Org}},{{.Country}},{{.SharePct}},{{.Shape}};{{end}}|{{.Error}}`)
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
	lan := landingMux(pageData{}, tmpl)

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
	testPeersServer(t).mux().ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/", nil))

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
	server.mux().ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/", nil))

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
	landingMux(pageData{}, tmpl).ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/peers/192.168.0.10", nil))
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
	server.mux().ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/", nil))
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
	server.mux().ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/", nil))
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
	server.mux().ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/", nil))
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
	if rec.Body.Len() < pcapGlobalHeaderLen {
		t.Fatalf("body is %d bytes, want at least a pcap header", rec.Body.Len())
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
	// before this feature.
	server := testPeersServer(t)
	rec := httptest.NewRecorder()
	server.mux().ServeHTTP(rec, postForm("/peers/192.168.0.10/capture/start"))
	if rec.Code != http.StatusNotFound {
		t.Fatalf("status = %d, want 404", rec.Code)
	}
}

func TestLANMuxHasNoCaptureRoutes(t *testing.T) {
	// The capture routes are mesh-only, like every other peers route.
	config := loadConfig()
	tmpl := template.Must(template.New("index").Parse("landing"))
	lan := landingMux(config, tmpl)
	for _, path := range []string{
		"/peers/192.168.0.10/capture/start",
		"/peers/192.168.0.10/capture.pcap",
	} {
		rec := httptest.NewRecorder()
		lan.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, path, nil))
		if rec.Code != http.StatusNotFound {
			t.Fatalf("landing mux answered %s with %d, want 404", path, rec.Code)
		}
	}
}

func TestCaptureActionsAreLogged(t *testing.T) {
	var out strings.Builder
	log.SetOutput(&out)
	t.Cleanup(func() { log.SetOutput(os.Stderr) })

	server := testPeersServerWithCaptures(t)
	server.mux().ServeHTTP(httptest.NewRecorder(), postForm("/peers/192.168.0.10/capture/start"))
	server.mux().ServeHTTP(httptest.NewRecorder(), postForm("/peers/192.168.0.10/capture/stop"))

	body := out.String()
	for _, want := range []string{
		`action=capture-start peer="-" device="192.168.0.10" result="ok"`,
		`action=capture-stop peer="-" device="192.168.0.10" result="ok"`,
	} {
		if !strings.Contains(body, want) {
			t.Fatalf("journal is missing %s\n%s", want, body)
		}
	}
}
