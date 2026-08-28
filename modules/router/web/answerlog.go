package main

import (
	"bufio"
	"io"
	"log"
	"net/netip"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"
)

// Naming a peer that has no reverse record.
//
// A PTR is the obvious way to name an address and it is missing for exactly
// the addresses on this network that most need naming. The in-ISP CDN caches
// answer from AS5384, publish no reverse record, and never will: 5.195.173.84
// and 151.253.247.147 are Etisalat by AS and by registration, which tells a
// reader nothing about whether the flow is Instagram video or a system update.
// Google's own 172.217.118.4 is the same story from the other direction.
//
// The name is not lost, though — it just points the other way. Something on
// this LAN resolved a name and got this address back, moments before opening
// the connection the peers page is now showing. blocky writes that down (see
// sifr.router.queryLog in dns.nix) and this file reads it back as an
// address-to-name map.
//
// What this is NOT: the log is written with blocky's `fields` restricted to
// the question and the answer, so it records that something here resolved a
// name and never which device did. This reader could not attribute a lookup to
// a device if it wanted to, and it must stay that way — the peers page already
// shows which device is talking to which address, and that is a narrower claim
// than a browsing history.
//
// The name is a weaker claim than a PTR and the page says so rather than
// merging them: a PTR is what the address's operator calls it, while this is
// what somebody here asked for shortly before traffic appeared. Usually the
// same thing. Not always — one CDN address serves many names, and the last
// name resolved to it is a good guess at the current flow rather than a fact
// about it.

// How often the directory is re-read, and how much is kept.
const (
	answerLogInterval = 15 * time.Second
	// Entries held before the oldest are dropped. A CDN-heavy network resolves
	// a few thousand distinct names a day; this is sized to hold a day of them
	// without the map being able to grow without bound.
	answerLogMaxEntries = 16384
	// A cap on how much is read from one file in one pass, so a log that grew
	// unexpectedly cannot stall a refresh. Reading resumes from the offset on
	// the next pass, so nothing is skipped — it just catches up.
	answerLogMaxRead = 32 << 20
)

type answerEntry struct {
	name string
	at   time.Time
}

// answerLog maps an address to the name most recently resolved to it.
//
// A nil *answerLog answers nothing, which is what a router with the query log
// switched off gets: the peers page shows reverse names only, exactly as it
// did before this existed.
type answerLog struct {
	dir string

	mu      sync.Mutex
	entries map[netip.Addr]answerEntry
	// Where reading stopped in each file last pass, so a refresh reads only
	// what was appended. blocky writes one file per day and appends to it, so
	// without this every refresh would re-read the whole day.
	offsets map[string]int64
	now     func() time.Time
}

func newAnswerLog(dir string) *answerLog {
	if strings.TrimSpace(dir) == "" {
		return nil
	}
	return &answerLog{
		dir:     dir,
		entries: map[netip.Addr]answerEntry{},
		offsets: map[string]int64{},
		now:     time.Now,
	}
}

// Lookup returns the name most recently resolved to addr.
//
// Never blocks on anything but the mutex: the file reading happens in the
// refresh goroutine, so this is a map read on the page render path.
func (a *answerLog) Lookup(addr netip.Addr) (string, bool) {
	if a == nil {
		return "", false
	}
	a.mu.Lock()
	defer a.mu.Unlock()
	entry, ok := a.entries[addr.Unmap()]
	if !ok {
		return "", false
	}
	return entry.name, true
}

// watch refreshes on an interval until the process exits.
func (a *answerLog) watch(interval time.Duration) {
	if a == nil {
		return
	}
	for range time.Tick(interval) {
		a.refresh()
	}
}

// refresh reads whatever has been appended since the last pass.
//
// A missing or unreadable directory is not an error worth logging every
// interval: the log is opt-in, blocky may not have written the first file yet,
// and the page degrades to reverse names only.
func (a *answerLog) refresh() {
	if a == nil {
		return
	}
	names, err := filepath.Glob(filepath.Join(a.dir, "*.log"))
	if err != nil {
		return
	}
	// Oldest first, so that when two files hold the same address the newer
	// file's name is the one left in the map.
	sort.Strings(names)
	for _, name := range names {
		if err := a.readFile(name); err != nil && !os.IsNotExist(err) {
			log.Printf("answer log: %s: %v", filepath.Base(name), err)
		}
	}
	a.forgetRotated(names)
}

// forgetRotated drops offsets for files that have aged out of the directory,
// so the map does not accumulate one entry per day the router stays up.
func (a *answerLog) forgetRotated(present []string) {
	live := make(map[string]bool, len(present))
	for _, name := range present {
		live[name] = true
	}
	a.mu.Lock()
	defer a.mu.Unlock()
	for name := range a.offsets {
		if !live[name] {
			delete(a.offsets, name)
		}
	}
}

