package main

import (
	"errors"
	"net/netip"
	"strings"
	"testing"
	"time"
)

// fakeTimeouts builds a table backed by a fixed set of sysctl values rather
// than /proc, and counts reads so the caching can be asserted.
func fakeTimeouts(values map[string]string, reads *int) *timeoutTable {
	return &timeoutTable{
		ttl: time.Hour,
		read: func(name string) ([]byte, error) {
			if reads != nil {
				*reads++
			}
			raw, ok := values[name]
			if !ok {
				return nil, errors.New("no such file")
			}
			return []byte(raw), nil
		},
	}
}

const (
	tcpEstablished = "nf_conntrack_tcp_timeout_established"
	udpPlain       = "nf_conntrack_udp_timeout"
	udpStream      = "nf_conntrack_udp_timeout_stream"
)

func TestIdleIsTheGapBelowTheMaximum(t *testing.T) {
	table := fakeTimeouts(map[string]string{tcpEstablished: "432000\n"}, nil)
	// Assured, because an unassured established entry is clamped to a much
	// shorter timeout — see TestUnassuredEstablishedIsCappedAtTheUnackTimeout.
	f := flow{Proto: "tcp", State: "ESTABLISHED", Timeout: 431876, HaveTimeout: true, Assured: true}
	got, ok := table.idle(f)
	if !ok {
		t.Fatal("an established tcp flow got no idle time")
	}
	if want := 124 * time.Second; got != want {
		t.Fatalf("idle = %s, want %s", got, want)
	}
}

func TestIdleIsZeroForAFlowThatJustMoved(t *testing.T) {
	// A packet resets the countdown to the maximum, so zero is a real answer
	// and must not be confused with "unknown" — the template renders one as
	// "0s" and the other as an em-dash.
	table := fakeTimeouts(map[string]string{tcpEstablished: "432000"}, nil)
	got, ok := table.idle(flow{
		Proto: "tcp", State: "ESTABLISHED", Timeout: 432000, HaveTimeout: true,
		Assured: true,
	})
	if !ok || got != 0 {
		t.Fatalf("idle = %s, ok = %v; want 0s and ok", got, ok)
	}
}

func TestUdpPicksItsTimeoutByAssuredFlag(t *testing.T) {
	// The kernel moves a udp entry onto the longer timeout once it is ASSURED.
	// Reading the wrong one of the two misdates every udp flow on the page.
	table := fakeTimeouts(map[string]string{udpPlain: "30", udpStream: "120"}, nil)

	got, ok := table.idle(flow{Proto: "udp", Timeout: 25, HaveTimeout: true})
	if !ok || got != 5*time.Second {
		t.Fatalf("unassured udp: idle = %s, ok = %v; want 5s", got, ok)
	}

	got, ok = table.idle(flow{
		Proto: "udp", Timeout: 100, HaveTimeout: true, Assured: true,
	})
	if !ok || got != 20*time.Second {
		t.Fatalf("assured udp: idle = %s, ok = %v; want 20s", got, ok)
	}
}

func TestUnknownMaximumYieldsNoAnswerRatherThanAWrongOne(t *testing.T) {
	table := fakeTimeouts(map[string]string{tcpEstablished: "432000"}, nil)
	cases := []struct {
		name string
		f    flow
	}{
		// A protocol this file deliberately does not map. Blank is the intended
		// outcome, not a gap: a guessed maximum would date the flow confidently
		// and wrongly.
		{"gre has no timeout sysctl here", flow{
			Proto: "gre", Timeout: 100, HaveTimeout: true,
		}},
		{"a tcp state with no sysctl", flow{
			Proto: "tcp", State: "SYN_SENT", Timeout: 100, HaveTimeout: true,
		}},
		{"tcp with no state printed", flow{
			Proto: "tcp", Timeout: 100, HaveTimeout: true,
		}},
		{"a line that carried no countdown", flow{
			Proto: "tcp", State: "ESTABLISHED",
		}},
		// Longer than the maximum it supposedly started from, so the maximum is
		// not the one this entry is using. Reporting nothing beats reporting a
		// negative gap wrapped into a very large positive one.
		{"countdown above the maximum", flow{
			Proto: "tcp", State: "ESTABLISHED", Timeout: 500000, HaveTimeout: true,
			Assured: true,
		}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got, ok := table.idle(tc.f); ok {
				t.Fatalf("got %s, want no answer", got)
			}
		})
	}
}

