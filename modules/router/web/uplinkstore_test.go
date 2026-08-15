package main

import (
	"path/filepath"
	"testing"
	"time"
)

func newTestStore(t *testing.T) *uplinkStore {
	t.Helper()

	store, err := openUplinkStore(filepath.Join(t.TempDir(), "uplink.db"))
	if err != nil {
		t.Fatalf("open store: %v", err)
	}
	t.Cleanup(func() { store.Close() })
	return store
}

func writeMinutes(t *testing.T, store *uplinkStore, target string, base time.Time, rows ...minuteRow) {
	t.Helper()

	for i, row := range rows {
		row.Target = target
		row.Role = roleCore
		row.Address = "1.1.1.1"
		if row.TS.IsZero() {
			row.TS = base.Add(time.Duration(i) * time.Minute)
		}
		if err := store.writeMinute(row); err != nil {
			t.Fatalf("write minute %d: %v", i, err)
		}
	}
}

func TestStoreCreatesItsOwnDirectory(t *testing.T) {
	// StateDirectory gives the unit /var/lib/private/router-web, but the
	// subdirectory the database sits in is this code's to make.
	path := filepath.Join(t.TempDir(), "nested", "deeper", "uplink.db")
	store, err := openUplinkStore(path)
	if err != nil {
		t.Fatalf("open store: %v", err)
	}
	store.Close()
}

func TestStoreReopenKeepsHistory(t *testing.T) {
	// The point of the whole file: a restart, a redeploy or a reboot must not
	// lose the history, because the history is the evidence.
	dir := t.TempDir()
	path := filepath.Join(dir, "uplink.db")
	base := time.Date(2026, 8, 15, 10, 0, 0, 0, time.UTC)

	first, err := openUplinkStore(path)
	if err != nil {
		t.Fatalf("open store: %v", err)
	}
	writeMinutes(t, first, "cloudflare", base,
		minuteRow{Sent: 60, Received: 60, RTTP50: 5.2})
	if _, err := first.appendEvent(uplinkEvent{TS: base, Kind: eventPPPDown, Target: "ppp0", Detail: "test"}); err != nil {
		t.Fatalf("append event: %v", err)
	}
	first.Close()

	second, err := openUplinkStore(path)
	if err != nil {
		t.Fatalf("reopen store: %v", err)
	}
	defer second.Close()

	rows, err := second.since("cloudflare", base.Add(-time.Hour))
	if err != nil {
		t.Fatalf("since: %v", err)
	}
	if len(rows) != 1 || rows[0].RTTP50 != 5.2 {
		t.Fatalf("rows after reopen = %+v, want the one written before", rows)
	}

	events, err := second.events(base.Add(-time.Hour), 10)
	if err != nil {
		t.Fatalf("events: %v", err)
	}
	if len(events) != 1 {
		t.Fatalf("events after reopen = %d, want 1", len(events))
	}
}

func TestStoreWriteMinuteReplaces(t *testing.T) {
	// A flush that runs twice for the same minute, which a restart straddling
	// a boundary produces, must leave one row rather than fail.
	store := newTestStore(t)
	base := time.Date(2026, 8, 15, 10, 0, 0, 0, time.UTC)

	writeMinutes(t, store, "cloudflare", base, minuteRow{TS: base, Sent: 30, Received: 30, RTTP50: 5})
	writeMinutes(t, store, "cloudflare", base, minuteRow{TS: base, Sent: 60, Received: 59, RTTP50: 6})

	rows, err := store.since("cloudflare", base.Add(-time.Hour))
	if err != nil {
		t.Fatalf("since: %v", err)
	}
	if len(rows) != 1 {
		t.Fatalf("got %d rows, want 1", len(rows))
	}
	if rows[0].Sent != 60 {
		t.Errorf("sent = %d, want 60: the later flush should win", rows[0].Sent)
	}
}

func TestStoreSinceIsOrderedAndBounded(t *testing.T) {
	store := newTestStore(t)
	base := time.Date(2026, 8, 15, 10, 0, 0, 0, time.UTC)

	writeMinutes(t, store, "cloudflare", base,
		minuteRow{Sent: 60, Received: 60, RTTP50: 1},
		minuteRow{Sent: 60, Received: 60, RTTP50: 2},
		minuteRow{Sent: 60, Received: 60, RTTP50: 3},
	)
	// Another target's rows must not leak into the first target's window.
	writeMinutes(t, store, "google", base, minuteRow{Sent: 60, Received: 60, RTTP50: 99})

	rows, err := store.since("cloudflare", base.Add(time.Minute))
	if err != nil {
		t.Fatalf("since: %v", err)
	}
	if len(rows) != 2 {
		t.Fatalf("got %d rows, want 2", len(rows))
	}
	if rows[0].RTTP50 != 2 || rows[1].RTTP50 != 3 {
		t.Errorf("rows out of order or wrong: %v, %v", rows[0].RTTP50, rows[1].RTTP50)
	}
}

