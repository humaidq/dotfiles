package main

import (
	"context"
	"errors"
	"html/template"
	"log"
	"net/http"
	"net/http/httptest"
	"net/netip"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

var errFake = errors.New("conntrack unavailable")

func testPeersServer(t *testing.T) *peersServer {
	t.Helper()
	tmpl, err := template.New("peers.html").Parse(
		`{{.Device}}|{{range .Peers}}{{.Addr}},{{.ASN}},{{.Org}},{{.Country}},{{.SharePct}};{{end}}|{{.Error}}`)
	if err != nil {
		t.Fatalf("parse template: %v", err)
	}
	table, err := LoadASNTable(writeTSV(t,
		"203.0.113.0\t203.0.113.255\t64496\tNL\tExample Hosting\n"))
	if err != nil {
		t.Fatalf("LoadASNTable: %v", err)
	}
	indexTmpl, err := template.New("peers-index.html").Parse(
		`{{range .Leases}}{{.Addr}}={{.Name}};{{end}}|{{.Error}}`)
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
