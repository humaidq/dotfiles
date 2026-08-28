package main

import (
	"context"
	"errors"
	"net"
	"net/netip"
	"sort"
	"strings"
	"sync"
	"time"
)

// Reverse DNS for the addresses in the peers table.
//
// The rule this file is built around: a page render never waits for a
// resolver. A PTR lookup is a network round trip to whatever holds the reverse
// zone, which for the addresses on this page is somewhere on the internet, and
// a table of forty peers is forty of them. Blocking the render on that turns a
// page that answers in milliseconds into one that answers in seconds, or does
// not answer at all when a nameserver blackholes rather than refuses — and the
// peers page is read when something is already wrong with the network.
//
// So the split is: handlePage reads only what is already cached, and the
// browser asks for the rest afterwards. First view of a busy device fills in a
// beat late; every view after that is server-rendered, because the cache is
// still warm. See peers.html for the browser half.
//
// Names are advisory. A PTR is set by whoever holds the reverse zone for the
// address, which for a cloud host is the tenant, so it is a claim by the peer
// about itself and not attribution the way the ASN and country columns are.
// Useful for exactly that reason — "ec2-…compute.amazonaws.com" or
// "…1e100.net" names the service where the AS only names the landlord — but it
// is not evidence and the page must not present it as such.

// How long an answer is held.
//
// PTR records change on the timescale that machines are reprovisioned, not the
// timescale a page is refreshed, so an hour is short rather than long. The
// negative TTL is much shorter because "no PTR" is also what a momentarily
// broken resolver looks like after the error has been swallowed, and a wrong
// negative held for an hour is a column that stays mysteriously empty.
const (
	rdnsTTL         = time.Hour
	rdnsNegativeTTL = 10 * time.Minute
	// Entries kept before the cache starts evicting. A busy device reaches a
	// few hundred distinct peers; this is sized so normal use never evicts,
	// and so a scan cannot grow the map without bound.
	rdnsMaxEntries = 4096
	// Concurrent in-flight lookups. The queries go to the router's own
	// resolver, which is also serving the LAN — the point of a bound here is
	// that a page of peers must not arrive as a burst that competes with real
	// traffic.
	rdnsConcurrency = 8
)

type rdnsEntry struct {
	// The name, without its trailing dot. Empty means a resolved absence: the
	// address has no PTR. That is a real answer and is cached as one, which is
	// what stops the browser asking again on every render for the majority of
	// addresses that will never have a name.
	name string
	at   time.Time
}

func (e rdnsEntry) expired(now time.Time) bool {
	ttl := rdnsTTL
	if e.name == "" {
		ttl = rdnsNegativeTTL
	}
	return now.Sub(e.at) >= ttl
}

// rdnsCache answers reverse lookups, holding what it has already learned.
//
// The zero value is not usable; call newRDNSCache. A nil *rdnsCache is
// usable and answers nothing, which is what disables the feature: no names in
// the template, and registerRoutes leaves the lookup endpoint unregistered.
type rdnsCache struct {
	mu      sync.Mutex
	entries map[netip.Addr]rdnsEntry
	// Addresses currently being resolved, so two browsers on the same page do
	// not both ask the resolver for the same address. The channel closes when
	// the answer lands.
	inflight map[netip.Addr]chan struct{}

	// The resolver call. Injectable so tests never touch DNS — and so the
	// page-render path can be proven not to call it.
	lookup func(ctx context.Context, addr netip.Addr) ([]string, error)
	// Bounds concurrent lookups. Buffered to rdnsConcurrency.
	sem chan struct{}
	// now is time.Now except in tests, which need to age entries without
	// sleeping.
	now func() time.Time
}

func newRDNSCache() *rdnsCache {
	return &rdnsCache{
		entries:  map[netip.Addr]rdnsEntry{},
		inflight: map[netip.Addr]chan struct{}{},
		lookup:   lookupAddr,
		sem:      make(chan struct{}, rdnsConcurrency),
		now:      time.Now,
	}
}

// lookupAddr is the real resolver call: the host's configured nameserver,
// which on these routers is the blocky instance on localhost.
func lookupAddr(ctx context.Context, addr netip.Addr) ([]string, error) {
	return net.DefaultResolver.LookupAddr(ctx, addr.String())
}