func TestNilTableReportsNoIdleTime(t *testing.T) {
	var table *timeoutTable
	if _, ok := table.idle(flow{
		Proto: "tcp", State: "ESTABLISHED", Timeout: 1, HaveTimeout: true,
		Assured: true,
	}); ok {
		t.Fatal("a nil table must report no idle time, not panic or answer")
	}
}

func TestSysctlValuesAndMissesAreBothCached(t *testing.T) {
	reads := 0
	table := fakeTimeouts(map[string]string{tcpEstablished: "432000"}, &reads)
	hit := flow{Proto: "tcp", State: "ESTABLISHED", Timeout: 1, HaveTimeout: true, Assured: true}
	// A state with no sysctl: without a negative cache this would cost a failed
	// open on every flow of every render, forever.
	miss := flow{Proto: "tcp", State: "FIN_WAIT", Timeout: 1, HaveTimeout: true, Assured: true}
	for range 5 {
		table.idle(hit)
		table.idle(miss)
	}
	if reads != 2 {
		t.Fatalf("read the sysctls %d times, want one per distinct name", reads)
	}
}

func TestSysctlNameIsDerivedFromTheState(t *testing.T) {
	for _, tc := range []struct{ state, want string }{
		{"ESTABLISHED", "nf_conntrack_tcp_timeout_established"},
		{"TIME_WAIT", "nf_conntrack_tcp_timeout_time_wait"},
		{"CLOSE_WAIT", "nf_conntrack_tcp_timeout_close_wait"},
	} {
		got, ok := timeoutSysctl(flow{Proto: "tcp", State: tc.state})
		if !ok || got != tc.want {
			t.Fatalf("%s -> %q (ok=%v), want %q", tc.state, got, ok, tc.want)
		}
	}
}

func TestSysctlValueIsParsedWithTrailingNewline(t *testing.T) {
	// /proc always hands back a trailing newline; a parser that did not trim it
	// would treat every timeout as unknown and blank the whole column.
	table := fakeTimeouts(map[string]string{udpPlain: "  30\n"}, nil)
	if _, ok := table.idle(flow{Proto: "udp", Timeout: 30, HaveTimeout: true}); !ok {
		t.Fatal("a value with surrounding whitespace was not parsed")
	}
}

// The idle time reaches the peer aggregation, and the freshest flow wins.
func TestPeerIdleTakesTheFreshestFlow(t *testing.T) {
	const fixture = `ipv4     2 tcp      6 431876 ESTABLISHED src=192.168.0.10 dst=203.0.113.10 sport=1 dport=443 packets=10 bytes=400 src=203.0.113.10 dst=198.51.100.1 sport=443 dport=1 packets=8 bytes=300 [ASSURED] mark=0 use=1
ipv4     2 tcp      6 431998 ESTABLISHED src=192.168.0.10 dst=203.0.113.10 sport=2 dport=443 packets=2 bytes=100 src=203.0.113.10 dst=198.51.100.1 sport=443 dport=2 packets=2 bytes=100 [ASSURED] mark=0 use=1
`
	table := fakeTimeouts(map[string]string{tcpEstablished: "432000"}, nil)
	peers, err := parseConntrack(strings.NewReader(fixture), newAddrSet(netip.MustParseAddr("192.168.0.10")), table)
	if err != nil {
		t.Fatalf("parse: %v", err)
	}
	if len(peers) != 1 {
		t.Fatalf("got %d peers, want 1", len(peers))
	}
	if !peers[0].HaveIdle {
		t.Fatal("the peer got no idle time")
	}
	// 432000-431998, not 432000-431876: a peer is as live as its liveliest
	// flow, or a pile of stale entries would bury the one still moving bytes.
	if want := 2 * time.Second; peers[0].Idle != want {
		t.Fatalf("idle = %s, want %s", peers[0].Idle, want)
	}
}