func TestStoreLatest(t *testing.T) {
	store := newTestStore(t)
	base := time.Date(2026, 8, 15, 10, 0, 0, 0, time.UTC)

	if _, ok, err := store.latest("cloudflare"); err != nil || ok {
		t.Fatalf("latest on an empty store = ok %v, err %v; want false, nil", ok, err)
	}

	writeMinutes(t, store, "cloudflare", base,
		minuteRow{Sent: 60, Received: 60, RTTP50: 1},
		minuteRow{Sent: 60, Received: 60, RTTP50: 2},
	)

	row, ok, err := store.latest("cloudflare")
	if err != nil || !ok {
		t.Fatalf("latest = ok %v, err %v", ok, err)
	}
	if row.RTTP50 != 2 {
		t.Errorf("latest p50 = %v, want 2", row.RTTP50)
	}
}

func TestStoreLossSince(t *testing.T) {
	store := newTestStore(t)
	base := time.Date(2026, 8, 15, 10, 0, 0, 0, time.UTC)

	writeMinutes(t, store, "cloudflare", base,
		minuteRow{Sent: 60, Received: 60},
		minuteRow{Sent: 60, Received: 30},
		minuteRow{Sent: 60, Received: 0},
	)

	sent, received, err := store.lossSince("cloudflare", base)
	if err != nil {
		t.Fatalf("lossSince: %v", err)
	}
	if sent != 180 || received != 90 {
		t.Errorf("sent/received = %d/%d, want 180/90", sent, received)
	}

	// An empty window must report zero rather than fail, so the band renders
	// on a router that has just started.
	sent, received, err = store.lossSince("cloudflare", base.Add(time.Hour))
	if err != nil {
		t.Fatalf("lossSince on an empty window: %v", err)
	}
	if sent != 0 || received != 0 {
		t.Errorf("empty window = %d/%d, want 0/0", sent, received)
	}
}

func TestStoreBaseline(t *testing.T) {
	store := newTestStore(t)
	base := time.Date(2026, 8, 15, 10, 0, 0, 0, time.UTC)

	if _, ok, err := store.baseline("cloudflare", base); err != nil || ok {
		t.Fatalf("baseline with no history = ok %v, err %v; want false, nil", ok, err)
	}

	// Ninety good minutes and ten bad ones. The baseline is what the line
	// looks like when it works, so the bad day must not move it.
	var rows []minuteRow
	for range 90 {
		rows = append(rows, minuteRow{Sent: 60, Received: 60, RTTP50: 5})
	}
	for range 10 {
		rows = append(rows, minuteRow{Sent: 60, Received: 60, RTTP50: 250})
	}
	writeMinutes(t, store, "cloudflare", base, rows...)

	value, ok, err := store.baseline("cloudflare", base)
	if err != nil || !ok {
		t.Fatalf("baseline = ok %v, err %v", ok, err)
	}
	if value != 5 {
		t.Errorf("baseline = %v, want 5: a bad episode redefined normal", value)
	}
}

func TestStoreBaselineIgnoresMinutesWithNoReply(t *testing.T) {
	// A minute where every probe was lost stores zero RTTs. Counting those as
	// a fast reply would drag the baseline to zero and make the latency
	// episode detector fire on a healthy line forever after.
	store := newTestStore(t)
	base := time.Date(2026, 8, 15, 10, 0, 0, 0, time.UTC)

	var rows []minuteRow
	for range 20 {
		rows = append(rows, minuteRow{Sent: 60, Received: 0})
	}
	for range 20 {
		rows = append(rows, minuteRow{Sent: 60, Received: 60, RTTP50: 5})
	}
	writeMinutes(t, store, "cloudflare", base, rows...)

	value, ok, err := store.baseline("cloudflare", base)
	if err != nil || !ok {
		t.Fatalf("baseline = ok %v, err %v", ok, err)
	}
	if value != 5 {
		t.Errorf("baseline = %v, want 5", value)
	}
}