func (a *answerLog) readFile(path string) error {
	handle, err := os.Open(path)
	if err != nil {
		return err
	}
	defer handle.Close()

	info, err := handle.Stat()
	if err != nil {
		return err
	}

	a.mu.Lock()
	offset := a.offsets[path]
	a.mu.Unlock()

	// Shorter than where reading stopped means the file was replaced or
	// truncated under us. Start again from the beginning rather than seeking
	// past the end, which would silently read nothing for the life of the
	// process.
	if info.Size() < offset {
		offset = 0
	}
	if info.Size() == offset {
		return nil
	}
	if _, err := handle.Seek(offset, io.SeekStart); err != nil {
		return err
	}

	limit := min(info.Size()-offset, answerLogMaxRead)
	reader := bufio.NewReader(io.LimitReader(handle, limit))

	// Only whole lines are consumed, and the offset advances only over them.
	// blocky flushes on an interval and can leave the last line half written;
	// counting that as read would lose the record entirely, because the rest of
	// it arrives after the point reading would resume from. A bufio.Scanner
	// cannot express this — it hands back a truncated final line indistinguish-
	// ably from a complete one — which is why this reads delimiter by
	// delimiter instead.
	read := int64(0)
	found := map[netip.Addr]string{}
	for {
		line, err := reader.ReadString('\n')
		if err != nil {
			// io.EOF here means a trailing partial line, which is left
			// uncounted for the next pass. Any other error ends this file and
			// leaves the offset where the complete lines ended.
			break
		}
		read += int64(len(line))
		name, addrs := parseAnswerLine(strings.TrimRight(line, "\r\n"))
		if name == "" {
			continue
		}
		for _, addr := range addrs {
			found[addr] = name
		}
	}

	a.store(path, offset+read, found)
	return nil
}

func (a *answerLog) store(path string, offset int64, found map[netip.Addr]string) {
	a.mu.Lock()
	defer a.mu.Unlock()
	a.offsets[path] = offset
	now := a.now()
	for addr, name := range found {
		a.entries[addr] = answerEntry{name: name, at: now}
	}
	if len(a.entries) > answerLogMaxEntries {
		a.evictLocked()
	}
}

// evictLocked drops the oldest quarter of the map.
//
// A quarter rather than one entry: eviction walks the whole map, and doing
// that per insert once the cap is reached would turn every refresh into a scan
// per line. Dropping a batch amortises it.
func (a *answerLog) evictLocked() {
	type aged struct {
		addr netip.Addr
		at   time.Time
	}
	all := make([]aged, 0, len(a.entries))
	for addr, entry := range a.entries {
		all = append(all, aged{addr: addr, at: entry.at})
	}
	sort.Slice(all, func(i, j int) bool { return all[i].at.Before(all[j].at) })
	for _, entry := range all[:len(all)/4] {
		delete(a.entries, entry.addr)
	}
}

// parseAnswerLine pulls the question and its addresses out of one CSV row.
//
// blocky's csv writer emits tab-separated columns; the two that matter are the
// question name and the rendered answer set:
//
//	2026-08-28 12:33:03 <TAB> 0.0.0.0 <TAB> none <TAB> 0 <TAB> <TAB>
//	stun.l.google.com. <TAB> A (74.125.250.129) <TAB> ... <TAB> A <TAB> bingo
//
// The 0.0.0.0 and none in the client columns are not placeholders this code
// should ever learn to fill in — they are blocky blanking the fields the
// config deliberately does not log.
//
// Answers arrive as a comma-separated list of "TYPE (value)", and a CNAME
// chain puts the intermediate names in there alongside the addresses. Only A
// and AAAA are taken, and every address in the set is mapped to the question,
// because a name that resolves to four CDN addresses is equally the name of
// all four.
func parseAnswerLine(line string) (string, []netip.Addr) {
	fields := strings.Split(line, "\t")
	if len(fields) < 7 {
		return "", nil
	}
	name := strings.TrimSuffix(strings.TrimSpace(fields[5]), ".")
	if name == "" {
		return "", nil
	}
	var addrs []netip.Addr
	for record := range strings.SplitSeq(fields[6], ",") {
		record = strings.TrimSpace(record)
		open := strings.IndexByte(record, '(')
		if open < 0 || !strings.HasSuffix(record, ")") {
			continue
		}
		switch strings.TrimSpace(record[:open]) {
		case "A", "AAAA":
		default:
			continue
		}
		addr, err := netip.ParseAddr(strings.TrimSpace(record[open+1 : len(record)-1]))
		if err != nil {
			continue
		}
		// blocky's blockType is zeroIp, so a blocked name is logged as
		// resolving to 0.0.0.0 or ::. Recording that would make every blocked
		// address on the page claim the name of whichever tracker was blocked
		// most recently, which is worse than saying nothing.
		if !addr.IsValid() || addr.IsUnspecified() {
			continue
		}
		addrs = append(addrs, addr.Unmap())
	}
	if len(addrs) == 0 {
		return "", nil
	}
	return name, addrs
}
