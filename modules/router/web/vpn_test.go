package main

import (
	"encoding/json"
	"html/template"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"
)

func testVPNService(t *testing.T) *vpnService {
	t.Helper()

	dir := t.TempDir()
	// Created by tmpfiles on a real router, with the group ownership that is
	// the whole of router-web's privilege here. Created up front in the test
	// too, because "the file already exists and is not ours" is the case
	// setDesired has to keep working in.
	if err := os.WriteFile(filepath.Join(dir, vpnDesiredFile), []byte("off\n"), 0o660); err != nil {
		t.Fatalf("seed switch: %v", err)
	}

	tmpl, err := template.ParseFiles("vpn.html", "nav.html")
	if err != nil {
		t.Fatalf("parse vpn.html: %v", err)
	}

	service := newVPNService(dir, tmpl)
	// The real budget is seconds, which would make every settling test take
	// them. The behaviour under test is "waits, then gives up", not how long.
	service.settle, service.poll = 100*time.Millisecond, 5*time.Millisecond
	return service
}

func writeReport(t *testing.T, service *vpnService, status vpnStatus) {
	t.Helper()
	raw, err := json.Marshal(status)
	if err != nil {
		t.Fatalf("marshal report: %v", err)
	}
	if err := os.WriteFile(service.statusPath(), raw, 0o640); err != nil {
		t.Fatalf("write report: %v", err)
	}
}

// Everything that is not exactly "on" has to read as off, because the same rule
// is written twice — here and in read_desired in vpn.bash — and a disagreement
// between them is a page claiming a tunnel is up that the reconciler has taken
// down, or worse, the reverse.
func TestSwitchReadsOffUnlessItSaysOn(t *testing.T) {
	service := testVPNService(t)

	for _, test := range []struct {
		name    string
		content string
		want    string
	}{
		{"on", "on\n", vpnOn},
		{"on without a newline", "on", vpnOn},
		{"off", "off\n", vpnOff},
		{"empty", "", vpnOff},
		{"half written", "o", vpnOff},
		{"nonsense", "yes please\n", vpnOff},
	} {
		t.Run(test.name, func(t *testing.T) {
			if err := os.WriteFile(service.desiredPath(), []byte(test.content), 0o660); err != nil {
				t.Fatalf("write switch: %v", err)
			}
			if got := service.desired(); got != test.want {
				t.Errorf("desired() = %q, want %q", got, test.want)
			}
		})
	}

	t.Run("missing file", func(t *testing.T) {
		if err := os.Remove(service.desiredPath()); err != nil {
			t.Fatalf("remove switch: %v", err)
		}
		if got := service.desired(); got != vpnOff {
			t.Errorf("desired() = %q with no file at all, want %q", got, vpnOff)
		}
	})
}

// The path unit that wakes the reconciler watches this file for a
// close-after-write. A rename would arrive as a directory event it does not
// watch, so the switch would be flipped and nothing would happen until the
// timer noticed a minute later — and the file would lose the group ownership
// that lets this process write it at all.
func TestSwitchIsRewrittenInPlaceNotReplaced(t *testing.T) {
	service := testVPNService(t)

	before, err := os.Stat(service.desiredPath())
	if err != nil {
		t.Fatalf("stat switch: %v", err)
	}

	if err := service.setDesired(vpnOn); err != nil {
		t.Fatalf("setDesired: %v", err)
	}

	after, err := os.Stat(service.desiredPath())
	if err != nil {
		t.Fatalf("stat switch: %v", err)
	}
	if before.Sys().(*syscall.Stat_t).Ino != after.Sys().(*syscall.Stat_t).Ino {
		t.Error("the switch file was replaced, not rewritten: the path unit will not see the change")
	}
	if got := service.desired(); got != vpnOn {
		t.Errorf("desired() = %q after setDesired(on)", got)
	}
}