// cached returns what is already known about addr without ever blocking.
//
// The second return distinguishes "no answer yet" from "resolved, and there is
// no name". The template needs both: the first is what the browser is asked to
// fill in, the second must not be asked about again, and rendering them the
// same way is what would make the page re-query every nameless address on
// every load.
//
// This is the only method the render path calls, and it does no I/O.
func (c *rdnsCache) cached(addr netip.Addr) (string, bool) {
	if c == nil {
		return "", false
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	entry, ok := c.entries[addr.Unmap()]
	if !ok || entry.expired(c.now()) {
		return "", false
	}
	return entry.name, true
}

// resolve returns the name for addr, doing the lookup if it is not cached.
//
// Blocks, by design: it is called from the browser's fill-in request and from
// nowhere on the render path. Honours ctx, and a cancelled or timed-out lookup
// caches nothing — a deadline says something about the resolver's mood, not
// about whether the address has a name.
func (c *rdnsCache) resolve(ctx context.Context, addr netip.Addr) (string, bool) {
	if c == nil {
		return "", false
	}
	addr = addr.Unmap()
	if name, ok := c.cached(addr); ok {
		return name, true
	}

	// One resolver query per address at a time. A second caller waits for the
	// first's answer and then reads it from the cache, rather than issuing a
	// duplicate query — a page reload while the first fill-in is still in
	// flight is the ordinary way that happens.
	c.mu.Lock()
	if wait, busy := c.inflight[addr]; busy {
		c.mu.Unlock()
		select {
		case <-wait:
			return c.cached(addr)
		case <-ctx.Done():
			return "", false
		}
	}
	done := make(chan struct{})
	c.inflight[addr] = done
	c.mu.Unlock()

	defer func() {
		c.mu.Lock()
		delete(c.inflight, addr)
		c.mu.Unlock()
		close(done)
	}()

	select {
	case c.sem <- struct{}{}:
		defer func() { <-c.sem }()
	case <-ctx.Done():
		return "", false
	}

	names, err := c.lookup(ctx, addr)
	if err != nil {
		// A resolved absence is cached; anything else is not. NXDOMAIN and
		// NODATA both arrive here as IsNotFound, and both mean the reverse
		// zone was reached and has nothing — an answer worth keeping. A
		// timeout, a SERVFAIL or a cancelled context mean the question was
		// never answered, and caching that as "no name" would hide a name for
		// as long as the entry lived.
		var dnsErr *net.DNSError
		if errors.As(err, &dnsErr) && dnsErr.IsNotFound {
			c.store(addr, "")
			return "", true
		}
		return "", false
	}

	c.store(addr, pickName(names))
	return c.cached(addr)
}

// pickName reduces a PTR answer to the one name the column shows.
//
// Several PTRs on one address is legal and does happen on hosting ranges. The
// lowest name in sort order is taken rather than the first in the reply,
// because a resolver is free to reorder an answer set and a name that changed
// between two refreshes for no reason would read as the peer having changed.
func pickName(names []string) string {
	cleaned := make([]string, 0, len(names))
	for _, name := range names {
		name = strings.TrimSuffix(strings.TrimSpace(name), ".")
		if name != "" {
			cleaned = append(cleaned, name)
		}
	}
	if len(cleaned) == 0 {
		return ""
	}
	sort.Strings(cleaned)
	return cleaned[0]
}

// store records an answer, evicting if the map has grown past its bound.
func (c *rdnsCache) store(addr netip.Addr, name string) {
	c.mu.Lock()
	defer c.mu.Unlock()
	now := c.now()
	if len(c.entries) >= rdnsMaxEntries {
		c.evictLocked(now)
	}
	c.entries[addr] = rdnsEntry{name: name, at: now}
}

// evictLocked makes room. Expired entries go first, since dropping those costs
// nothing; if that frees none — every entry fresh, which takes more distinct
// peers in an hour than this network has — the oldest is dropped so an insert
// can still proceed. Called only on overflow, so the scan is not on any hot
// path.
func (c *rdnsCache) evictLocked(now time.Time) {
	oldest := netip.Addr{}
	oldestAt := time.Time{}
	freed := false
	for addr, entry := range c.entries {
		if entry.expired(now) {
			delete(c.entries, addr)
			freed = true
			continue
		}
		if oldestAt.IsZero() || entry.at.Before(oldestAt) {
			oldest, oldestAt = addr, entry.at
		}
	}
	if !freed && oldest.IsValid() {
		delete(c.entries, oldest)
	}
}

// resolveMany looks up several addresses at once, returning what it got.
//
// Bounded by ctx rather than by a count of successes: whatever has landed when
// the deadline passes is the answer, and the rest stay uncached for the next
// request to ask about again. Addresses that resolve after the deadline still
// populate the cache through resolve's own store, so the work is not wasted —
// it just misses this response and lands in the next render.
func (c *rdnsCache) resolveMany(ctx context.Context, addrs []netip.Addr) map[netip.Addr]string {
	found := map[netip.Addr]string{}
	if c == nil || len(addrs) == 0 {
		return found
	}

	var mu sync.Mutex
	var wg sync.WaitGroup
	for _, addr := range addrs {
		wg.Add(1)
		go func(addr netip.Addr) {
			defer wg.Done()
			name, ok := c.resolve(ctx, addr)
			if !ok {
				return
			}
			mu.Lock()
			found[addr] = name
			mu.Unlock()
		}(addr)
	}
	wg.Wait()
	return found
}