func TestStoreEventLifecycle(t *testing.T) {
	store := newTestStore(t)
	base := time.Date(2026, 8, 15, 10, 0, 0, 0, time.UTC)

	id, err := store.appendEvent(uplinkEvent{
		TS: base, Kind: eventDegraded, Target: "cloudflare", Detail: "3.0% loss",
	})
	if err != nil {
		t.Fatalf("append: %v", err)
	}

	// A restart mid-episode has to find the open event rather than open a
	// second one that overlaps it.
	open, found, err := store.openEvent(eventDegraded, "cloudflare")
	if err != nil || !found {
		t.Fatalf("openEvent = found %v, err %v", found, err)
	}
	if open.ID != id || open.Detail != "3.0% loss" {
		t.Errorf("openEvent returned %+v", open)
	}

	if _, found, _ := store.openEvent(eventDegraded, "google"); found {
		t.Error("openEvent matched a different target")
	}
	if _, found, _ := store.openEvent(eventOutage, "cloudflare"); found {
		t.Error("openEvent matched a different kind")
	}

	if err := store.closeEvent(id, base.Add(10*time.Minute)); err != nil {
		t.Fatalf("close: %v", err)
	}
	if _, found, _ := store.openEvent(eventDegraded, "cloudflare"); found {
		t.Error("event still open after being closed")
	}

	// Closing twice, or closing something that does not exist, is what a
	// restarted state machine does. Neither is an error.
	if err := store.closeEvent(id, base.Add(20*time.Minute)); err != nil {
		t.Errorf("second close: %v", err)
	}
	if err := store.closeEvent(9999, base); err != nil {
		t.Errorf("close of an absent event: %v", err)
	}

	events, err := store.events(base.Add(-time.Hour), 10)
	if err != nil {
		t.Fatalf("events: %v", err)
	}
	if len(events) != 1 {
		t.Fatalf("got %d events, want 1", len(events))
	}
	if !events[0].Ended.Equal(base.Add(10 * time.Minute)) {
		t.Errorf("ended = %v, want the first close to stand", events[0].Ended)
	}
}

func TestStoreEventsAreNewestFirst(t *testing.T) {
	store := newTestStore(t)
	base := time.Date(2026, 8, 15, 10, 0, 0, 0, time.UTC)

	for i := range 5 {
		if _, err := store.appendEvent(uplinkEvent{
			TS: base.Add(time.Duration(i) * time.Hour), Kind: eventPPPDown, Target: "ppp0",
			Detail: "drop",
		}); err != nil {
			t.Fatalf("append: %v", err)
		}
	}

	events, err := store.events(base, 3)
	if err != nil {
		t.Fatalf("events: %v", err)
	}
	if len(events) != 3 {
		t.Fatalf("got %d events, want the limit of 3", len(events))
	}
	if !events[0].TS.Equal(base.Add(4 * time.Hour)) {
		t.Errorf("first event is %v, want the newest", events[0].TS)
	}
}

func TestStoreCountEvents(t *testing.T) {
	store := newTestStore(t)
	base := time.Date(2026, 8, 15, 10, 0, 0, 0, time.UTC)

	for i := range 3 {
		store.appendEvent(uplinkEvent{TS: base.Add(time.Duration(i) * time.Hour), Kind: eventPPPDown, Target: "ppp0"})
	}
	store.appendEvent(uplinkEvent{TS: base, Kind: eventDegraded, Target: "cloudflare"})

	count, err := store.countEvents(eventPPPDown, base)
	if err != nil {
		t.Fatalf("countEvents: %v", err)
	}
	if count != 3 {
		t.Errorf("count = %d, want 3", count)
	}

	// Events at +0h, +1h and +2h; a window starting at +90m sees only the last.
	count, err = store.countEvents(eventPPPDown, base.Add(90*time.Minute))
	if err != nil {
		t.Fatalf("countEvents: %v", err)
	}
	if count != 1 {
		t.Errorf("count from a later window start = %d, want 1", count)
	}
}

func TestStorePruneKeepsEvents(t *testing.T) {
	// Minutes expire; events do not. A session drop from four months ago is
	// exactly what gets cited in a complaint.
	store := newTestStore(t)
	now := time.Date(2026, 8, 15, 10, 0, 0, 0, time.UTC)
	old := now.Add(-100 * 24 * time.Hour)

	writeMinutes(t, store, "cloudflare", old, minuteRow{TS: old, Sent: 60, Received: 60, RTTP50: 5})
	writeMinutes(t, store, "cloudflare", now, minuteRow{TS: now, Sent: 60, Received: 60, RTTP50: 5})
	if _, err := store.appendEvent(uplinkEvent{TS: old, Kind: eventPPPDown, Target: "ppp0", Detail: "old"}); err != nil {
		t.Fatalf("append: %v", err)
	}

	if err := store.prune(now.Add(-90 * 24 * time.Hour)); err != nil {
		t.Fatalf("prune: %v", err)
	}

	rows, err := store.since("cloudflare", old.Add(-time.Hour))
	if err != nil {
		t.Fatalf("since: %v", err)
	}
	if len(rows) != 1 {
		t.Fatalf("got %d rows after prune, want 1", len(rows))
	}
	if !rows[0].TS.Equal(now) {
		t.Errorf("prune kept the wrong row: %v", rows[0].TS)
	}

	events, err := store.events(old.Add(-time.Hour), 10)
	if err != nil {
		t.Fatalf("events: %v", err)
	}
	if len(events) != 1 {
		t.Errorf("got %d events after prune, want the old one kept", len(events))
	}
}

