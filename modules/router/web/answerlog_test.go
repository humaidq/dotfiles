package main

import (
	"fmt"
	"net/netip"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// One row in blocky's csv query log, in the shape the deployed config produces:
// clientIP and clientName blanked to 0.0.0.0/none because the config does not
// log them, question at index 5, rendered answer set at index 6.
func answerRow(question, answer string) string {
	return strings.Join([]string{
		"2026-08-28 12:33:03", "0.0.0.0", "none", "0", "",
		question, answer, "", "", "A", "bingo",
	}, "\t") + "\n"
}

func writeAnswerLog(t *testing.T, dir, name, body string) string {
	t.Helper()
	path := filepath.Join(dir, name)
	if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
		t.Fatalf("write %s: %v", name, err)
	}
	return path
}

func mustLookup(t *testing.T, log *answerLog, addr string) string {
	t.Helper()
	name, _ := log.Lookup(netip.MustParseAddr(addr))
	return name
}

// The case the whole feature exists for: an address with no reverse record,
// named by what somebody here resolved to reach it.
func TestAnswerLogNamesAnAddress(t *testing.T) {
	dir := t.TempDir()
	writeAnswerLog(t, dir, "2026-08-28_ALL.log",
		answerRow("scontent.cdninstagram.com.", "A (5.195.173.84)"))

	log := newAnswerLog(dir)
	log.refresh()

	if got := mustLookup(t, log, "5.195.173.84"); got != "scontent.cdninstagram.com" {
		t.Fatalf("name = %q, want the question with its trailing dot stripped", got)
	}
}

// A name with several addresses names all of them: a CDN name that resolves to
// four addresses is equally the name of each, and the peer table shows whichever
// one the device actually connected to.
func TestAnswerLogMapsEveryAddressInTheAnswer(t *testing.T) {
	dir := t.TempDir()
	writeAnswerLog(t, dir, "2026-08-28_ALL.log",
		answerRow("cdn.example.com.",
			"CNAME (edge.example.net.), A (203.0.113.10), A (203.0.113.11), AAAA (2001:db8::1)"))

	log := newAnswerLog(dir)
	log.refresh()

	for _, addr := range []string{"203.0.113.10", "203.0.113.11", "2001:db8::1"} {
		if got := mustLookup(t, log, addr); got != "cdn.example.com" {
			t.Fatalf("%s = %q, want cdn.example.com", addr, got)
		}
	}
}

// blocky's blockType is zeroIp, so every blocked name in the log "resolves" to
// 0.0.0.0. Recording that would give any peer at 0.0.0.0 the name of whichever
// tracker was blocked most recently.
func TestAnswerLogIgnoresBlockedAnswers(t *testing.T) {
	dir := t.TempDir()
	writeAnswerLog(t, dir, "2026-08-28_ALL.log",
		answerRow("tracker.example.com.", "A (0.0.0.0)")+
			answerRow("tracker6.example.com.", "AAAA (::)"))

	log := newAnswerLog(dir)
	log.refresh()

	if len(log.entries) != 0 {
		t.Fatalf("entries = %v, want a blocked answer to be recorded as nothing", log.entries)
	}
}

// The later answer wins. One CDN address serves many names over a day, and the
// most recent one is the best guess at the flow being looked at now.
func TestAnswerLogKeepsTheMostRecentName(t *testing.T) {
	dir := t.TempDir()
	path := writeAnswerLog(t, dir, "2026-08-28_ALL.log",
		answerRow("first.example.com.", "A (203.0.113.10)"))

	log := newAnswerLog(dir)
	log.refresh()
	if got := mustLookup(t, log, "203.0.113.10"); got != "first.example.com" {
		t.Fatalf("name = %q, want first.example.com", got)
	}

	appendTo(t, path, answerRow("second.example.com.", "A (203.0.113.10)"))
	log.refresh()
	if got := mustLookup(t, log, "203.0.113.10"); got != "second.example.com" {
		t.Fatalf("name = %q, want the later answer to win", got)
	}
}

