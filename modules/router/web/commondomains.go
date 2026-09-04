package main

import (
	"bufio"
	"log"
	"os"
	"strings"
	"sync"
	"time"
)

// The domains a DNS review already skips, read here for a second purpose.
//
// WHY THIS EXISTS. The dark-peer collector's original test was "did anything
// resolve a name to this address", and a peer with a name was left alone. That
// is wrong, and the network proved it: 138.113.249.19 held 96% of one device's
// traffic on tcp/443 with no reverse record and every other mark of a tunnel,
// and blocky's log had resolved it 31 times — from tcdn1.driftwoodmetrics.com.
// A fronted tunnel has a hostname because it needs one; that is how its client
// finds an endpoint that moves. Treating "has a name" as "is ordinary" hands
// the better-built tunnels a free pass and catches only the ones crude enough
// to dial a bare address.
//
// What separates the two is not whether a name exists but whether it is a name
// that tells you nothing. secrets/router/dns-common-domains.txt is already
// exactly that judgement, written down and maintained: its own header sets the
// bar at "a lookup of this domain must tell you nothing you would act on", and
// it deliberately excludes multi-tenant cloud, dynamic DNS, pastebins and
// consumer VPN vendors — every category a tunnel would hide in. akamai.net,
// googlevideo.com, fbcdn.net and gvt2.com are in it, which is what silences the
// in-ISP caches and the CDN pulls that dominate a device's bytes by design.
// driftwoodmetrics.com is not, and never would be.
//
// So the same file that shortens a DNS review also decides what this collector
// stays quiet about, and adding a domain to it does both at once. That is the
// intended way to silence a false positive here: name the thing as ordinary,
// once, where the next review will also benefit.
type commonDomains struct {
	path string

	mu     sync.RWMutex
	at     stamp
	set    map[string]struct{}
	loaded bool
}

// newCommonDomains returns nil for an empty path, which is a router that was
// never given the list. See covers() for what a nil one claims.
func newCommonDomains(path string) *commonDomains {
	path = strings.TrimSpace(path)
	if path == "" {
		return nil
	}
	return &commonDomains{path: path}
}

// reload re-reads the file when it has changed.
//
// Same stamp-and-swap as the ASN and geo tables next door, and for the same
// reason: sops rewrites the decrypted file on a rebuild, and a collector that
// only read it at start-up would keep judging against the previous list until
// something restarted the service.
func (c *commonDomains) reload() {
	if c == nil {
		return
	}
	current, ok := statStamp(c.path)
	if !ok {
		return
	}
	c.mu.RLock()
	unchanged := c.loaded && c.at == current
	c.mu.RUnlock()
	if unchanged {
		return
	}

	handle, err := os.Open(c.path)
	if err != nil {
		log.Printf("common domains: open %s: %v", c.path, err)
		return
	}
	defer handle.Close()

	set := map[string]struct{}{}
	scanner := bufio.NewScanner(handle)
	for scanner.Scan() {
		// Comments run to end of line and may follow an entry, which is how
		// every other list in secrets/router is written.
		line := scanner.Text()
		if hash := strings.IndexByte(line, '#'); hash >= 0 {
			line = line[:hash]
		}
		entry := strings.ToLower(strings.Trim(strings.TrimSpace(line), "."))
		if entry == "" {
			continue
		}
		set[entry] = struct{}{}
	}
	if err := scanner.Err(); err != nil {
		log.Printf("common domains: read %s: %v", c.path, err)
		return
	}

	c.mu.Lock()
	c.set, c.at, c.loaded = set, current, true
	c.mu.Unlock()
	log.Printf("common domains: loaded %d entries from %s", len(set), c.path)
}

// watch reloads on an interval.
func (c *commonDomains) watch(interval time.Duration) {
	if c == nil {
		return
	}
	for {
		c.reload()
		time.Sleep(interval)
	}
}

// ready reports whether a list has been read at all.
//
// The caller needs this apart from covers() because the two failures mean
// opposite things. A name that is not in a loaded list is evidence; a name that
// is not in a list that failed to load is nothing at all, and treating the
// second as the first would report every CDN on the network at once.
func (c *commonDomains) ready() bool {
	if c == nil {
		return false
	}
	c.mu.RLock()
	defer c.mu.RUnlock()
	return c.loaded && len(c.set) > 0
}

// covers reports whether a name falls under one of the listed domains.
//
// Matched at label boundaries, walking up from the full name: a.b.example.com
// is covered by example.com and by b.example.com, and notexample.com is
// covered by neither. A plain suffix test would let anyone who registers
// notgoogle.com inherit google.com's exemption.
func (c *commonDomains) covers(name string) bool {
	if c == nil {
		return false
	}
	name = strings.ToLower(strings.Trim(strings.TrimSpace(name), "."))
	if name == "" {
		return false
	}
	c.mu.RLock()
	defer c.mu.RUnlock()
	for {
		if _, ok := c.set[name]; ok {
			return true
		}
		_, rest, found := strings.Cut(name, ".")
		if !found {
			return false
		}
		name = rest
	}
}