// The report is a contract between two programs written in two languages: the
// reconciler (vpn.bash) builds this document with jq, and this file parses it.
// The fixture below is real output from that script, pasted verbatim, so a
// field renamed on either side fails here rather than showing up as a page that
// silently reports an empty name and an unknown key.
func TestReportParsesWhatTheReconcilerWrites(t *testing.T) {
	service := testVPNService(t)
	const fixture = `{
  "enabled": true,
  "interface": "wg0",
  "port": 51820,
  "address": "10.30.0.1/24",
  "publicKey": "K7cQ1ZbYtBqRZ2sYq0Ry5r7tQnUu2Wc9Fp3vX8mAoDs=",
  "peers": 2,
  "label": "x7k2",
  "fqdn": "x7k2.huma.id",
  "recordId": "abc-123",
  "publicAddress": "217.164.1.2",
  "updated": "2026-08-16T09:18:19Z",
  "note": ""
}`
	if err := os.WriteFile(service.statusPath(), []byte(fixture), 0o640); err != nil {
		t.Fatalf("write report: %v", err)
	}

	status, err := service.status()
	if err != nil {
		t.Fatalf("status(): %v", err)
	}
	for _, field := range []struct {
		name      string
		got, want any
	}{
		{"enabled", status.Enabled, true},
		{"interface", status.Interface, "wg0"},
		{"port", status.Port, 51820},
		{"address", status.Address, "10.30.0.1/24"},
		{"publicKey", status.PublicKey, "K7cQ1ZbYtBqRZ2sYq0Ry5r7tQnUu2Wc9Fp3vX8mAoDs="},
		{"peers", status.Peers, 2},
		{"label", status.Label, "x7k2"},
		{"fqdn", status.FQDN, "x7k2.huma.id"},
		{"recordId", status.RecordID, "abc-123"},
		{"publicAddress", status.PublicAddress, "217.164.1.2"},
	} {
		if field.got != field.want {
			t.Errorf("%s = %v, want %v", field.name, field.got, field.want)
		}
	}

	// And the timestamp is in the format the page dates the report with. A
	// report that cannot be dated renders no age at all, which reads as a
	// reconciler that has never run.
	if err := service.setDesired(vpnOn); err != nil {
		t.Fatalf("setDesired: %v", err)
	}
	if service.page(navSource{}).Reported == "" {
		t.Error("the report's timestamp did not parse as RFC 3339")
	}
}

func TestReportMissingIsNotAnError(t *testing.T) {
	// What a router that has never had the tunnel switched on looks like. It
	// must not render an error banner: nothing is wrong.
	service := testVPNService(t)
	status, err := service.status()
	if err != nil {
		t.Fatalf("status() with no report = %v", err)
	}
	if status.Enabled {
		t.Error("no report at all reported an enabled tunnel")
	}
}

func TestPageReportsSettlingWhileTheSwitchAndTheReportDisagree(t *testing.T) {
	service := testVPNService(t)

	// Switched on, reconciler has not caught up. This is the state a reader is
	// most likely to see immediately after pressing the button, and the one
	// where saying "up" would be a lie.
	if err := service.setDesired(vpnOn); err != nil {
		t.Fatalf("setDesired: %v", err)
	}
	data := service.page(navSource{})
	if !data.Settling {
		t.Error("switch on with no report did not report settling")
	}
	if data.State != "settling" || !strings.Contains(data.StateText, "on") {
		t.Errorf("band = %q / %q, want the switching-on band", data.State, data.StateText)
	}

	writeReport(t, service, vpnStatus{Enabled: true, Port: 51820, FQDN: "x7k2.example.net"})
	data = service.page(navSource{})
	if data.Settling {
		t.Error("still settling once the report agrees")
	}
	if data.State != "on" {
		t.Errorf("band = %q, want on", data.State)
	}

	// And the other direction: switched off, tunnel still up.
	if err := service.setDesired(vpnOff); err != nil {
		t.Fatalf("setDesired: %v", err)
	}
	data = service.page(navSource{})
	if !data.Settling || !strings.Contains(data.StateText, "off") {
		t.Errorf("band = %q / %q, want the switching-off band", data.State, data.StateText)
	}
}