func appendTo(t *testing.T, path, body string) {
	t.Helper()
	handle, err := os.OpenFile(path, os.O_APPEND|os.O_WRONLY, 0o644)
	if err != nil {
		t.Fatalf("open %s: %v", path, err)
	}
	defer handle.Close()
	if _, err := handle.WriteString(body); err != nil {
		t.Fatalf("append: %v", err)
	}
}

// blocky appends to one file all day. Re-reading it whole on every refresh
// would be the obvious way to write this and would cost a full scan of the
// day's log every fifteen seconds.
func TestAnswerLogReadsOnlyWhatWasAppended(t *testing.T) {
	dir := t.TempDir()
	path := writeAnswerLog(t, dir, "2026-08-28_ALL.log",
		answerRow("first.example.com.", "A (203.0.113.10)"))

	log := newAnswerLog(dir)
	log.refresh()
	first := log.offsets[path]
	if first == 0 {
		t.Fatal("offset not advanced after the first read")
	}

	appendTo(t, path, answerRow("second.example.com.", "A (203.0.113.20)"))
	log.refresh()
	if log.offsets[path] <= first {
		t.Fatalf("offset = %d, want it past %d", log.offsets[path], first)
	}
	if got := mustLookup(t, log, "203.0.113.20"); got != "second.example.com" {
		t.Fatalf("appended row not read: %q", got)
	}
}

// A file that got shorter is a new file at the same path, not a file to seek
// past the end of. Getting this wrong reads nothing for the life of the
// process, silently.
func TestAnswerLogRereadsATruncatedFile(t *testing.T) {
	dir := t.TempDir()
	path := writeAnswerLog(t, dir, "2026-08-28_ALL.log",
		answerRow("first.example.com.", "A (203.0.113.10)")+
			answerRow("second.example.com.", "A (203.0.113.20)"))

	log := newAnswerLog(dir)
	log.refresh()

	writeAnswerLog(t, dir, "2026-08-28_ALL.log",
		answerRow("fresh.example.com.", "A (203.0.113.30)"))
	log.refresh()

	if got := mustLookup(t, log, "203.0.113.30"); got != "fresh.example.com" {
		t.Fatalf("name = %q, want the rewritten file to be read from the start", got)
	}
	_ = path
}

// blocky flushes on an interval and can leave a line half written. Counting it
// as read would lose it, because the rest of it arrives after the offset.
func TestAnswerLogRereadsAPartialLine(t *testing.T) {
	dir := t.TempDir()
	full := answerRow("split.example.com.", "A (203.0.113.10)")
	path := writeAnswerLog(t, dir, "2026-08-28_ALL.log", full[:len(full)-12])

	log := newAnswerLog(dir)
	log.refresh()

	// Whatever the partial line parsed to, the rest of it lands next.
	appendTo(t, path, full[len(full)-12:])
	log.refresh()

	if got := mustLookup(t, log, "203.0.113.10"); got != "split.example.com" {
		t.Fatalf("name = %q, want the completed line to be read", got)
	}
}

// Days are separate files and the newer one wins for an address in both.
func TestAnswerLogPrefersTheNewerFile(t *testing.T) {
	dir := t.TempDir()
	writeAnswerLog(t, dir, "2026-08-27_ALL.log",
		answerRow("yesterday.example.com.", "A (203.0.113.10)"))
	writeAnswerLog(t, dir, "2026-08-28_ALL.log",
		answerRow("today.example.com.", "A (203.0.113.10)"))

	log := newAnswerLog(dir)
	log.refresh()

	if got := mustLookup(t, log, "203.0.113.10"); got != "today.example.com" {
		t.Fatalf("name = %q, want today's answer", got)
	}
}

