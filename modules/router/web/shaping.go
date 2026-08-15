package main

import (
	"context"
	"encoding/json"
	"net/netip"
	"os/exec"
	"strings"
	"sync"
	"time"
)

// How a peer is currently being treated by the router. Reported on the peers
// page so an operator can see that an address is already handled rather than
// acting on it twice, or wondering why a peer looks starved.
const (
	shapeNone = ""
	shapeIMO  = "imo"
	// Hyphenated, not spaced: the template uses this string as both the badge
	// label and a CSS class, and a space would silently become two classes.
	shapeQuota     = "cdn-quota"
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

// The CDN quota sits below the throttle sets rather than above them because a
// peer in throttle4 is shaped for every device unconditionally, which is the
// broader statement about what is happening to it. Both end in the same tc
// class; the ordering only decides which word the page uses when a peer is
// somehow in scope for both.
var shapeRank = map[string]int{
	shapeNone: 0, shapeIMO: 1, shapeQuota: 2, shapeThrottled: 3, shapeBlocked: 4,
}

// The pair sets the CDN volume quota writes when it actually shapes a packet.
// Unlike everything in shapingSets these are keyed on device AND peer, so they
// cannot be answered by classify() and get their own lookup — see classifyPair.
var quotaPairSets = []string{"cdn_throttled4", "cdn_throttled6"}

// tempblock keeps its rules in a table of its own rather than in the sets
// above, so the sweep over shapingSets cannot see it and a peer blocked from
// the page's own button showed no status at all.
//
// That is worse than cosmetic. conntrack tracks at prerouting priority -200,
// well ahead of the block chain at -20, so a dropped packet still creates an
// entry: a blocked app that keeps retrying reappears on the peers page showing
// traffic out and nothing back. Without a badge that reads as a block that
// failed rather than one that is working.
const (
	tempblockTable         = "router_tempblock"
	tempblockChain         = "block"
	tempblockCommentPrefix = "tempblock:"
)

func readTempblockChain(ctx context.Context) ([]byte, error) {
	return exec.CommandContext(ctx, "nft", "-j", "list", "chain",
		"inet", tempblockTable, tempblockChain).Output()
}

// addTempblockRules folds the addresses tempblock is dropping into the index.
//
// The address comes from each rule's comment rather than from its match
// expression, which buys two things: the parser touches one field instead of
// walking nft's expression tree, and — for an exact address — the two rules
// that address gets, one per direction, carry the same comment and collapse
// to one map entry for free: both writes land on i.exact[addr], the second
// one a same-rank no-op next to the first.
//
// That collapse is a property of the map write, not of the comment being
// shared, and it does not extend to the CIDR branch below. A tempblocked
// prefix appends to i.prefixes unconditionally, so its pair of rules —
// same comment, same reasoning as the exact case — really does produce two
// identical shapePrefix entries every time this function runs. Left as-is:
// classify() takes the rank-max over i.prefixes, so a duplicate entry changes
// no answer, and the whole index is rebuilt from scratch on every cache load
// rather than accumulated, so the duplicate cannot grow across reads. Worth a
// dedup only if this loop ever got expensive enough to notice, which a
// handful of temp-blocked CIDRs per router does not.
func (i *shapeIndex) addTempblockRules(raw []byte) {
	var doc struct {
		Nftables []struct {
			Rule *struct {
				Comment string `json:"comment"`
			} `json:"rule"`
		} `json:"nftables"`
	}
	if err := json.Unmarshal(raw, &doc); err != nil {
		return
	}
	for _, obj := range doc.Nftables {
		if obj.Rule == nil {
			continue
		}
		text, found := strings.CutPrefix(obj.Rule.Comment, tempblockCommentPrefix)
		if !found {
			continue
		}
		if addr, err := netip.ParseAddr(text); err == nil {
			addr = addr.Unmap()
			if shapeRank[shapeBlocked] > shapeRank[i.exact[addr]] {
				i.exact[addr] = shapeBlocked
			}
			continue
		}
		if prefix, err := netip.ParsePrefix(text); err == nil {
			i.prefixes = append(i.prefixes, shapePrefix{prefix.Masked(), shapeBlocked})
		}
	}
}

// shapeIndex answers "how is this address currently treated?".
//
// Exact addresses go in a map and prefixes in a slice: the sets are dominated
// by single addresses (roughly six to one), so the map absorbs most lookups and
// the linear scan is left with the remainder.
type shapeIndex struct {
	exact    map[netip.Addr]string
	prefixes []shapePrefix
	// Device-and-peer pairs the CDN quota is currently shaping. Exact keys
	// only: these sets hold addresses the quota rules observed, never prefixes.
	pairs map[addrPair]struct{}
}

type shapePrefix struct {
	prefix netip.Prefix
	class  string
}

type addrPair struct{ device, peer netip.Addr }

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

// classifyPair reports whether the CDN volume quota is currently shaping this
// device's traffic to this peer.
//
// Separate from classify because the answer is not a property of the peer. An
// Akamai edge is metered for a pool device that has blown its budget and
// untouched for every other device on the LAN at the same moment, so a lookup
// on the peer alone would either badge it for everyone or for no one.
func (i *shapeIndex) classifyPair(device, peer netip.Addr) string {
	if i == nil {
		return shapeNone
	}
	if _, ok := i.pairs[addrPair{device.Unmap(), peer.Unmap()}]; ok {
		return shapeQuota
	}
	return shapeNone
}

// addPairs folds one `nft -j list set` document for a concatenated set into the
// pair index. Elements arrive as {"elem": {"val": {"concat": [device, peer]},
// "expires": N}} — the elem wrapper is what a set with a timeout emits, and the
// bare {"concat": [...]} form is accepted too so the parser does not depend on
// the set keeping its timeout.
func (i *shapeIndex) addPairs(raw []byte) {
	var doc struct {
		Nftables []struct {
			Set *struct {
				// Raw, then decoded one element at a time, for the reason add()
				// does the same: a set holding one element this parser does not
				// recognise would otherwise fail to decode as a whole and take
				// every good pair beside it with it.
				Elem []json.RawMessage `json:"elem"`
			} `json:"set"`
		} `json:"nftables"`
	}
	if err := json.Unmarshal(raw, &doc); err != nil {
		return
	}
	for _, obj := range doc.Nftables {
		if obj.Set == nil {
			continue
		}
		for _, elem := range obj.Set.Elem {
			var wrapper struct {
				Concat []string `json:"concat"`
				Elem   *struct {
					Val struct {
						Concat []string `json:"concat"`
					} `json:"val"`
				} `json:"elem"`
			}
			if err := json.Unmarshal(elem, &wrapper); err != nil {
				continue
			}
			concat := wrapper.Concat
			if wrapper.Elem != nil {
				concat = wrapper.Elem.Val.Concat
			}
			if len(concat) != 2 {
				continue
			}
			device, err := netip.ParseAddr(concat[0])
			if err != nil {
				continue
			}
			peer, err := netip.ParseAddr(concat[1])
			if err != nil {
				continue
			}
			i.pairs[addrPair{device.Unmap(), peer.Unmap()}] = struct{}{}
		}
	}
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
	index := &shapeIndex{
		exact: map[netip.Addr]string{},
		pairs: map[addrPair]struct{}{},
	}
	for _, name := range quotaPairSets {
		if raw, ok := docs[name]; ok {
			index.addPairs(raw)
		}
	}
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

// readNeighbours shells out to the kernel's IPv4 neighbour table, the live
// answer to "which MAC holds this address" and the only source that notices an
// address changing hands. It is the same table the lowtrust CLI resolves from,
// and like that CLI the page falls back to the lease file when the kernel has
// evicted the entry — see render() for why that window matters.
func readNeighbours(ctx context.Context) ([]byte, error) {
	return exec.CommandContext(ctx, "ip", "-4", "neigh", "show").Output()
}

// macForDevice finds device's MAC in `ip -4 neigh show` output. Each line is
// "<addr> dev <iface> lladdr <mac> <state>"; a line with no lladdr field (the
// entry is FAILED, or incomplete) has none to find. Returning "" for that case
// rather than an error lets the caller skip the nft lookup entirely instead of
// asking it about an empty MAC.
func macForDevice(raw []byte, device netip.Addr) string {
	want := device.String()
	for _, line := range strings.Split(string(raw), "\n") {
		fields := strings.Fields(line)
		if len(fields) == 0 || fields[0] != want {
			continue
		}
		for i, f := range fields {
			if f == "lladdr" && i+1 < len(fields) {
				return fields[i+1]
			}
		}
	}
	return ""
}

// lowTrustMembership reports whether a device's MAC is in the low-trust sets.
// Returns "", "temp" or "permanent"; permanent wins, because that is what
// decides whether the page offers a remove button.
func lowTrustMembership(ctx context.Context, mac string) string {
	if mac == "" {
		return ""
	}
	for _, s := range []struct{ set, class string }{
		{"lowtrust_macs", "permanent"},
		{"lowtrust_macs_temp", "temp"},
	} {
		out, err := exec.CommandContext(ctx, "nft", "-j", "list", "set", "inet", "router-blocklists", s.set).Output()
		if err != nil {
			continue
		}
		if strings.Contains(strings.ToLower(string(out)), strings.ToLower(mac)) {
			return s.class
		}
	}
	return ""
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
	// Read separately from the sets above because tempblock's state is rules in
	// another table, which is a different nft call rather than another set
	// name. Nil in tests that do not care.
	readTempblock func(ctx context.Context) ([]byte, error)
}

func newShapeCache() *shapeCache {
	return &shapeCache{ttl: 30 * time.Second, read: readShapingSet, readTempblock: readTempblockChain}
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
	names := make([]string, 0, len(shapingSets)+len(quotaPairSets))
	for _, set := range shapingSets {
		names = append(names, set.name)
	}
	// Absent whenever the CDN quota is off, which is the same "less to say"
	// case as the imo sets below rather than a failure.
	names = append(names, quotaPairSets...)
	for _, name := range names {
		raw, err := c.read(ctx, name)
		if err != nil {
			// A missing set is not an error worth failing the page for: the
			// imo sets are absent when that tier is off, and the status column
			// simply has less to say.
			continue
		}
		docs[name] = raw
	}
	c.index = parseShapingSets(docs)
	if c.readTempblock != nil {
		// A router with no temp blocks set has no such table and nft exits
		// non-zero. That is the common case, not an error worth losing the
		// sets over.
		if raw, err := c.readTempblock(ctx); err == nil {
			c.index.addTempblockRules(raw)
		}
	}
	c.loaded = time.Now()
	return c.index
}

// invalidate drops the cached index so the next read is current.
//
// Called after a button changes what the sets and rules say. Without it the
// page the action redirects to is served from an index up to a TTL old, so a
// peer that was just blocked can still render as untouched — which reads as
// the block having failed.
func (c *shapeCache) invalidate() {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.index = nil
}