func TestEndpointPrefersTheEphemeralName(t *testing.T) {
	service := testVPNService(t)
	if err := service.setDesired(vpnOn); err != nil {
		t.Fatalf("setDesired: %v", err)
	}

	writeReport(t, service, vpnStatus{
		Enabled: true, Port: 51820,
		FQDN: "x7k2.example.net", PublicAddress: "203.0.113.7",
	})
	if got := service.page(navSource{}).Endpoint; got != "x7k2.example.net:51820" {
		t.Errorf("endpoint = %q, want the name", got)
	}

	// No zone configured, so there is no name. The address is still something
	// a client can be pointed at, and an empty endpoint would read as the
	// tunnel being unreachable rather than merely unnamed.
	writeReport(t, service, vpnStatus{Enabled: true, Port: 51820, PublicAddress: "203.0.113.7"})
	if got := service.page(navSource{}).Endpoint; got != "203.0.113.7:51820" {
		t.Errorf("endpoint = %q, want the address", got)
	}

	// Switched off: nothing to point anything at.
	writeReport(t, service, vpnStatus{Enabled: false})
	if got := service.page(navSource{}).Endpoint; got != "" {
		t.Errorf("endpoint = %q with the tunnel off, want empty", got)
	}
}

// The port this opens faces the internet, which makes it the most valuable
// mutation on the listener — and the only one a cross-site page could aim at
// without first knowing a device address.
func TestSwitchRefusesCrossSiteRequests(t *testing.T) {
	service := testVPNService(t)
	mux := http.NewServeMux()
	service.registerRoutes(mux)

	for _, path := range []string{"/vpn/enable", "/vpn/disable"} {
		t.Run(path, func(t *testing.T) {
			request := httptest.NewRequest(http.MethodPost, path, nil)
			request.Header.Set("Sec-Fetch-Site", "cross-site")
			recorder := httptest.NewRecorder()
			mux.ServeHTTP(recorder, request)

			if recorder.Code != http.StatusForbidden {
				t.Errorf("status = %d, want 403", recorder.Code)
			}
			if got := service.desired(); got != vpnOff {
				t.Errorf("the switch moved to %q on a refused request", got)
			}
		})
	}
}

func TestSwitchFlipsAndRedirectsToThePage(t *testing.T) {
	service := testVPNService(t)
	mux := http.NewServeMux()
	service.registerRoutes(mux)

	recorder := httptest.NewRecorder()
	mux.ServeHTTP(recorder, httptest.NewRequest(http.MethodPost, "/vpn/enable", nil))

	if recorder.Code != http.StatusSeeOther {
		t.Fatalf("status = %d, want 303", recorder.Code)
	}
	if got := recorder.Header().Get("Location"); got != "/vpn" {
		t.Errorf("redirect to %q, want /vpn", got)
	}
	if got := service.desired(); got != vpnOn {
		t.Errorf("switch = %q after enable", got)
	}

	recorder = httptest.NewRecorder()
	mux.ServeHTTP(recorder, httptest.NewRequest(http.MethodPost, "/vpn/disable", nil))
	if got := service.desired(); got != vpnOff {
		t.Errorf("switch = %q after disable", got)
	}
}

// The wait is what makes the redirect land on a page showing the new state
// rather than on one that still says the old one. It has to end as soon as the
// reconciler catches up, not run out its budget every time.
func TestSettleReturnsAsSoonAsTheReportAgrees(t *testing.T) {
	service := testVPNService(t)
	service.settle, service.poll = 5*time.Second, 5*time.Millisecond

	go func() {
		time.Sleep(20 * time.Millisecond)
		raw, _ := json.Marshal(vpnStatus{Enabled: true})
		_ = os.WriteFile(service.statusPath(), raw, 0o640)
	}()

	start := time.Now()
	service.settleFor(true)
	if elapsed := time.Since(start); elapsed >= time.Second {
		t.Errorf("waited %s for a report that arrived in 20ms", elapsed)
	}
}

func TestSettleGivesUpRatherThanHanging(t *testing.T) {
	// A reconcile that never finishes must not hold the request open: the page
	// it redirects to says "settling" perfectly well on its own.
	service := testVPNService(t)
	start := time.Now()
	service.settleFor(true)
	if elapsed := time.Since(start); elapsed > 2*time.Second {
		t.Errorf("settleFor blocked for %s", elapsed)
	}
}

