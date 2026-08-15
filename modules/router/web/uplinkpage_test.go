package main

import (
	"html/template"
	"net/http"
	"net/http/httptest"
	"net/netip"
	"strings"
	"testing"
	"time"
)

// newTestService assembles the read side without opening a raw socket, which a
// test process has no capability for. The prober is built by hand rather than
// through newUplinkProber for the same reason.
func newTestService(t *testing.T, store *uplinkStore, targets ...*uplinkTarget) *uplinkService {
	t.Helper()

	tmpl, err := template.ParseFiles("uplink.html")
	if err != nil {
		t.Fatalf("parse uplink.html: %v", err)
	}

	prober := &uplinkProber{
		store:    store,
		pppIface: "ppp0",
		targets:  targets,
		byID:     map[uint16]*uplinkTarget{},
		pppLocal: netip.MustParseAddr("217.164.183.46"),
		pppPeer:  netip.MustParseAddr("217.164.182.1"),
	}
	return &uplinkService{store: store, prober: prober, tmpl: tmpl, retention: 90 * 24 * time.Hour}
}

func seededTargets() []*uplinkTarget {
	peer := &uplinkTarget{
		anchor:  anchor{Name: peerTargetName, Role: rolePeer, Tin: tinBestEffort},
		addr:    netip.MustParseAddr("217.164.182.1"),
		pending: map[uint16]pendingProbe{},
		buckets: map[int64]*minuteBucket{},
		lastOK:  true,
		lastRTT: 900 * time.Microsecond,
	}
	core := &uplinkTarget{
		anchor:  anchor{Name: "cloudflare", Role: roleCore, Tin: tinBestEffort},
		addr:    netip.MustParseAddr("1.1.1.1"),
		pending: map[uint16]pendingProbe{},
		buckets: map[int64]*minuteBucket{},
		lastOK:  true,
		lastRTT: 5200 * time.Microsecond,
	}
	transit := &uplinkTarget{
		anchor:  anchor{Name: "lighthouse", Role: roleTransit, Tin: tinBestEffort},
		addr:    netip.MustParseAddr("139.84.173.48"),
		pending: map[uint16]pendingProbe{},
		buckets: map[int64]*minuteBucket{},
		lastOK:  false,
		lostRun: 4,
	}
	return []*uplinkTarget{peer, core, transit}
}

// The template is parsed from a file and executed against a struct, so a
// renamed field is a runtime error on a page that is only ever opened when
// something is already wrong. This is the test that catches it.
func TestUplinkPageRenders(t *testing.T) {
	store := newTestStore(t)
	now := time.Now().Truncate(time.Minute)

	for i := range 30 {
		ts := now.Add(-time.Duration(30-i) * time.Minute)
		if err := store.writeMinute(minuteRow{
			TS: ts, Target: "cloudflare", Role: roleCore, Address: "1.1.1.1",
			Sent: 60, Received: 60, RTTMin: 4.7, RTTP50: 5.2, RTTP95: 5.9, RTTMax: 6.8,
			Jitter: 0.4, DownPeak: 2_000_000, UpPeak: 400_000,
		}); err != nil {
			t.Fatalf("seed: %v", err)
		}
	}
	if _, err := store.appendEvent(uplinkEvent{
		TS: now.Add(-2 * time.Hour), Kind: eventPPPDown, Target: "ppp0", Detail: "no address on the interface",
	}); err != nil {
		t.Fatalf("seed event: %v", err)
	}

	service := newTestService(t, store, seededTargets()...)

	recorder := httptest.NewRecorder()
	service.handlePage(recorder, httptest.NewRequest(http.MethodGet, "/uplink", nil))

	if recorder.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200", recorder.Code)
	}
	body := recorder.Body.String()

	// A template that failed halfway through still returns 200 with a
	// truncated body, so the closing tag is the real assertion.
	if !strings.Contains(body, "</html>") {
		t.Fatalf("page truncated, probably a template error:\n%s", body)
	}
	for _, want := range []string{
		"cloudflare", "lighthouse", peerTargetName,
		"5.20 ms",                     // the median, at the precision the link deserves
		"no address on the interface", // the event log
		"reachability only",           // the peer's caveat, which the page must state
		"<polyline",                   // the sparkline drew something
	} {
		if !strings.Contains(body, want) {
			t.Errorf("page is missing %q", want)
		}
	}
}

