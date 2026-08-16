package main

import (
	"net/netip"
	"os"
	"path/filepath"
	"testing"
	"time"
)

// The bug this file exists for: router-web started at 11:01:54, geoip-update
// wrote the tables at 11:02 and 11:03, and the country column stayed empty for
// the life of the process even though both files were on disk.
func TestWatcherPicksUpTablesWrittenAfterStartup(t *testing.T) {
	dir := t.TempDir()
	asnPath := filepath.Join(dir, "asn.tsv")
	geoPath := filepath.Join(dir, "country.tsv")

	// Neither file exists yet, exactly as at startup on a fresh router.
	watcher := newTableWatcher(asnPath, geoPath)
	if watcher.asnTable() != nil || watcher.geoTable() != nil {
		t.Fatal("loaded a table from files that do not exist")
	}
	// Nil tables must answer rather than panic, because the page renders in
	// this state.
	if _, ok := watcher.geoTable().Lookup(netip.MustParseAddr("8.8.8.8")); ok {
		t.Fatal("nil geo table answered")
	}

	write(t, asnPath, "8.8.8.0\t8.8.8.255\t15169\t\tGOOGLE\n")
	write(t, geoPath, "8.8.8.0\t8.8.8.255\tUS\n")
	watcher.refresh()

	info, ok := watcher.asnTable().Lookup(netip.MustParseAddr("8.8.8.8"))
	if !ok || info.Number != 15169 {
		t.Fatalf("asn after write: %+v %v", info, ok)
	}
	code, ok := watcher.geoTable().Lookup(netip.MustParseAddr("8.8.8.8"))
	if !ok || code != "US" {
		t.Fatalf("country after write: %q %v", code, ok)
	}
}

// The half that would have gone unnoticed for a week: the updater replaces the
// files every week under a process that had already read them.
func TestWatcherPicksUpAReplacedTable(t *testing.T) {
	dir := t.TempDir()
	geoPath := filepath.Join(dir, "country.tsv")
	write(t, geoPath, "8.8.8.0\t8.8.8.255\tUS\n")

	watcher := newTableWatcher("", geoPath)
	if code, _ := watcher.geoTable().Lookup(netip.MustParseAddr("8.8.8.8")); code != "US" {
		t.Fatalf("initial load: %q", code)
	}

	// A new release places the same address elsewhere. Written via rename, as
	// the converter does, so this is a new inode rather than an edit.
	tmp := geoPath + ".new"
	write(t, tmp, "8.8.8.0\t8.8.8.255\tNL\n")
	if err := os.Chtimes(tmp, time.Now().Add(time.Second), time.Now().Add(time.Second)); err != nil {
		t.Fatalf("chtimes: %v", err)
	}
	if err := os.Rename(tmp, geoPath); err != nil {
		t.Fatalf("rename: %v", err)
	}

	watcher.refresh()
	if code, _ := watcher.geoTable().Lookup(netip.MustParseAddr("8.8.8.8")); code != "NL" {
		t.Fatalf("after replacement: %q, want NL — the watcher did not re-read", code)
	}
}

func TestWatcherKeepsThePreviousTableWhenAReloadFails(t *testing.T) {
	// A truncated or half-written file is a transient the next poll fixes. An
	// old table beats no table, which is the same call the STUN resolver makes.
	dir := t.TempDir()
	geoPath := filepath.Join(dir, "country.tsv")
	write(t, geoPath, "8.8.8.0\t8.8.8.255\tUS\n")
	watcher := newTableWatcher("", geoPath)

	if err := os.Remove(geoPath); err != nil {
		t.Fatalf("remove: %v", err)
	}
	watcher.refresh()
	if code, _ := watcher.geoTable().Lookup(netip.MustParseAddr("8.8.8.8")); code != "US" {
		t.Fatalf("lost the table when the file vanished: %q", code)
	}
}

func TestWatcherDoesNotReloadAnUnchangedFile(t *testing.T) {
	dir := t.TempDir()
	geoPath := filepath.Join(dir, "country.tsv")
	write(t, geoPath, "8.8.8.0\t8.8.8.255\tUS\n")
	watcher := newTableWatcher("", geoPath)

	first := watcher.geoTable()
	watcher.refresh()
	watcher.refresh()
	if watcher.geoTable() != first {
		t.Fatal("re-parsed a 25 MB table that had not changed")
	}
}

func TestNilWatcherIsUsable(t *testing.T) {
	// What a test server or a misconfigured router holds. Every path through
	// the page must survive it.
	var watcher *tableWatcher
	watcher.refresh()
	if watcher.asnTable() != nil || watcher.geoTable() != nil {
		t.Fatal("nil watcher produced a table")
	}
}

func write(t *testing.T, path, body string) {
	t.Helper()
	if err := os.WriteFile(path, []byte(body), 0o600); err != nil {
		t.Fatalf("write %s: %v", path, err)
	}
}