// The listener split is a security boundary; see muxsplit_test.go for the peer
// routes it was written for. The tunnel switch belongs on the same side of it:
// the LAN is the household, and the household does not open ports to the
// internet.
func TestLANListenerServesNoTunnelRoute(t *testing.T) {
	tmpl, err := template.ParseFiles("index.html", "nav.html")
	if err != nil {
		t.Fatalf("parse index.html: %v", err)
	}
	// The LAN mux is built from the same nav source the mesh one is, tunnel
	// service and all. Registration, not a nil check, is what has to keep it
	// off this listener.
	nav := navSource{vpn: testVPNService(t)}
	lan := landingMux(pageData{}, tmpl, nil, nil, nil, nav)

	for _, route := range []struct{ method, path string }{
		{http.MethodGet, "/vpn"},
		{http.MethodPost, "/vpn/enable"},
		{http.MethodPost, "/vpn/disable"},
	} {
		t.Run(route.method+" "+route.path, func(t *testing.T) {
			recorder := httptest.NewRecorder()
			lan.ServeHTTP(recorder, httptest.NewRequest(route.method, route.path, nil))
			if recorder.Code != http.StatusNotFound {
				t.Errorf("status = %d, want 404: the tunnel switch is reachable from the LAN", recorder.Code)
			}
		})
	}

	// And the strip does not offer what the listener will not serve.
	recorder := httptest.NewRecorder()
	lan.ServeHTTP(recorder, httptest.NewRequest(http.MethodGet, "/", nil))
	if strings.Contains(recorder.Body.String(), `href="/vpn"`) {
		t.Error("the LAN status page links to the tunnel switch")
	}
}

func TestMeshListenerServesTheTunnelSwitch(t *testing.T) {
	tmpl, err := template.ParseFiles("index.html", "nav.html")
	if err != nil {
		t.Fatalf("parse index.html: %v", err)
	}
	service := testVPNService(t)
	nav := navSource{host: "bongo", vpn: service}
	service.nav = nav
	mesh := meshMux(pageData{}, tmpl, nil, nil, nil, testPeersServer(t), nav)

	recorder := httptest.NewRecorder()
	mesh.ServeHTTP(recorder, httptest.NewRequest(http.MethodGet, "/vpn", nil))
	if recorder.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200", recorder.Code)
	}
	body := recorder.Body.String()
	if !strings.Contains(body, "/vpn/enable") {
		t.Error("the tunnel page offers no way to switch it on")
	}
	// The strip, so the page is not a dead end reachable only by typing it.
	if !strings.Contains(body, `href="/peers"`) {
		t.Error("the tunnel page does not carry the shared navigation")
	}
}

// A router without the feature keeps every route and every pixel it had before
// it existed.
func TestNoTunnelDirectoryMeansNoFeature(t *testing.T) {
	t.Setenv("ROUTER_VPN_DIR", "")
	if service := startVPN("."); service != nil {
		t.Fatal("the tunnel service started with no state directory configured")
	}

	nav := navSource{host: "bongo"}.data("status", true)
	if nav.ShowVPN {
		t.Error("the strip offers the tunnel on a router that has none")
	}
}

// The entry follows the routes: mesh only, and only where the feature exists.
func TestStripOffersTheTunnelOnlyWhereItWorks(t *testing.T) {
	service := testVPNService(t)

	if nav := (navSource{vpn: service}).data("status", false); nav.ShowVPN {
		t.Error("the LAN strip offers the tunnel switch")
	}
	if nav := (navSource{vpn: service}).data("vpn", true); !nav.ShowVPN {
		t.Error("the mesh strip hides a tunnel switch that is configured")
	}

	body := renderNav(t, navData{Host: "bongo", State: stateOK, Active: "vpn", ShowPeers: true, ShowVPN: true})
	if !strings.Contains(body, `href="/vpn"`) {
		t.Error("the strip does not link the tunnel page")
	}
	if got := strings.Count(body, `aria-current="page"`); got != 1 {
		t.Errorf("active vpn marked %d entries current, want 1", got)
	}
}