func TestUplinkPageRendersWithNoHistory(t *testing.T) {
	// The first render after deploy happens before any minute has been
	// written, and it must not be an error page.
	store := newTestStore(t)
	service := newTestService(t, store, seededTargets()...)

	recorder := httptest.NewRecorder()
	service.handlePage(recorder, httptest.NewRequest(http.MethodGet, "/uplink", nil))

	if recorder.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200", recorder.Code)
	}
	if !strings.Contains(recorder.Body.String(), "</html>") {
		t.Fatal("page truncated with an empty store")
	}
	if !strings.Contains(recorder.Body.String(), "Nothing recorded.") {
		t.Error("empty tables did not render their placeholder")
	}
}

func TestUplinkPageRejectsOtherPaths(t *testing.T) {
	service := newTestService(t, newTestStore(t))

	recorder := httptest.NewRecorder()
	service.handlePage(recorder, httptest.NewRequest(http.MethodGet, "/uplink/../secrets", nil))
	if recorder.Code != http.StatusNotFound {
		t.Errorf("status = %d, want 404", recorder.Code)
	}
}

func TestLandingBandRenders(t *testing.T) {
	// The band is injected into the landing page, which predates this feature
	// and has to keep rendering with and without it.
	tmpl, err := template.ParseFiles("index.html")
	if err != nil {
		t.Fatalf("parse index.html: %v", err)
	}

	store := newTestStore(t)
	now := time.Now().Truncate(time.Minute)
	if err := store.writeMinute(minuteRow{
		TS: now.Add(-time.Minute), Target: "cloudflare", Role: roleCore, Address: "1.1.1.1",
		Sent: 60, Received: 60, RTTMin: 4.7, RTTP50: 5.2, RTTP95: 5.9, RTTMax: 6.8, Jitter: 0.4,
	}); err != nil {
		t.Fatalf("seed: %v", err)
	}
	service := newTestService(t, store, seededTargets()...)

	t.Run("with a band", func(t *testing.T) {
		recorder := httptest.NewRecorder()
		landingMux(pageData{}, tmpl, service).ServeHTTP(recorder,
			httptest.NewRequest(http.MethodGet, "/", nil))

		body := recorder.Body.String()
		if !strings.Contains(body, "uplink-ok") {
			t.Errorf("band did not render as healthy:\n%s", body)
		}
		if !strings.Contains(body, `href="/uplink"`) {
			t.Error("band has no link to the detail page")
		}
	})

	t.Run("without one", func(t *testing.T) {
		recorder := httptest.NewRecorder()
		landingMux(pageData{}, tmpl, nil).ServeHTTP(recorder,
			httptest.NewRequest(http.MethodGet, "/", nil))

		body := recorder.Body.String()
		if !strings.Contains(body, "Gateway Status") {
			t.Fatal("landing page did not render without a band")
		}
		// Not an empty band with em dashes, which would read as a fault. The
		// class names alone are always present in the stylesheet, so the
		// assertion is on the element that carries them.
		if strings.Contains(body, `class="uplink uplink-`) {
			t.Error("band rendered on a router with no probing configured")
		}
	})
}

func TestUplinkRoutesOnlyExistWhenConfigured(t *testing.T) {
	tmpl, err := template.ParseFiles("index.html")
	if err != nil {
		t.Fatalf("parse index.html: %v", err)
	}

	// A /metrics that answers with an empty body would be scraped happily and
	// recorded as zero, which is worse than not answering.
	for _, path := range []string{"/uplink", "/metrics"} {
		recorder := httptest.NewRecorder()
		landingMux(pageData{}, tmpl, nil).ServeHTTP(recorder,
			httptest.NewRequest(http.MethodGet, path, nil))
		if recorder.Code != http.StatusNotFound {
			t.Errorf("%s status = %d without probing configured, want 404", path, recorder.Code)
		}
	}
}

