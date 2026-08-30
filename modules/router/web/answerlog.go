package main

import (
	"bufio"
	"log"
	"net/netip"
	"os/exec"
	"regexp"
	"sort"
	"strconv"
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
// THE SOURCE IS THE JOURNAL, and it was a set of csv files for two days in
// August 2026. The file was preferable for this reader — it held nothing but
// questions and answers, because blocky's `fields` was restricted to those two
// — but blocky has exactly one query log, and restricting it starved the
// twenty-one DNS panels on the router dashboard, which are built on the client
// and the block reason a restricted list removes. The log went back to the
// journal so both readers could have it.
//
// WHAT THAT MEANS FOR THIS FILE. The line now has client_ip and client_names
// sitting directly beside the question, and this reader does not look at them.
// That is a deliberate property and not an oversight to tidy up later:
// parseAnswerLine takes question_name and answer and nothing else, so no
// lookup reaching this map can be attributed to a device. The peers page
// already shows which device is talking to which address, and that is a
// narrower claim than a browsing history. Anyone tempted to widen the parse
// should note there is no caller that wants the extra fields.
//
// The name is a weaker claim than a PTR and the page says so rather than
// merging them: a PTR is what the address's operator calls it, while this is
// what somebody here asked for shortly before traffic appeared. Usually the
// same thing. Not always — one CDN address serves many names, and the last
// name resolved to it is a good guess at the current flow rather than a fact
// about it.

const (
	// How much of the journal is read before following it. The map only ever
	// answers about addresses in the connection table right now, so this needs
	// to cover the current session and not the day: a busy evening resolves a
	// few thousand names an hour, which this comfortably spans.
	answerLogBackfill = 10000
	// Entries held before the oldest are dropped. A CDN-heavy network resolves
	// a few thousand distinct names a day; this is sized to hold a day of them
	// without the map being able to grow without bound.
	answerLogMaxEntries = 16384
	// How long to wait before restarting journalctl after it exits. It should
	// not exit, so this is a backstop against a tight respawn loop rather than
	// an expected path.
	answerLogRetryDelay = 5 * time.Second
	// Lines carrying a long CNAME chain run to a few hundred bytes; a name
	// server answering with an unusually large record set could run longer,
	// and the scanner's 64KiB default would end the stream rather than skip
	// the line.
	answerLogMaxLine = 1 << 20
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
	unit string

	mu      sync.Mutex
	entries map[netip.Addr]answerEntry
	now     func() time.Time
}

func newAnswerLog(unit string) *answerLog {
	unit = strings.TrimSpace(unit)
	if unit == "" {
		return nil
	}
	return &answerLog{
		unit:    unit,
		entries: map[netip.Addr]answerEntry{},
		now:     time.Now,
	}
}

// Lookup returns the name most recently resolved to addr.
//
// Never blocks on anything but the mutex: the journal reading happens in the
// follow goroutine, so this is a map read on the page render path.
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

// backfill reads the recent journal once and returns, so the first page render
// already has names rather than waiting for the follower to see live traffic.
func (a *answerLog) backfill() {
	if a == nil {
		return
	}
	a.read(false)
}

// follow streams the journal until the process exits.
//
// Re-reads the same backfill window each time it restarts. That is deliberate
// duplicate work: the alternative is to follow from the end and lose whatever
// resolved during the gap, and rewriting a map entry with the value it already
// holds costs nothing worth saving.
func (a *answerLog) follow() {
	if a == nil {
		return
	}
	for {
		a.read(true)
		time.Sleep(answerLogRetryDelay)
	}
}

func (a *answerLog) read(follow bool) {
	args := []string{
		"--unit", a.unit,
		// Just the message. The syslog prefix journalctl would otherwise add
		// carries a second timestamp and the unit name, neither of which this
		// parses, and both of which contain characters the field scanner would
		// have to be taught to ignore.
		"--output", "cat",
		"--no-pager",
		"--lines", strconv.Itoa(answerLogBackfill),
	}
	if follow {
		args = append(args, "--follow")
	}
	cmd := exec.Command("journalctl", args...)
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		log.Printf("answer log: journalctl pipe: %v", err)
		return
	}
	if err := cmd.Start(); err != nil {
		log.Printf("answer log: start journalctl: %v", err)
		return
	}
	scanner := bufio.NewScanner(stdout)
	scanner.Buffer(make([]byte, 0, 64<<10), answerLogMaxLine)
	for scanner.Scan() {
		a.record(scanner.Text())
	}
	// A scan error ends the stream; the follow loop restarts it. Not logged
	// when following, because the ordinary way this returns is the unit being
	// restarted under us, which is not a fault.
	if err := scanner.Err(); err != nil && !follow {
		log.Printf("answer log: read journal: %v", err)
	}
	_ = cmd.Wait()
}

