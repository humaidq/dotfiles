package main

import (
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// Two defects made the event log fill with rows that claimed to be current and
// never could stop being: peer_changed was appended and never closed, and a
// restart mid-episode abandoned the open degraded row and later opened another.
// These cover the fixes for both, and the repair for what they already wrote.

func TestPeerChangedClosesThePreviousSession(t *testing.T) {
	store := newTestStore(t)
	iface := "ppp0"
	first := time.Date(2026, 8, 22, 5, 0, 0, 0, time.UTC)
	second := first.Add(24 * time.Hour)

	if _, err := store.appendEvent(uplinkEvent{
		TS: first, Kind: eventPeerChanged, Target: iface, Detail: "session one",
	}); err != nil {
		t.Fatalf("append first: %v", err)
	}

	// What pollPPP does when it sees the address move.
	if err := store.closeOpenEvents(eventPeerChanged, iface, second); err != nil {
		t.Fatalf("close open: %v", err)
	}
	if _, err := store.appendEvent(uplinkEvent{
		TS: second, Kind: eventPeerChanged, Target: iface, Detail: "session two",
	}); err != nil {
		t.Fatalf("append second: %v", err)
	}

	events, err := store.events(first.Add(-time.Hour), 10)
	if err != nil {
		t.Fatalf("events: %v", err)
	}
	if len(events) != 2 {
		t.Fatalf("got %d events, want 2", len(events))
	}
	// Newest first.
	if !events[0].Ended.IsZero() {
		t.Error("the current session is not ongoing")
	}
	if events[1].Ended.IsZero() {
		t.Error("the superseded session is still ongoing")
	}
	if got := events[1].Ended; !got.Equal(second) {
		t.Errorf("previous session ended %s, want %s", got, second)
	}
}

// Exactly one session may be open, however many redials have happened.
func TestOnlyTheLatestSessionIsOngoing(t *testing.T) {
	store := newTestStore(t)
	iface := "ppp0"
	base := time.Date(2026, 8, 18, 5, 0, 0, 0, time.UTC)

	for day := range 5 {
		at := base.Add(time.Duration(day) * 24 * time.Hour)
		if err := store.closeOpenEvents(eventPeerChanged, iface, at); err != nil {
			t.Fatalf("close open: %v", err)
		}
		if _, err := store.appendEvent(uplinkEvent{
			TS: at, Kind: eventPeerChanged, Target: iface, Detail: "redial",
		}); err != nil {
			t.Fatalf("append: %v", err)
		}
	}

	events, err := store.events(base.Add(-time.Hour), 20)
	if err != nil {
		t.Fatalf("events: %v", err)
	}
	open := 0
	for _, e := range events {
		if e.Ended.IsZero() {
			open++
		}
	}
	if open != 1 {
		t.Errorf("%d sessions open after five redials, want 1", open)
	}
	if !events[0].Ended.IsZero() {
		t.Error("the open one is not the newest")
	}
}

// A restart mid-episode must continue the episode, not abandon it and start a
// second one that overlaps.
func TestRestartResumesAnOpenEpisode(t *testing.T) {
	store := newTestStore(t)
	start := time.Date(2026, 8, 23, 5, 0, 0, 0, time.UTC)

	before := newTestTarget(roleCore)
	id, err := store.appendEvent(uplinkEvent{
		TS: start, Kind: eventDegraded, Target: before.anchor.Name, Detail: "median 85 ms",
	})
	if err != nil {
		t.Fatalf("append: %v", err)
	}

	// A fresh process: new target structs, nothing in memory.
	after := newTestTarget(roleCore)
	prober := &uplinkProber{store: store, targets: []*uplinkTarget{after}}
	prober.resumeOpenEvents()

	if !after.episodeOpen {
		t.Fatal("the resumed process does not know it is inside an episode")
	}
	if after.episodeID != id {
		t.Errorf("episodeID = %d, want %d", after.episodeID, id)
	}

	// And it can now close the original row rather than orphaning it.
	recovered := start.Add(2 * time.Hour)
	for i := range episodeCloseAfter {
		prober.updateEpisode(after, minuteRow{
			TS: recovered.Add(time.Duration(i) * time.Minute), Target: after.anchor.Name,
			Role: roleCore, Sent: 60, Received: 60, RTTP50: 9,
		})
	}
	if after.episodeOpen {
		t.Error("episode still open after a full run of good minutes")
	}
	if _, found, err := store.openEvent(eventDegraded, after.anchor.Name); err != nil {
		t.Fatalf("open event: %v", err)
	} else if found {
		t.Error("the original row was left open, so a second episode would follow it")
	}
}

func TestRestartResumesAnOpenPPPDown(t *testing.T) {
	store := newTestStore(t)
	iface := "ppp0"
	id, err := store.appendEvent(uplinkEvent{
		TS:   time.Date(2026, 8, 23, 5, 0, 0, 0, time.UTC),
		Kind: eventPPPDown, Target: iface, Detail: "no address on the interface",
	})
	if err != nil {
		t.Fatalf("append: %v", err)
	}

	prober := &uplinkProber{store: store, pppIface: iface}
	prober.resumeOpenEvents()

	if !prober.pppDown {
		t.Error("the resumed process does not know the session was down")
	}
	if prober.pppEvent != id {
		t.Errorf("pppEvent = %d, want %d", prober.pppEvent, id)
	}
}

// Nothing open, nothing adopted — and in particular no phantom episode on a
// router whose history is clean.
func TestResumeIsANoopWithNothingOpen(t *testing.T) {
	store := newTestStore(t)
	target := newTestTarget(roleCore)
	prober := &uplinkProber{store: store, pppIface: "ppp0", targets: []*uplinkTarget{target}}
	prober.resumeOpenEvents()

	if target.episodeOpen || target.episodeID != 0 {
		t.Error("resume invented an episode")
	}
	if prober.pppDown {
		t.Error("resume invented a down session")
	}
}

// The repair for rows the two defects already wrote. Runs at open, so this
// reopens a store over the same file to trigger it.
func TestOpeningRepairsSupersededEvents(t *testing.T) {
	path := filepath.Join(t.TempDir(), "uplink.db")
	store, err := openUplinkStore(path)
	if err != nil {
		t.Fatalf("open: %v", err)
	}

	base := time.Date(2026, 8, 20, 5, 0, 0, 0, time.UTC)
	// Three redials, none ever closed — the shape the bug produced.
	for day := range 3 {
		if _, err := store.appendEvent(uplinkEvent{
			TS:   base.Add(time.Duration(day) * 24 * time.Hour),
			Kind: eventPeerChanged, Target: "ppp0", Detail: "redial",
		}); err != nil {
			t.Fatalf("append: %v", err)
		}
	}
	// Two overlapping open episodes for one anchor, from a restart.
	firstEpisode := base.Add(48 * time.Hour)
	secondEpisode := firstEpisode.Add(11 * time.Hour)
	for _, ts := range []time.Time{firstEpisode, secondEpisode} {
		if _, err := store.appendEvent(uplinkEvent{
			TS: ts, Kind: eventDegraded, Target: "hisn", Detail: "median 85 ms",
		}); err != nil {
			t.Fatalf("append: %v", err)
		}
	}
	store.Close()

	repaired, err := openUplinkStore(path)
	if err != nil {
		t.Fatalf("reopen: %v", err)
	}
	defer repaired.Close()

	events, err := repaired.events(base.Add(-time.Hour), 50)
	if err != nil {
		t.Fatalf("events: %v", err)
	}
	openByKind := map[string]int{}
	for _, e := range events {
		if e.Ended.IsZero() {
			openByKind[e.Kind]++
		}
	}
	if openByKind[eventPeerChanged] != 1 {
		t.Errorf("%d open peer_changed after repair, want 1", openByKind[eventPeerChanged])
	}
	if openByKind[eventDegraded] != 1 {
		t.Errorf("%d open degraded after repair, want 1", openByKind[eventDegraded])
	}

	// The superseded episode ends where its successor begins, which is the
	// only end time that is known rather than invented.
	for _, e := range events {
		if e.Kind == eventDegraded && e.TS.Equal(firstEpisode) {
			if !e.Ended.Equal(secondEpisode) {
				t.Errorf("superseded episode ended %s, want %s", e.Ended, secondEpisode)
			}
		}
		// The newest of each kind must still be ongoing: inventing an end for
		// the current session is the failure being fixed, not the fix.
		if e.Kind == eventDegraded && e.TS.Equal(secondEpisode) && !e.Ended.IsZero() {
			t.Error("the running episode was closed by the repair")
		}
	}
}

// Running the repair twice must not move an end time that is already set.
func TestRepairIsIdempotent(t *testing.T) {
	path := filepath.Join(t.TempDir(), "uplink.db")
	store, err := openUplinkStore(path)
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	base := time.Date(2026, 8, 20, 5, 0, 0, 0, time.UTC)
	for day := range 2 {
		if _, err := store.appendEvent(uplinkEvent{
			TS:   base.Add(time.Duration(day) * 24 * time.Hour),
			Kind: eventPeerChanged, Target: "ppp0", Detail: "redial",
		}); err != nil {
			t.Fatalf("append: %v", err)
		}
	}
	store.Close()

	var first []uplinkEvent
	for pass := range 3 {
		s, err := openUplinkStore(path)
		if err != nil {
			t.Fatalf("reopen: %v", err)
		}
		got, err := s.events(base.Add(-time.Hour), 50)
		if err != nil {
			t.Fatalf("events: %v", err)
		}
		s.Close()
		if pass == 0 {
			first = got
			continue
		}
		if len(got) != len(first) {
			t.Fatalf("pass %d returned %d events, want %d", pass, len(got), len(first))
		}
		for i := range got {
			if !got[i].Ended.Equal(first[i].Ended) {
				t.Errorf("pass %d moved event %d end from %s to %s",
					pass, got[i].ID, first[i].Ended, got[i].Ended)
			}
		}
	}
}

// The fibre section on the uplink page: the live band, and the graph the
// status page deliberately has not got.
func TestUplinkPageRendersFibreBandAndGraph(t *testing.T) {
	store := newTestStore(t)
	monitor := writeONT(t, ontHealthy)
	monitor.store = store

	// Two days of readings, drifting down by a fifth of a dB, plus one taken
	// while the fibre was down.
	base := time.Now().Add(-48 * time.Hour).Truncate(time.Minute)
	for i := range 48 {
		sample := opticalSample{
			TS: base.Add(time.Duration(i) * time.Hour),
			Rx: -13.5 - float64(i)*0.004, Tx: 2.4, Temp: 38.4, Volt: 3.31,
			Bias: 0.012, PONUp: i != 20,
		}
		if err := store.appendOptical(sample); err != nil {
			t.Fatalf("seed optical: %v", err)
		}
	}

	service := newTestService(t, store, seededTargets()...)
	recorder := httptest.NewRecorder()
	service.handlePage(recorder, httptest.NewRequest(http.MethodGet, "/uplink", nil), navData{}, monitor)

	if recorder.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200", recorder.Code)
	}
	body := recorder.Body.String()
	for _, want := range []string{
		"Fibre line: healthy",
		"Receive power",
		"-13.6 dBm",
		"normal -25.0 to -10.0 dBm",
		"Fibre, last 14 days",
		"spark-line",
		"spark-loss", // the minute the PON was down, marked not interpolated
		"dBm across 47 readings",
	} {
		if !strings.Contains(body, want) {
			t.Errorf("uplink page is missing %q", want)
		}
	}
}