func TestMetricsExport(t *testing.T) {
	store := newTestStore(t)
	now := time.Now().Truncate(time.Minute)
	if err := store.writeMinute(minuteRow{
		TS: now.Add(-time.Minute), Target: "cloudflare", Role: roleCore, Address: "1.1.1.1",
		Sent: 60, Received: 59, RTTMin: 4.7, RTTP50: 5.2, RTTP95: 5.9, RTTMax: 6.8,
		Jitter: 0.4, DownPeak: 100_000_000, UpPeak: 20_000_000,
	}); err != nil {
		t.Fatalf("seed: %v", err)
	}

	targets := seededTargets()
	targets[1].sentTotal = 3600
	targets[1].receivedTotal = 3599
	service := newTestService(t, store, targets...)

	recorder := httptest.NewRecorder()
	service.handleMetrics(recorder, httptest.NewRequest(http.MethodGet, "/metrics", nil))

	if recorder.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200", recorder.Code)
	}
	body := recorder.Body.String()

	for _, want := range []string{
		`router_uplink_link_up 1`,
		`router_uplink_probes_sent_total{target="cloudflare",role="core",tin="be",address="1.1.1.1"} 3600`,
		`router_uplink_probes_received_total{target="cloudflare",role="core",tin="be",address="1.1.1.1"} 3599`,
		// Seconds, not milliseconds: the store keeps ms because that is how
		// the page reads, and Prometheus convention is base units.
		`router_uplink_rtt_seconds{target="cloudflare",role="core",tin="be",address="1.1.1.1",quantile="0.5"} 0.0052`,
		`router_uplink_rtt_seconds{target="cloudflare",role="core",tin="be",address="1.1.1.1",quantile="0.95"} 0.0059`,
		`router_uplink_jitter_seconds{target="cloudflare",role="core",tin="be",address="1.1.1.1"} 0.0004`,
		`router_uplink_load_peak_bits_per_second{target="cloudflare",role="core",tin="be",address="1.1.1.1",direction="down"} 100000000`,
		`router_uplink_target_up{target="lighthouse",role="transit",tin="be",address="139.84.173.48"} 0`,
		"# TYPE router_uplink_rtt_seconds gauge",
	} {
		if !strings.Contains(body, want) {
			t.Errorf("metrics missing:\n  %s\ngot:\n%s", want, body)
		}
	}

	// A target with no completed minute contributes counters but no gauges,
	// rather than a zero that would read as a perfect line.
	if strings.Contains(body, `router_uplink_rtt_seconds{target="lighthouse"`) {
		t.Error("exported latency for a target with no history")
	}
}

func TestBandStates(t *testing.T) {
	now := time.Now().Truncate(time.Minute)

	t.Run("link down outranks everything", func(t *testing.T) {
		store := newTestStore(t)
		if err := store.writeMinute(minuteRow{
			TS: now.Add(-time.Minute), Target: "cloudflare", Role: roleCore, Address: "1.1.1.1",
			Sent: 60, Received: 60, RTTP50: 5.2, RTTP95: 5.9,
		}); err != nil {
			t.Fatalf("seed: %v", err)
		}
		service := newTestService(t, store, seededTargets()...)
		service.prober.pppDown = true

		if band := service.band(); band.State != stateDown {
			t.Errorf("state = %q with the session down, want %q", band.State, stateDown)
		}
	})

	t.Run("an open episode degrades", func(t *testing.T) {
		store := newTestStore(t)
		if err := store.writeMinute(minuteRow{
			TS: now.Add(-time.Minute), Target: "cloudflare", Role: roleCore, Address: "1.1.1.1",
			Sent: 60, Received: 60, RTTP50: 5.2, RTTP95: 5.9,
		}); err != nil {
			t.Fatalf("seed: %v", err)
		}
		targets := seededTargets()
		targets[2].episodeOpen = true
		service := newTestService(t, store, targets...)

		band := service.band()
		if band.State != stateDegraded {
			t.Errorf("state = %q with an open episode, want %q", band.State, stateDegraded)
		}
		if !strings.Contains(band.StateText, "lighthouse") {
			t.Errorf("state text %q does not name the degraded target", band.StateText)
		}
	})

	t.Run("no history yet", func(t *testing.T) {
		service := newTestService(t, newTestStore(t), seededTargets()...)

		band := service.band()
		if band.State != stateUnknown {
			t.Errorf("state = %q with no history, want %q", band.State, stateUnknown)
		}
		if band.Latency != "—" {
			t.Errorf("latency = %q with no history, want an em dash", band.Latency)
		}
	})
}