// Offsets must not accumulate one entry per day the router stays up.
func TestAnswerLogForgetsRotatedFiles(t *testing.T) {
	dir := t.TempDir()
	old := writeAnswerLog(t, dir, "2026-08-27_ALL.log",
		answerRow("yesterday.example.com.", "A (203.0.113.10)"))
	writeAnswerLog(t, dir, "2026-08-28_ALL.log",
		answerRow("today.example.com.", "A (203.0.113.20)"))

	log := newAnswerLog(dir)
	log.refresh()
	if len(log.offsets) != 2 {
		t.Fatalf("offsets = %d, want 2", len(log.offsets))
	}

	if err := os.Remove(old); err != nil {
		t.Fatalf("remove: %v", err)
	}
	log.refresh()
	if len(log.offsets) != 1 {
		t.Fatalf("offsets = %d after rotation, want 1", len(log.offsets))
	}
}

// The map is bounded, like every other cache in this binary.
func TestAnswerLogIsBounded(t *testing.T) {
	dir := t.TempDir()
	var body strings.Builder
	for i := range answerLogMaxEntries + 500 {
		body.WriteString(answerRow(
			fmt.Sprintf("host%d.example.com.", i),
			fmt.Sprintf("A (203.%d.%d.%d)", i/65536, (i/256)%256, i%256)))
	}
	writeAnswerLog(t, dir, "2026-08-28_ALL.log", body.String())

	log := newAnswerLog(dir)
	log.now = func() time.Time { return time.Unix(0, 0) }
	log.refresh()

	if len(log.entries) > answerLogMaxEntries {
		t.Fatalf("entries = %d, want at most %d", len(log.entries), answerLogMaxEntries)
	}
}

// A nil log is the feature switched off: it answers nothing and does not
// panic, because the page renders in that state on any router without the
// query log.
func TestAnswerLogNilIsUsable(t *testing.T) {
	var log *answerLog
	if name, ok := log.Lookup(netip.MustParseAddr("203.0.113.10")); ok || name != "" {
		t.Fatalf("nil log answered %q", name)
	}
	log.refresh()
	if got := newAnswerLog("  "); got != nil {
		t.Fatal("a blank directory should disable the feature")
	}
}

// A missing directory is the ordinary state before blocky has written its first
// file, not an error to fail on.
func TestAnswerLogToleratesAMissingDirectory(t *testing.T) {
	log := newAnswerLog(filepath.Join(t.TempDir(), "nope"))
	log.refresh()
	if len(log.entries) != 0 {
		t.Fatal("entries from a directory that does not exist")
	}
}

func TestParseAnswerLine(t *testing.T) {
	cases := []struct {
		name  string
		line  string
		want  string
		addrs []string
	}{
		{"a record", answerRow("a.example.com.", "A (203.0.113.10)"),
			"a.example.com", []string{"203.0.113.10"}},
		{"aaaa record", answerRow("b.example.com.", "AAAA (2001:db8::1)"),
			"b.example.com", []string{"2001:db8::1"}},
		// A CNAME-only answer names no address, so there is nothing to record.
		{"cname only", answerRow("c.example.com.", "CNAME (other.example.net.)"), "", nil},
		{"empty answer", answerRow("d.example.com.", ""), "", nil},
		{"too few columns", "one\ttwo\tthree", "", nil},
		{"unparseable address", answerRow("e.example.com.", "A (not-an-ip)"), "", nil},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			name, addrs := parseAnswerLine(strings.TrimSuffix(tc.line, "\n"))
			if name != tc.want {
				t.Fatalf("name = %q, want %q", name, tc.want)
			}
			if len(addrs) != len(tc.addrs) {
				t.Fatalf("addrs = %v, want %v", addrs, tc.addrs)
			}
			for i, want := range tc.addrs {
				if addrs[i] != netip.MustParseAddr(want) {
					t.Fatalf("addrs[%d] = %v, want %s", i, addrs[i], want)
				}
			}
		})
	}
}
