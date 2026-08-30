package main

import (
	"fmt"
	"net/netip"
	"strings"
	"testing"
	"time"
)

// One line of blocky's console query log, in the shape the deployed config
// produces: logfmt-ish key=value pairs in blocky's own alphabetical order,
// with the client fields present and this reader ignoring them.
func answerLine(question, answer string) string {
	return "[2026-08-30 12:33:03]  INFO queryLog: query resolved " +
		"answer=" + answer + " " +
		"client_ip=192.168.50.12 client_names=some-phone instance=bingo " +
		"question_name=" + question + " question_type=A " +
		"response_code=NOERROR response_reason=RESOLVED (upstream) response_type=RESOLVED"
}

func feed(log *answerLog, lines ...string) {
	for _, line := range lines {
		log.record(line)
	}
}

func mustLookup(t *testing.T, log *answerLog, addr string) string {
	t.Helper()
	name, _ := log.Lookup(netip.MustParseAddr(addr))
	return name
}

// The case the whole feature exists for: an address with no reverse record,
// named by what somebody here resolved to reach it.
func TestAnswerLogNamesAnAddress(t *testing.T) {
	log := newAnswerLog("blocky.service")
	feed(log, answerLine("scontent.cdninstagram.com.", "A (5.195.173.84)"))

	if got := mustLookup(t, log, "5.195.173.84"); got != "scontent.cdninstagram.com" {
		t.Fatalf("name = %q, want the question with its trailing dot stripped", got)
	}
}

// A name with several addresses names all of them: a CDN name that resolves to
// four addresses is equally the name of each, and the peer table shows whichever
// one the device actually connected to.
func TestAnswerLogMapsEveryAddressInTheAnswer(t *testing.T) {
	log := newAnswerLog("blocky.service")
	feed(log, answerLine("cdn.example.com.",
		"CNAME (edge.example.net.), A (203.0.113.10), A (203.0.113.11), AAAA (2001:db8::1)"))

	for _, addr := range []string{"203.0.113.10", "203.0.113.11", "2001:db8::1"} {
		if got := mustLookup(t, log, addr); got != "cdn.example.com" {
			t.Fatalf("%s = %q, want cdn.example.com", addr, got)
		}
	}
}

// blocky's blockType is zeroIp, so every blocked name "resolves" to 0.0.0.0.
// Recording that would give any peer at 0.0.0.0 the name of whichever tracker
// was blocked most recently.
func TestAnswerLogIgnoresBlockedAnswers(t *testing.T) {
	log := newAnswerLog("blocky.service")
	feed(log,
		answerLine("tracker.example.com.", "A (0.0.0.0)"),
		answerLine("tracker6.example.com.", "AAAA (::)"))

	if len(log.entries) != 0 {
		t.Fatalf("entries = %v, want a blocked answer to be recorded as nothing", log.entries)
	}
}

// The later answer wins. One CDN address serves many names over a day, and the
// most recent one is the best guess at the flow being looked at now.
func TestAnswerLogKeepsTheMostRecentName(t *testing.T) {
	log := newAnswerLog("blocky.service")
	feed(log, answerLine("first.example.com.", "A (203.0.113.10)"))
	if got := mustLookup(t, log, "203.0.113.10"); got != "first.example.com" {
		t.Fatalf("name = %q, want first.example.com", got)
	}

	feed(log, answerLine("second.example.com.", "A (203.0.113.10)"))
	if got := mustLookup(t, log, "203.0.113.10"); got != "second.example.com" {
		t.Fatalf("name = %q, want the later answer to win", got)
	}
}

// blocky logs plenty that is not a query. Anchoring on the marker is what keeps
// a list_cache line or an upstream error from contributing stray fields.
func TestAnswerLogIgnoresNonQueryLines(t *testing.T) {
	log := newAnswerLog("blocky.service")
	feed(log,
		"[2026-08-30 09:02:06]  INFO list_cache: group import finished group=nrd total_count=2253183",
		"[2026-08-30 09:02:05] ERROR list_cache: parse error: line 707177: source=https://example.com/list.txt",
		"[2026-08-30 12:33:03]  INFO blocking disabled")

	if len(log.entries) != 0 {
		t.Fatalf("entries = %v, want nothing from lines that are not a resolved query", log.entries)
	}
}

// The map is bounded, like every other cache in this binary.
func TestAnswerLogIsBounded(t *testing.T) {
	log := newAnswerLog("blocky.service")
	log.now = func() time.Time { return time.Unix(0, 0) }
	for i := range answerLogMaxEntries + 500 {
		log.record(answerLine(
			fmt.Sprintf("host%d.example.com.", i),
			fmt.Sprintf("A (203.%d.%d.%d)", i/65536, (i/256)%256, i%256)))
	}

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
	log.backfill()
	if got := newAnswerLog("  "); got != nil {
		t.Fatal("a blank unit should disable the feature")
	}
}

// The client fields sit directly beside the question in every line, and this
// reader must not grow an interest in them. Asserted rather than left to the
// comment at the top of answerlog.go: the point of the whole arrangement is
// that no lookup here can be attributed to a device.
func TestAnswerLogDoesNotReadClientFields(t *testing.T) {
	fields := parseAnswerFields(strings.TrimPrefix(
		answerLine("a.example.com.", "A (203.0.113.10)"),
		"[2026-08-30 12:33:03]  INFO queryLog: query resolved"))

	// The parser is generic, so it does see them; what matters is that
	// parseAnswerLine returns only the name and the addresses, and there is no
	// path from a client field to anything the page renders.
	if fields["client_ip"] == "" {
		t.Fatal("test line does not carry the client fields it is meant to guard")
	}
	name, addrs := parseAnswerLine(answerLine("a.example.com.", "A (203.0.113.10)"))
	if name != "a.example.com" || len(addrs) != 1 {
		t.Fatalf("parse = %q %v, want the question and its address alone", name, addrs)
	}
}

func TestParseAnswerLine(t *testing.T) {
	cases := []struct {
		name  string
		line  string
		want  string
		addrs []string
	}{
		{"a record", answerLine("a.example.com.", "A (203.0.113.10)"),
			"a.example.com", []string{"203.0.113.10"}},
		{"aaaa record", answerLine("b.example.com.", "AAAA (2001:db8::1)"),
			"b.example.com", []string{"2001:db8::1"}},
		// A CNAME-only answer names no address, so there is nothing to record.
		{"cname only", answerLine("c.example.com.", "CNAME (other.example.net.)"), "", nil},
		{"empty answer", answerLine("d.example.com.", ""), "", nil},
		{"not a query line", "[2026-08-30 12:33:03]  INFO list_cache: group import finished", "", nil},
		{"unparseable address", answerLine("e.example.com.", "A (not-an-ip)"), "", nil},
		// The reason this does not split on whitespace: a value with spaces in
		// it must not truncate, and the field after it must still be found.
		{"value containing spaces", "query resolved answer=CNAME (x.example.net.), A (203.0.113.10) " +
			"client_ip=192.168.50.12 question_name=f.example.com. " +
			"response_reason=RESOLVED (upstream) response_type=RESOLVED",
			"f.example.com", []string{"203.0.113.10"}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			name, addrs := parseAnswerLine(tc.line)
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