func TestPeerHasNoIdleWithoutATable(t *testing.T) {
	peers, err := parseConntrack(strings.NewReader(conntrackFixture), newAddrSet(netip.MustParseAddr("192.168.0.10")), nil)
	if err != nil {
		t.Fatalf("parse: %v", err)
	}
	for _, peer := range peers {
		if peer.HaveIdle {
			t.Fatalf("%s got an idle time with no timeout table", peer.Addr)
		}
	}
}

const tcpUnack = "nf_conntrack_tcp_timeout_unacknowledged"

// The regression this column shipped with: a TCP entry in ESTABLISHED that the
// kernel has not marked ASSURED is held to the unacknowledged timeout, not the
// five-day established one. Reading the wrong maximum reported a connection
// last active seconds ago as idle for very nearly five days — which is how the
// bug was noticed, as rows claiming "4d".
func TestUnassuredEstablishedIsCappedAtTheUnackTimeout(t *testing.T) {
	table := fakeTimeouts(map[string]string{
		tcpEstablished: "432000",
		tcpUnack:       "300",
	}, nil)

	got, ok := table.idle(flow{
		Proto: "tcp", State: "ESTABLISHED", Timeout: 295, HaveTimeout: true,
	})
	if !ok {
		t.Fatal("an unassured established flow got no idle time")
	}
	if want := 5 * time.Second; got != want {
		t.Fatalf("idle = %s, want %s (not 432000-295)", got, want)
	}

	// The same countdown on an ASSURED entry means something entirely
	// different: it really has been silent for days.
	got, ok = table.idle(flow{
		Proto: "tcp", State: "ESTABLISHED", Timeout: 295, HaveTimeout: true,
		Assured: true,
	})
	if !ok || got != time.Duration(432000-295)*time.Second {
		t.Fatalf("assured: idle = %s, ok = %v", got, ok)
	}
}

func TestTheCapOnlyAppliesToUnassuredEstablished(t *testing.T) {
	for _, f := range []flow{
		{Proto: "tcp", State: "ESTABLISHED", Assured: true},
		{Proto: "tcp", State: "TIME_WAIT"},
		{Proto: "udp"},
	} {
		if _, capped := timeoutCap(f); capped {
			t.Fatalf("%s/%s (assured=%v) must not be capped", f.Proto, f.State, f.Assured)
		}
	}
	if _, capped := timeoutCap(flow{Proto: "tcp", State: "ESTABLISHED"}); !capped {
		t.Fatal("unassured established must be capped")
	}
}

func TestAnUnreadableCapBlanksRatherThanOverstating(t *testing.T) {
	// The clamp applies, so the established maximum in hand is known to be the
	// wrong one. Saying nothing beats saying five days.
	table := fakeTimeouts(map[string]string{tcpEstablished: "432000"}, nil)
	if got, ok := table.idle(flow{
		Proto: "tcp", State: "ESTABLISHED", Timeout: 295, HaveTimeout: true,
	}); ok {
		t.Fatalf("got %s, want no answer when the cap cannot be read", got)
	}
}

func TestAnUncappedKernelBlanksRatherThanGoingNegative(t *testing.T) {
	// If a kernel did not apply the clamp, the countdown would run past the
	// smaller maximum. The min() must degrade to a blank cell, never wrap.
	table := fakeTimeouts(map[string]string{
		tcpEstablished: "432000",
		tcpUnack:       "300",
	}, nil)
	if got, ok := table.idle(flow{
		Proto: "tcp", State: "ESTABLISHED", Timeout: 100000, HaveTimeout: true,
	}); ok {
		t.Fatalf("got %s, want no answer", got)
	}
}

