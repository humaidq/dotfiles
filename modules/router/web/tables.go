package main

import (
	"log"
	"os"
	"sync"
	"sync/atomic"
	"time"
)

// Keeping the range tables current under a server that does not restart.
//
// Both tables are files written by geoip-update, and the first version of this
// loaded them once at startup. That was wrong twice over, and the second way
// was the one that would have gone unnoticed for a week at a time:
//
//   - On a deploy, systemd starts router-web and the updater concurrently. On
//     2026-08-16 router-web won at 11:01:54 and the tables landed at 11:02 and
//     11:03, so the country column was empty on a router that had both files
//     sitting on disk the whole time anyone looked at it.
//   - In steady state the updater replaces both files every week beneath a
//     process that had already read them. Every refresh would have been
//     invisible until some unrelated deploy happened to restart the server.
//
// So the tables are held in atomics and re-read when the files change. Polling
// rather than inotify: two stat calls a minute against a file that changes
// weekly is not worth a watcher, and os.Rename — which is how the converter
// installs both files — is exactly the case a naive watcher misses.
const tableWatchInterval = time.Minute

// stamp is what "the file changed" means here. Size and modification time
// together, because the converter writes to a temp file and renames, so a new
// table is a new inode rather than an in-place edit of the same bytes.
type stamp struct {
	size int64
	mod  time.Time
}

func statStamp(path string) (stamp, bool) {
	info, err := os.Stat(path)
	if err != nil {
		return stamp{}, false
	}
	return stamp{size: info.Size(), mod: info.ModTime()}, true
}

// tableWatcher reloads whichever of the two tables has changed.
//
// Held by the peers server, which reads through asnTable() and geoTable().
// Both readers are nil-safe, so a table that has never loaded answers "no
// attribution" rather than failing a page — which is what a fresh router wants
// while it waits for its first download.
type tableWatcher struct {
	asnPath string
	geoPath string

	asn atomic.Pointer[ASNTable]
	geo atomic.Pointer[GeoTable]

	mu       sync.Mutex
	asnStamp stamp
	geoStamp stamp
}

// refresh reloads any table whose file has changed since the last look.
//
// A failed load leaves the previous table in place rather than clearing it. A
// half-written file is a transient the next poll fixes, and a stale table is a
// far better answer than none — the same reasoning the STUN resolver applies
// to its sets.
func (w *tableWatcher) refresh() {
	if w == nil {
		return
	}
	w.mu.Lock()
	defer w.mu.Unlock()

	if w.asnPath != "" {
		if current, ok := statStamp(w.asnPath); ok && current != w.asnStamp {
			table, err := LoadASNTable(w.asnPath)
			if err != nil {
				log.Printf("asn table reload failed, keeping the previous one: %v", err)
			} else {
				w.asn.Store(table)
				w.asnStamp = current
				log.Printf("asn table loaded from %s", w.asnPath)
			}
		}
	}

	if w.geoPath != "" {
		if current, ok := statStamp(w.geoPath); ok && current != w.geoStamp {
			table, err := LoadGeoTable(w.geoPath)
			if err != nil {
				log.Printf("geoip table reload failed, keeping the previous one: %v", err)
			} else {
				w.geo.Store(table)
				w.geoStamp = current
				log.Printf("geoip table loaded from %s", w.geoPath)
			}
		}
	}
}

// watch refreshes on an interval until the process exits.
func (w *tableWatcher) watch(interval time.Duration) {
	for range time.Tick(interval) {
		w.refresh()
	}
}

func (w *tableWatcher) asnTable() *ASNTable {
	if w == nil {
		return nil
	}
	return w.asn.Load()
}

func (w *tableWatcher) geoTable() *GeoTable {
	if w == nil {
		return nil
	}
	return w.geo.Load()
}

// newTableWatcher loads both tables once, synchronously, and returns a watcher
// that will keep them current.
//
// The first load is synchronous so a router whose tables are already on disk
// serves a complete page from its very first request rather than from a minute
// later. Missing files are not an error here — refresh logs nothing for a path
// that does not exist yet, and the next poll picks it up.
func newTableWatcher(asnPath, geoPath string) *tableWatcher {
	watcher := &tableWatcher{asnPath: asnPath, geoPath: geoPath}
	watcher.refresh()
	return watcher
}
