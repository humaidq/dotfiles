package main

import (
	"html/template"
	"net/http"
	"net/http/httptest"
	"net/netip"
	"strings"
	"testing"
)

// The listener split is a security boundary, not a layout choice: the LAN is
// the household, and the peers pages both name every device and expose buttons
// that change the firewall. These tests are the enforcement — the route lists
// live in two functions precisely so that this can assert on the difference.

// Every route that can see or change a device. A new one added to
// peers.registerRoutes without being added here is not tested against the LAN,
// so this list is deliberately exhaustive rather than a sample.
var peerRoutes = []struct {
	method string
	path   string
}{
	{http.MethodGet, "/peers"},
	{http.MethodGet, "/peers/"},
	{http.MethodGet, "/peers/192.168.0.10"},
	{http.MethodPost, "/peers/192.168.0.10/throttle"},
	{http.MethodPost, "/peers/192.168.0.10/block"},
	{http.MethodPost, "/peers/192.168.0.10/drop"},
	{http.MethodPost, "/peers/192.168.0.10/drop-all"},
	{http.MethodPost, "/peers/192.168.0.10/lowtrust"},
	{http.MethodPost, "/peers/192.168.0.10/lowtrust/remove"},
	{http.MethodPost, "/peers/192.168.0.10/capture/start"},
	{http.MethodPost, "/peers/192.168.0.10/capture/stop"},
	{http.MethodPost, "/peers/192.168.0.10/capture/discard"},
	{http.MethodGet, "/peers/192.168.0.10/capture.pcap"},
}

func TestLANListenerServesNoPeerRoute(t *testing.T) {
	tmpl, err := template.ParseFiles("index.html", "nav.html")
	if err != nil {
		t.Fatalf("parse index.html: %v", err)
	}
	lan := landingMux(pageData{}, tmpl, nil, nil, navSource{})

	for _, route := range peerRoutes {
		t.Run(route.method+" "+route.path, func(t *testing.T) {
			rec := httptest.NewRecorder()
			lan.ServeHTTP(rec, httptest.NewRequest(route.method, route.path, nil))
			if rec.Code != http.StatusNotFound {
				t.Errorf("status = %d, want 404: this route is reachable from the LAN", rec.Code)
			}
		})
	}
}

func TestMeshListenerServesStatusAndPeers(t *testing.T) {
	indexTmpl, err := template.ParseFiles("index.html", "nav.html")
	if err != nil {
		t.Fatalf("parse index.html: %v", err)
	}
	peers := testPeersServer(t)
	mesh := meshMux(pageData{}, indexTmpl, nil, nil, peers, navSource{})

	// The status page, which is the whole point of the change: it used to be
	// LAN-only, and the mesh is what is reachable when the LAN is not.
	rec := httptest.NewRecorder()
	mesh.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/", nil))
	if rec.Code != http.StatusOK {
		t.Fatalf("status page on the mesh = %d, want 200", rec.Code)
	}
	if !strings.Contains(rec.Body.String(), "Gateway Status") {
		t.Error("mesh root did not render the status page")
	}
	// And it offers the link, which the LAN copy must not.
	if !strings.Contains(rec.Body.String(), `href="/peers"`) {
		t.Error("mesh status page does not link to the peers list")
	}

	// The peers list, moved off the root to make room for it.
	rec = httptest.NewRecorder()
	mesh.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/peers", nil))
	if rec.Code != http.StatusOK {
		t.Errorf("peers index on the mesh = %d, want 200", rec.Code)
	}

	rec = httptest.NewRecorder()
	mesh.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/peers/192.168.0.10", nil))
	if rec.Code != http.StatusOK {
		t.Errorf("device page on the mesh = %d, want 200", rec.Code)
	}
}

func TestLANStatusPageOffersNoPeersLink(t *testing.T) {
	// A link that 404s is worse than no link: it reads as the page being
	// broken rather than as the route being deliberately elsewhere.
	tmpl, err := template.ParseFiles("index.html", "nav.html")
	if err != nil {
		t.Fatalf("parse index.html: %v", err)
	}

	rec := httptest.NewRecorder()
	landingMux(pageData{}, tmpl, nil, nil, navSource{}).ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/", nil))
	if strings.Contains(rec.Body.String(), `href="/peers"`) {
		t.Error("LAN status page links to a route it does not serve")
	}
}

func TestPeersIndexRejectsOtherPaths(t *testing.T) {
	// The handler keeps its own path guard in case the registered pattern is
	// ever loosened to a prefix, which would make it the catch-all for
	// everything under /peers.
	rec := httptest.NewRecorder()
	testPeersServer(t).handleIndex(rec, httptest.NewRequest(http.MethodGet, "/peers/nonsense", nil))
	if rec.Code != http.StatusNotFound {
		t.Errorf("status = %d, want 404", rec.Code)
	}
}

func TestMeshStatusRoutesIncludeUplink(t *testing.T) {
	// The reason this change was made: the uplink history was LAN-only, and
	// the LAN is not reachable from the other site.
	store := newTestStore(t)
	service := newTestService(t, store, seededTargets()...)
	service.prober.pppLocal = netip.MustParseAddr("217.164.183.46")

	indexTmpl, err := template.ParseFiles("index.html", "nav.html")
	if err != nil {
		t.Fatalf("parse index.html: %v", err)
	}
	mesh := meshMux(pageData{}, indexTmpl, service, nil, testPeersServer(t), navSource{})

	for _, path := range []string{"/uplink", "/metrics"} {
		rec := httptest.NewRecorder()
		mesh.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, path, nil))
		if rec.Code != http.StatusOK {
			t.Errorf("%s on the mesh = %d, want 200", path, rec.Code)
		}
	}
}

// realTemplatePeersServer swaps the stub templates the other tests use for the
// files actually shipped, which is the only way to assert on what a page
// really renders rather than on what a fixture chose to include.
func realTemplatePeersServer(t *testing.T) *peersServer {
	t.Helper()

	server := testPeersServer(t)

	tmpl, err := template.ParseFiles("peers.html", "nav.html")
	if err != nil {
		t.Fatalf("parse peers.html: %v", err)
	}
	indexTmpl, err := template.ParseFiles("peers-index.html", "nav.html")
	if err != nil {
		t.Fatalf("parse peers-index.html: %v", err)
	}
	server.tmpl, server.indexTmpl = tmpl, indexTmpl
	return server
}

func TestNavigationBetweenPages(t *testing.T) {
	// Every page reachable on the mesh links back to the ones above it. The
	// device page is the one that matters: it is usually arrived at from the
	// list, and without a link back the only way out is editing the URL.
	peers := realTemplatePeersServer(t)

	t.Run("device page links to the list", func(t *testing.T) {
		rec := httptest.NewRecorder()
		peers.mux().ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/peers/192.168.0.10", nil))
		if rec.Code != http.StatusOK {
			t.Fatalf("status = %d, want 200", rec.Code)
		}
		body := rec.Body.String()
		if !strings.Contains(body, `href="/peers"`) {
			t.Error("device page has no link back to the device list")
		}
		if !strings.Contains(body, `href="/"`) {
			t.Error("device page has no link back to the status page")
		}
	})

	t.Run("list links to the status page", func(t *testing.T) {
		rec := httptest.NewRecorder()
		peers.mux().ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/peers", nil))
		if rec.Code != http.StatusOK {
			t.Fatalf("status = %d, want 200", rec.Code)
		}
		if !strings.Contains(rec.Body.String(), `href="/"`) {
			t.Error("device list has no link back to the status page")
		}
	})
}
