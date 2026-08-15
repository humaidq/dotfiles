package main

import (
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"
)

// Turning a conntrack countdown into "last alive".
//
// conntrack prints how many seconds are left before an entry is reaped, not
// when it last saw a packet. The kernel resets that countdown to a per-state
// maximum on every packet, so the two differ by exactly the idle time — but
// only if the maximum is known, and it is a tunable rather than a constant.
// This file reads the tunables the kernel publishes and does that subtraction.
//
// The alternative was net.netfilter.nf_conntrack_timestamp, which makes
// conntrack print delta-time. That is the flow's AGE, which is the opposite of
// useful here: a five-hour-old video call and a five-hour-old dead TCP entry
// have the same age and it is the second one the page needs to grey out. It
// would also mean turning on a sysctl for a status column.

// Where the kernel publishes the conntrack timeouts. World-readable, and the
// service is not hardened with ProcSubset, so a DynamicUser can read them.
const conntrackSysctlDir = "/proc/sys/net/netfilter"

// timeoutTable answers "how long does a fresh entry of this kind start with?".
//
// Cached because these are sysctls: they change when someone tunes them, which
// is approximately never, and re-reading a handful of files per peer per render
// would be the only reason this page touched the filesystem in a loop.
type timeoutTable struct {
	mu     sync.Mutex
	ttl    time.Duration
	loaded time.Time
	// Misses are cached alongside hits. A TCP state whose sysctl this kernel
	// does not publish would otherwise cost a failed open on every flow in
	// every render, forever, because there is nothing to cache on success.
	values map[string]timeoutValue
	read   func(name string) ([]byte, error)
}

type timeoutValue struct {
	seconds uint64
	known   bool
}

func newTimeoutTable() *timeoutTable {
	return &timeoutTable{ttl: 5 * time.Minute, read: readConntrackSysctl}
}

func readConntrackSysctl(name string) ([]byte, error) {
	return os.ReadFile(filepath.Join(conntrackSysctlDir, name))
}

func (t *timeoutTable) lookup(name string) (uint64, bool) {
	t.mu.Lock()
	defer t.mu.Unlock()
	if t.values == nil || time.Since(t.loaded) >= t.ttl {
		t.values = map[string]timeoutValue{}
		t.loaded = time.Now()
	}
	if cached, ok := t.values[name]; ok {
		return cached.seconds, cached.known
	}
	entry := timeoutValue{}
	if raw, err := t.read(name); err == nil {
		if parsed, err := strconv.ParseUint(strings.TrimSpace(string(raw)), 10, 64); err == nil {
			entry = timeoutValue{seconds: parsed, known: true}
		}
	}
	t.values[name] = entry
	return entry.seconds, entry.known
}

// timeoutSysctl names the tunable the kernel is counting this flow down from.
//
// Deliberately partial. Every protocol left out — sctp, dccp, gre, unknown —
// yields no name, which yields no idle time and a blank cell, and that is the
// intended outcome rather than a gap to fill later. A wrong maximum does not
// produce a blank cell, it produces a confident and wrong "last seen 4 days
// ago" on a live connection, which is worse than saying nothing.
func timeoutSysctl(f flow) (string, bool) {
	switch f.Proto {
	case "tcp":
		if f.State == "" {
			return "", false
		}
		// The sysctls are named after the states conntrack prints, lowercased:
		// ESTABLISHED -> nf_conntrack_tcp_timeout_established. Derived rather
		// than tabulated so a state this code has never heard of still works,
		// and so one that genuinely has no sysctl falls through to the miss
		// cache in lookup rather than to a wrong answer.
		return "nf_conntrack_tcp_timeout_" + strings.ToLower(f.State), true
	case "udp":
		// The kernel switches a udp entry from the short timeout to the long
		// one once it is ASSURED, so the flag is not decoration here: reading
		// the wrong one of the two would misdate every udp flow on the page.
		if f.Assured {
			return "nf_conntrack_udp_timeout_stream", true
		}
		return "nf_conntrack_udp_timeout", true
	case "icmp":
		return "nf_conntrack_icmp_timeout", true
	case "icmpv6":
		return "nf_conntrack_icmpv6_timeout", true
	}
	return "", false
}

// timeoutCap names a second tunable the kernel clamps this flow's countdown to,
// on top of the one its state selects.
//
// There is one such clamp and it matters enormously here. A TCP entry in
// ESTABLISHED that has not been marked ASSURED — traffic seen one way only, a
// half-open socket, a connection whose reply never came — is held to
// nf_conntrack_tcp_timeout_unacknowledged (300s by default) rather than to
// nf_conntrack_tcp_timeout_established (432000s, five days). Reading the
// uncapped maximum for those entries computes 432000 minus a countdown that
// never exceeds 300, and reports a connection last active seconds ago as
// idle for very nearly five days. That is not a rounding error, it is the
// exact opposite of the answer, and it is what this column exists to get right.
//
// Taken as a minimum rather than a substitution so the result is safe even if a
// kernel applies the clamp differently: if the clamp does not in fact apply,
// the countdown will exceed the smaller maximum and idle() blanks the cell
// rather than reporting a negative gap.
func timeoutCap(f flow) (string, bool) {
	if f.Proto == "tcp" && f.State == "ESTABLISHED" && !f.Assured {
		return "nf_conntrack_tcp_timeout_unacknowledged", true
	}
	return "", false
}

// maxTimeout returns the countdown a fresh entry for this flow starts from.
func (t *timeoutTable) maxTimeout(f flow) (uint64, bool) {
	name, ok := timeoutSysctl(f)
	if !ok {
		return 0, false
	}
	max, ok := t.lookup(name)
	if !ok {
		return 0, false
	}
	if capName, capped := timeoutCap(f); capped {
		limit, ok := t.lookup(capName)
		if !ok {
			// The clamp applies but cannot be read, so the maximum in hand is
			// known to be the wrong one. A blank cell beats a five-day answer.
			return 0, false
		}
		if limit < max {
			max = limit
		}
	}
	return max, true
}

// idle returns how long ago the flow last carried a packet.
//
// A nil table is the "no idle information" case rather than an error: tests and
// any caller that does not want the lookup pass nil and get blank cells.
func (t *timeoutTable) idle(f flow) (time.Duration, bool) {
	if t == nil || !f.HaveTimeout {
		return 0, false
	}
	max, ok := t.maxTimeout(f)
	if !ok {
		return 0, false
	}
	if f.Timeout > max {
		// The countdown is longer than the maximum it supposedly started from,
		// so the maximum is not the one this entry is using — a sysctl tuned
		// since it was cached, or a state the kernel times out by a rule other
		// than its own name. Report nothing rather than a negative idle time
		// wrapped into a very large one.
		return 0, false
	}
	return time.Duration(max-f.Timeout) * time.Second, true
}