func TestStoreDaily(t *testing.T) {
	store := newTestStore(t)
	// 21:00 UTC is the next local day in +04, which is what the offset is
	// there to handle: a day boundary that matches the clock on the wall.
	base := time.Date(2026, 8, 15, 21, 0, 0, 0, time.UTC)
	const offset = 4 * 3600

	writeMinutes(t, store, "cloudflare", base,
		minuteRow{TS: base, Sent: 60, Received: 60, RTTMin: 4, RTTP50: 5, RTTP95: 6, RTTMax: 7},
		minuteRow{TS: base.Add(time.Minute), Sent: 60, Received: 30, RTTMin: 4, RTTP50: 7, RTTP95: 8, RTTMax: 90},
	)

	days, err := store.daily(base.Add(-48*time.Hour), offset)
	if err != nil {
		t.Fatalf("daily: %v", err)
	}
	if len(days) != 1 {
		t.Fatalf("got %d days, want 1", len(days))
	}

	day := days[0]
	if day.Sent != 120 || day.Received != 90 {
		t.Errorf("sent/received = %d/%d, want 120/90", day.Sent, day.Received)
	}
	if day.Loss() != 0.25 {
		t.Errorf("loss = %v, want 0.25", day.Loss())
	}
	if day.RTTMax != 90 {
		t.Errorf("max = %v, want 90", day.RTTMax)
	}
	if day.RTTP50 != 6 {
		t.Errorf("mean of the per-minute medians = %v, want 6", day.RTTP50)
	}
	if got := day.Day.In(time.FixedZone("test", offset)).Format("2006-01-02"); got != "2026-08-16" {
		t.Errorf("day = %s, want 2026-08-16 in local time", got)
	}
}

func TestStoreDailyIgnoresZeroLatencyMinutes(t *testing.T) {
	// Averaging in the zeros from fully lost minutes would report a day of
	// outage as a day of unusually low latency.
	store := newTestStore(t)
	base := time.Date(2026, 8, 15, 10, 0, 0, 0, time.UTC)

	writeMinutes(t, store, "cloudflare", base,
		minuteRow{TS: base, Sent: 60, Received: 60, RTTMin: 5, RTTP50: 5, RTTP95: 6, RTTMax: 7},
		minuteRow{TS: base.Add(time.Minute), Sent: 60, Received: 0},
	)

	days, err := store.daily(base.Add(-24*time.Hour), 0)
	if err != nil {
		t.Fatalf("daily: %v", err)
	}
	if len(days) != 1 {
		t.Fatalf("got %d days, want 1", len(days))
	}
	if days[0].RTTP50 != 5 {
		t.Errorf("median = %v, want 5", days[0].RTTP50)
	}
	if days[0].RTTMin != 5 {
		t.Errorf("min = %v, want 5", days[0].RTTMin)
	}
}

func TestStoreTargets(t *testing.T) {
	store := newTestStore(t)
	base := time.Date(2026, 8, 15, 10, 0, 0, 0, time.UTC)

	writeMinutes(t, store, "google", base, minuteRow{Sent: 60, Received: 60})
	writeMinutes(t, store, "cloudflare", base, minuteRow{Sent: 60, Received: 60})
	writeMinutes(t, store, "cloudflare", base.Add(time.Minute), minuteRow{Sent: 60, Received: 60})

	names, err := store.targets()
	if err != nil {
		t.Fatalf("targets: %v", err)
	}
	if len(names) != 2 || names[0] != "cloudflare" || names[1] != "google" {
		t.Errorf("targets = %v, want [cloudflare google]", names)
	}
}

func TestMinuteRowLoss(t *testing.T) {
	tests := []struct {
		name string
		row  minuteRow
		want float64
	}{
		{"nothing sent", minuteRow{}, 0},
		{"clean", minuteRow{Sent: 60, Received: 60}, 0},
		{"half", minuteRow{Sent: 60, Received: 30}, 0.5},
		{"total", minuteRow{Sent: 60, Received: 0}, 1},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			if got := test.row.Loss(); got != test.want {
				t.Errorf("loss = %v, want %v", got, test.want)
			}
		})
	}
}