func (a *answerLog) record(line string) {
	name, addrs := parseAnswerLine(line)
	if name == "" {
		return
	}
	a.mu.Lock()
	defer a.mu.Unlock()
	now := a.now()
	for _, addr := range addrs {
		a.entries[addr] = answerEntry{name: name, at: now}
	}
	if len(a.entries) > answerLogMaxEntries {
		a.evictLocked()
	}
}

// evictLocked drops the oldest quarter of the map.
//
// A quarter rather than one entry: eviction walks the whole map, and doing
// that per insert once the cap is reached would turn every line into a scan.
// Dropping a batch amortises it.
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

// Where a key starts. blocky's console query log is logfmt-shaped but not
// logfmt: it writes answer=CNAME (x), A (y) and response_reason=BLOCKED
// (general), values holding spaces, commas and parentheses that no logfmt
// parser accepts. Splitting on whitespace therefore truncates exactly the
// field this file exists to read, which is why values are delimited by where
// the next key begins rather than by the next space.
var answerLogKey = regexp.MustCompile(`(?:^|\s)([a-z_][a-z0-9_]*)=`)

// parseAnswerLine pulls the question and its addresses out of one journal line.
//
//	[2026-08-30 05:59:43]  INFO queryLog: query resolved answer=A (74.125.250.129)
//	client_ip=192.168.50.12 client_names=phone instance=bingo
//	question_name=stun.l.google.com. question_type=A response_code=NOERROR
//	response_reason=RESOLVED (upstream) response_type=RESOLVED
//
// client_ip and client_names are read past deliberately — see the note at the
// top of this file. Only question_name and answer are taken.
//
// Answers arrive as a comma-separated list of "TYPE (value)", and a CNAME
// chain puts the intermediate names in there alongside the addresses. Only A
// and AAAA are taken, and every address in the set is mapped to the question,
// because a name that resolves to four CDN addresses is equally the name of
// all four.
func parseAnswerLine(line string) (string, []netip.Addr) {
	// Anchored on the marker rather than parsed from the start of the line, so
	// that blocky's other log lines — list_cache imports, upstream errors —
	// cannot contribute a stray key=value pair.
	_, rest, found := strings.Cut(line, "query resolved")
	if !found {
		return "", nil
	}
	fields := parseAnswerFields(rest)

	name := strings.TrimSuffix(strings.TrimSpace(fields["question_name"]), ".")
	if name == "" {
		return "", nil
	}
	var addrs []netip.Addr
	for record := range strings.SplitSeq(fields["answer"], ",") {
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

// parseAnswerFields splits a run of key=value pairs whose values may contain
// spaces, taking each value to run until the next key begins.
func parseAnswerFields(s string) map[string]string {
	keys := answerLogKey.FindAllStringSubmatchIndex(s, -1)
	fields := make(map[string]string, len(keys))
	for i, key := range keys {
		// key[2]:key[3] is the name; the '=' sits immediately after it.
		end := len(s)
		if i+1 < len(keys) {
			// The next match starts at the whitespace before that key, which
			// is where this value ends.
			end = keys[i+1][0]
		}
		fields[s[key[2]:key[3]]] = strings.TrimSpace(s[key[3]+1 : end])
	}
	return fields
}