// A router with no ONT keeps exactly the page it had before.
func TestUplinkPageOmitsFibreWhenUnset(t *testing.T) {
	service := newTestService(t, newTestStore(t), seededTargets()...)
	recorder := httptest.NewRecorder()
	service.handlePage(recorder, httptest.NewRequest(http.MethodGet, "/uplink", nil), navData{}, nil)

	body := recorder.Body.String()
	for _, absent := range []string{"Fibre line", "Fibre, last"} {
		if strings.Contains(body, absent) {
			t.Errorf("uplink page rendered %q with no ONT configured", absent)
		}
	}
}

// One reading cannot make a line, and must not render a graph implying it can.
func TestFibreGraphNeedsTwoReadings(t *testing.T) {
	store := newTestStore(t)
	monitor := writeONT(t, ontHealthy)
	monitor.store = store
	monitor.record()

	service := newTestService(t, store, seededTargets()...)
	recorder := httptest.NewRecorder()
	service.handlePage(recorder, httptest.NewRequest(http.MethodGet, "/uplink", nil), navData{}, monitor)

	body := recorder.Body.String()
	if !strings.Contains(body, "Fibre line: healthy") {
		t.Error("the live band should render from the first reading")
	}
	if strings.Contains(body, "Fibre, last") {
		t.Error("a graph rendered from a single reading")
	}
}

// Removing an anchor while one of its episodes is open must not leave the row
// open forever: nothing probes that target any more, so nothing could ever
// close it.
func TestRemovingAnAnchorClosesItsOpenEpisode(t *testing.T) {
	store := newTestStore(t)
	if _, err := store.appendEvent(uplinkEvent{
		TS: time.Now().Add(-11 * time.Hour), Kind: eventDegraded,
		Target: "hisn", Detail: "median 85 ms against a 9 ms baseline",
	}); err != nil {
		t.Fatalf("append: %v", err)
	}

	// A prober configured with a different anchor set entirely.
	kept := newTestTarget(roleCore)
	prober := &uplinkProber{store: store, targets: []*uplinkTarget{kept}}
	prober.resumeOpenEvents()

	if _, found, err := store.openEvent(eventDegraded, "hisn"); err != nil {
		t.Fatalf("open event: %v", err)
	} else if found {
		t.Error("the removed anchor's episode is still ongoing and can never close")
	}
	// The anchors still configured are untouched.
	if kept.episodeOpen {
		t.Error("resume opened an episode for a target that had none")
	}
}