func TestBandPrefersTheHealthiestCoreAnchor(t *testing.T) {
	// One sick anycast node should read as that anchor degrading, not as the
	// uplink failing — the detail page still shows both.
	store := newTestStore(t)
	now := time.Now().Truncate(time.Minute)

	for name, p50 := range map[string]float64{"cloudflare": 240, "google": 5.4} {
		if err := store.writeMinute(minuteRow{
			TS: now.Add(-time.Minute), Target: name, Role: roleCore, Address: "1.1.1.1",
			Sent: 60, Received: 60, RTTP50: p50, RTTP95: p50 + 1,
		}); err != nil {
			t.Fatalf("seed: %v", err)
		}
	}

	targets := seededTargets()
	targets = append(targets, &uplinkTarget{
		anchor:  anchor{Name: "google", Role: roleCore, Tin: tinBestEffort},
		addr:    netip.MustParseAddr("8.8.8.8"),
		pending: map[uint16]pendingProbe{},
		buckets: map[int64]*minuteBucket{},
		lastOK:  true,
	})
	service := newTestService(t, store, targets...)

	if got := service.bestWithRole(roleCore); got != "google" {
		t.Errorf("bestWithRole(core) = %q, want google", got)
	}
	if band := service.band(); !strings.Contains(band.Latency, "5.40 ms") {
		t.Errorf("band latency = %q, want the healthy anchor's", band.Latency)
	}
}

func TestBandPicksNearestTransitNotFirstConfigured(t *testing.T) {
	// With one transit anchor config order was harmless. With several it is
	// arbitrary, and the band would report whichever was typed first — so a
	// household whose Frankfurt path was fine could read "Transit 310 ms"
	// because São Paulo happened to be listed above it.
	store := newTestStore(t)
	now := time.Now().Truncate(time.Minute)

	transits := []struct {
		name string
		p50  float64
	}{
		{"saopaulo", 310},
		{"newjersey", 190},
		{"frankfurt", 118},
		{"mumbai", 52},
	}
	for _, transit := range transits {
		if err := store.writeMinute(minuteRow{
			TS: now.Add(-time.Minute), Target: transit.name, Role: roleTransit, Address: "203.0.113.1",
			Sent: 60, Received: 60, RTTP50: transit.p50, RTTP95: transit.p50 + 4,
		}); err != nil {
			t.Fatalf("seed %s: %v", transit.name, err)
		}
	}

	// Deliberately listed worst-first, which is what the old behaviour would
	// have headlined.
	targets := seededTargets()
	for _, transit := range transits {
		targets = append(targets, &uplinkTarget{
			anchor:  anchor{Name: transit.name, Role: roleTransit, Tin: tinBestEffort},
			addr:    netip.MustParseAddr("203.0.113.1"),
			pending: map[uint16]pendingProbe{},
			buckets: map[int64]*minuteBucket{},
			lastOK:  true,
		})
	}
	service := newTestService(t, store, targets...)

	if got := service.bestWithRole(roleTransit); got != "mumbai" {
		t.Errorf("bestWithRole(transit) = %q, want mumbai", got)
	}

	band := service.band()
	if !strings.Contains(band.Transit, "52.0 ms") {
		t.Errorf("band transit = %q, want the nearest anchor's median", band.Transit)
	}
	// Named, because a bare figure does not say which continent answered.
	if !strings.Contains(band.Transit, "mumbai") {
		t.Errorf("band transit = %q, want it to name the anchor", band.Transit)
	}
}

func TestBandRoleSelectionIgnoresVoiceTwins(t *testing.T) {
	// A Voice twin is low by construction. If it could win the selection the
	// band would headline the one queue almost nothing else uses.
	store := newTestStore(t)
	now := time.Now().Truncate(time.Minute)

	for name, p50 := range map[string]float64{"cloudflare": 5.2, "cloudflare-voice": 1.1} {
		if err := store.writeMinute(minuteRow{
			TS: now.Add(-time.Minute), Target: name, Role: roleCore, Address: "1.1.1.1",
			Sent: 60, Received: 60, RTTP50: p50, RTTP95: p50 + 1,
		}); err != nil {
			t.Fatalf("seed: %v", err)
		}
	}

	targets := seededTargets()
	targets = append(targets, &uplinkTarget{
		anchor:  anchor{Name: "cloudflare" + voiceSuffix, Role: roleCore, Tin: tinVoice},
		addr:    netip.MustParseAddr("1.1.1.1"),
		pending: map[uint16]pendingProbe{},
		buckets: map[int64]*minuteBucket{},
		lastOK:  true,
	})
	service := newTestService(t, store, targets...)

	if got := service.bestWithRole(roleCore); got != "cloudflare" {
		t.Errorf("bestWithRole(core) = %q, want the best-effort target", got)
	}
}
