package main

import (
	"context"
	"encoding/json"
	"net/netip"
	"os/exec"
	"sync"
	"time"
)

// How a peer is currently being treated by the router. Reported on the peers
// page so an operator can see that an address is already handled rather than
// acting on it twice, or wondering why a peer looks starved.
const (
	shapeNone      = ""
	shapeIMO       = "imo"
	shapeThrottled = "throttled"
	shapeBlocked   = "blocked"
)

// Sets consulted, in ascending order of severity. A peer can appear in more
// than one; the page shows the most severe, because that is what determines
// what actually happens to its packets.
var shapingSets = []struct {
	name  string
	class string
}{
	{"imo4", shapeIMO}, {"imo6", shapeIMO},
	{"throttle4", shapeThrottled}, {"throttle6", shapeThrottled},
	// The imo estate on a day it is being dropped rather than shaped. Reported
	// as blocked, not as the imo tier: on those days that is exactly what
	// happens to its packets, and only one of the two pairs is ever populated.
	{"imo_block4", shapeBlocked}, {"imo_block6", shapeBlocked},
	{"doh_block4", shapeBlocked}, {"doh_block6", shapeBlocked},
	{"remote_block4", shapeBlocked}, {"remote_block6", shapeBlocked},
	{"local_block4", shapeBlocked}, {"local_block6", shapeBlocked},
}

var shapeRank = map[string]int{shapeNone: 0, shapeIMO: 1, shapeThrottled: 2, shapeBlocked: 3}

// shapeIndex answers "how is this address currently treated?".
//
// Exact addresses go in a map and prefixes in a slice: the sets are dominated
// by single addresses (roughly six to one), so the map absorbs most lookups and
// the linear scan is left with the remainder.
type shapeIndex struct {
	exact    map[netip.Addr]string
	prefixes []shapePrefix
}

type shapePrefix struct {
	prefix netip.Prefix
	class  string
}

func (i *shapeIndex) classify(addr netip.Addr) string {
	if i == nil {
		return shapeNone
	}
	addr = addr.Unmap()
	best := i.exact[addr]
	for _, entry := range i.prefixes {
		if shapeRank[entry.class] > shapeRank[best] && entry.prefix.Contains(addr) {
			best = entry.class
		}
	}
	return best
}

func (i *shapeIndex) add(class string, elems []json.RawMessage) {
	for _, raw := range elems {
		var addr string
		if err := json.Unmarshal(raw, &addr); err == nil {
			parsed, err := netip.ParseAddr(addr)
			if err != nil {
				continue
			}
			parsed = parsed.Unmap()
			if shapeRank[class] > shapeRank[i.exact[parsed]] {
				i.exact[parsed] = class
			}
			continue
		}
		var wrapper struct {
			Prefix *struct {
				Addr string `json:"addr"`
				Len  int    `json:"len"`
			} `json:"prefix"`
			Range []string `json:"range"`
		}
		if err := json.Unmarshal(raw, &wrapper); err != nil {
			continue
		}
		switch {
		case wrapper.Prefix != nil:
			p, err := netip.ParsePrefix(wrapper.Prefix.Addr + "/" + itoa(wrapper.Prefix.Len))
			if err != nil {
				continue
			}
			i.prefixes = append(i.prefixes, shapePrefix{p.Masked(), class})
		case len(wrapper.Range) == 2:
			// nft can emit an arbitrary range rather than a prefix. Recorded as
			// the two endpoints only: treating a range as its lower bound would
			// silently under-report, so it is skipped unless it is a single
			// address, which is the only range form seen in practice.
			if wrapper.Range[0] == wrapper.Range[1] {
				if parsed, err := netip.ParseAddr(wrapper.Range[0]); err == nil {
					parsed = parsed.Unmap()
					if shapeRank[class] > shapeRank[i.exact[parsed]] {
						i.exact[parsed] = class
					}
				}
			}
		}
	}
}

func itoa(n int) string {
	if n == 0 {
		return "0"
	}
	var buf [4]byte
	pos := len(buf)
	for n > 0 {
		pos--
		buf[pos] = byte('0' + n%10)
		n /= 10
	}
	return string(buf[pos:])
}

// parseShapingSets builds an index from one `nft -j list set` document per set.
func parseShapingSets(docs map[string][]byte) *shapeIndex {
	index := &shapeIndex{exact: map[netip.Addr]string{}}
	for _, set := range shapingSets {
		raw, ok := docs[set.name]
		if !ok {
			continue
		}
		var doc struct {
			Nftables []struct {
				Set *struct {
					Elem []json.RawMessage `json:"elem"`
				} `json:"set"`
			} `json:"nftables"`
		}
		if err := json.Unmarshal(raw, &doc); err != nil {
			continue
		}
		for _, obj := range doc.Nftables {
			if obj.Set != nil {
				index.add(set.class, obj.Set.Elem)
			}
		}
	}
	return index
}

// shapeCache keeps a parsed index for a short while. The blocklist feeds run to
// tens of thousands of elements, and a page render is not worth re-reading them
// every time; a stale-by-seconds answer is fine for a status column.
type shapeCache struct {
	mu     sync.Mutex
	ttl    time.Duration
	index  *shapeIndex
	loaded time.Time
	read   func(ctx context.Context, set string) ([]byte, error)
}

func newShapeCache() *shapeCache {
	return &shapeCache{ttl: 30 * time.Second, read: readShapingSet}
}

func readShapingSet(ctx context.Context, set string) ([]byte, error) {
	return exec.CommandContext(ctx, "nft", "-j", "list", "set", "inet", "router-blocklists", set).Output()
}

func (c *shapeCache) get(ctx context.Context) *shapeIndex {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.index != nil && time.Since(c.loaded) < c.ttl {
		return c.index
	}
	docs := map[string][]byte{}
	for _, set := range shapingSets {
		raw, err := c.read(ctx, set.name)
		if err != nil {
			// A missing set is not an error worth failing the page for: the
			// imo sets are absent when that tier is off, and the status column
			// simply has less to say.
			continue
		}
		docs[set.name] = raw
	}
	c.index = parseShapingSets(docs)
	c.loaded = time.Now()
	return c.index
}