// deviceIdle is what the devices list uses, and it is deliberately looser than
// the per-device peer reader: any flow with an end on the LAN dates that end.
func TestDeviceIdleDatesBothEndsOnTheLAN(t *testing.T) {
	const fixture = `ipv4     2 tcp      6 431900 ESTABLISHED src=192.168.0.10 dst=203.0.113.10 sport=1 dport=443 packets=10 bytes=400 src=203.0.113.10 dst=198.51.100.1 sport=443 dport=1 packets=8 bytes=300 [ASSURED] mark=0 use=1
ipv4     2 udp      17 100 src=192.168.0.20 dst=192.168.0.1 sport=5353 dport=53 packets=2 bytes=200 src=192.168.0.1 dst=192.168.0.20 sport=53 dport=5353 packets=2 bytes=400 [ASSURED] mark=0 use=1
`
	table := fakeTimeouts(map[string]string{
		tcpEstablished: "432000", tcpUnack: "300", udpStream: "120", udpPlain: "30",
	}, nil)
	idle, err := deviceIdle(strings.NewReader(fixture), lanAddrs("192.168.0.0/24"), table)
	if err != nil {
		t.Fatalf("deviceIdle: %v", err)
	}

	if got, want := idle[netip.MustParseAddr("192.168.0.10")], 100*time.Second; got != want {
		t.Fatalf(".10 idle = %s, want %s", got, want)
	}
	// A DNS query to the router. The peer readers drop this flow — both ends
	// are on the LAN — but it is often the only thing an idle phone emits, so
	// for liveness it counts.
	if got, want := idle[netip.MustParseAddr("192.168.0.20")], 20*time.Second; got != want {
		t.Fatalf(".20 idle = %s, want %s", got, want)
	}
	// The public peer is not a LAN address and must not get an entry.
	if _, ok := idle[netip.MustParseAddr("203.0.113.10")]; ok {
		t.Fatal("a public peer was dated as a LAN device")
	}
}

func TestDeviceIdleKeepsTheFreshestFlowPerDevice(t *testing.T) {
	const fixture = `ipv4     2 tcp      6 200000 ESTABLISHED src=192.168.0.10 dst=203.0.113.10 sport=1 dport=443 packets=10 bytes=400 src=203.0.113.10 dst=198.51.100.1 sport=443 dport=1 packets=8 bytes=300 [ASSURED] mark=0 use=1
ipv4     2 tcp      6 431997 ESTABLISHED src=192.168.0.10 dst=203.0.113.20 sport=2 dport=443 packets=2 bytes=100 src=203.0.113.20 dst=198.51.100.1 sport=443 dport=2 packets=2 bytes=100 [ASSURED] mark=0 use=1
`
	table := fakeTimeouts(map[string]string{tcpEstablished: "432000", tcpUnack: "300"}, nil)
	idle, err := deviceIdle(strings.NewReader(fixture), lanAddrs("192.168.0.0/24"), table)
	if err != nil {
		t.Fatalf("deviceIdle: %v", err)
	}
	if got, want := idle[netip.MustParseAddr("192.168.0.10")], 3*time.Second; got != want {
		t.Fatalf("idle = %s, want %s — a stale flow buried a live one", got, want)
	}
}

func TestDeviceIdleOmitsWhatItCannotDate(t *testing.T) {
	// gre has no timeout sysctl this code maps, so the device gets no entry at
	// all rather than a zero that would render as "just now".
	const fixture = `ipv4     2 unknown  47 500 src=192.168.0.10 dst=203.0.113.10 packets=10 bytes=400 src=203.0.113.10 dst=198.51.100.1 packets=8 bytes=300 mark=0 use=1
`
	table := fakeTimeouts(map[string]string{tcpEstablished: "432000"}, nil)
	idle, err := deviceIdle(strings.NewReader(fixture), lanAddrs("192.168.0.0/24"), table)
	if err != nil {
		t.Fatalf("deviceIdle: %v", err)
	}
	if _, ok := idle[netip.MustParseAddr("192.168.0.10")]; ok {
		t.Fatal("an undatable flow produced an entry")
	}
}

// lanAddrs builds the interest set the devices index passes to deviceIdle, from
// a prefix, for tests that predate the set. Real callers build it from the
// neighbour table instead, which is the point of the change: an IPv6 address is
// in no prefix this program is configured with.
func lanAddrs(prefix string) addrSet {
	p := netip.MustParsePrefix(prefix)
	set := newAddrSet()
	for addr := p.Addr(); p.Contains(addr); addr = addr.Next() {
		set.add(addr)
	}
	return set
}
