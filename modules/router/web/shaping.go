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
	shapeQuota = "cdn-quota"
	// In a throttle set, but this device-and-peer pair has not yet spent the
	// grace allowance sifr.router.throttle.graceBytes gives it, so its packets
	// are NOT being marked yet. Membership of the set is the whole basis for
	// this one — it is what can be known from the peer alone.
	shapeGrace     = "throttle-grace"
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
	// Reported as grace rather than throttled since the tier gained an
	// allowance. Membership means the NEXT pair to talk to this peer gets
	// graceBytes at line rate first, which is not the same claim as "this
	// peer's traffic is being held back", and the page said the second one
	// while the first was true. A pair that HAS spent its allowance is
	// upgraded to shapeThrottled by classifyPair.
	{"throttle4", shapeGrace}, {"throttle6", shapeGrace},
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
// shapeGrace ranks below the CDN quota: a peer merely in scope for a future
// throttle is a weaker statement than a budget a device has already spent.
var shapeRank = map[string]int{
	shapeNone: 0, shapeIMO: 1, shapeGrace: 2, shapeQuota: 3, shapeThrottled: 4, shapeBlocked: 5,
}

// The pair sets the CDN volume quota writes when it actually shapes a packet.
// Unlike everything in shapingSets these are keyed on device AND peer, so they
// cannot be answered by classify() and get their own lookup — see classifyPair.
var quotaPairSets = []string{"cdn_throttled4", "cdn_throttled6"}

// The pair sets forward_throttle writes once a pair is over its grace
// allowance and its packets are actually being marked into the shaped class.
//
// THIS IS THE ONLY PLACE THE PROVIDER TIER BECOMES VISIBLE, which is a bigger
// gain than the grace distinction it was added for. lowtrust_asn4/6 hold about
// fifteen thousand ranges expanded from custom-lowtrust-asns.txt — far too much
// to read and index on every page render — so a peer shaped by that tier
// carried no badge at all and read as untouched. These sets are written by the
// same rules regardless of which tier matched, so one small lookup now covers
// the address lists, the published node list and the providers alike.
var throttlePairSets = []string{"throttle_active4", "throttle_active6"}

// The grace sets themselves, read for the pairs whose quota is SPENT.
//
// throttle_active4/6 above is written on the packet path and carries a
// five-minute timeout, which the set's own note calls a display window. That
// window is too short for a bursty conversation: a throttled flow that goes
// quiet for five minutes drops out, and the page falls back to the peer-level
// answer and says "throttle-grace" — which reads as "not throttled yet" about a
// pair that has spent its entire allowance and will be marked on its very next
// packet. Observed on a peer that had moved ten megabytes.
//
// The grace element outlives that by an hour and carries the quota itself, so a
// spent quota is the durable form of the same fact and is reported as
// throttled. A pair still inside its allowance is left to the peer-level
// answer, which already says grace.
var gracePairSets = []string{"throttle_grace4", "throttle_grace6"}

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
	// Device-and-peer pairs currently being shaped, mapped to which mechanism
	// is doing it — the CDN volume quota, or the throttle tier once a pair is
	// past its grace allowance. Exact keys only: these sets hold addresses the
	// rules observed, never prefixes.
	//
	// A class rather than a presence flag because a pair can be in both, and
	// the page shows the more severe. It is the same rank comparison used for
	// the address sets, applied here so the answer does not depend on which
	// set the reader happened to load first.
	pairs map[addrPair]string
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
	return i.pairs[addrPair{device.Unmap(), peer.Unmap()}]
}

// addPairs folds one `nft -j list set` document for a concatenated set into the
// pair index. Elements arrive as {"elem": {"val": {"concat": [device, peer]},
// "expires": N}} — the elem wrapper is what a set with a timeout emits, and the
// bare {"concat": [...]} form is accepted too so the parser does not depend on
// the set keeping its timeout.
func (i *shapeIndex) addPairs(raw []byte, class string) {
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
			key := addrPair{device.Unmap(), peer.Unmap()}
			if shapeRank[class] > shapeRank[i.pairs[key]] {
				i.pairs[key] = class
			}
		}
	}
}

// quotaBytes converts one of nft's quota figures to bytes. The second result is
// false for a unit this code has not been taught, which the caller treats as
// "cannot compare" rather than as zero — guessing at a unit is how a pair with
// a two-gigabyte allowance would read as exhausted.
func quotaBytes(value uint64, unit string) (uint64, bool) {
	switch unit {
	case "", "bytes":
		return value, true
	case "kbytes":
		return value << 10, true
	case "mbytes":
		return value << 20, true
	case "gbytes":
		return value << 30, true
	}
	return 0, false
}

// addSpentGrace folds one `nft -j list set` document for a grace set into the
// pair index, recording only the pairs that have used their whole allowance.
//
// Elements carry a quota alongside the concatenated key:
//
//	{"elem": {"val": {"concat": [device, peer]},
//	          "quota": {"val": 2, "val_unit": "mbytes", "used": 152,
//	                    "used_unit": "bytes", "inv": true}}}
//
// "inv" is nft's spelling of `over` and is not consulted: these sets are
// declared by this router's own ruleset, so the comparison direction is known,
// and the arithmetic below is the thing that decides.
func (i *shapeIndex) addSpentGrace(raw []byte) {
	var doc struct {
		Nftables []struct {
			Set *struct {
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
				Elem *struct {
					Val struct {
						Concat []string `json:"concat"`
					} `json:"val"`
					Quota *struct {
						Val      uint64 `json:"val"`
						ValUnit  string `json:"val_unit"`
						Used     uint64 `json:"used"`
						UsedUnit string `json:"used_unit"`
					} `json:"quota"`
				} `json:"elem"`
			}
			if err := json.Unmarshal(elem, &wrapper); err != nil {
				continue
			}
			if wrapper.Elem == nil || wrapper.Elem.Quota == nil {
				continue
			}
			concat := wrapper.Elem.Val.Concat
			if len(concat) != 2 {
				continue
			}
			allowance, ok := quotaBytes(wrapper.Elem.Quota.Val, wrapper.Elem.Quota.ValUnit)
			if !ok {
				continue
			}
			used, ok := quotaBytes(wrapper.Elem.Quota.Used, wrapper.Elem.Quota.UsedUnit)
			if !ok || used < allowance {
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
			key := addrPair{device.Unmap(), peer.Unmap()}
			if shapeRank[shapeThrottled] > shapeRank[i.pairs[key]] {
				i.pairs[key] = shapeThrottled
			}
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
		pairs: map[addrPair]string{},
	}
	for _, name := range quotaPairSets {
		if raw, ok := docs[name]; ok {
			index.addPairs(raw, shapeQuota)
		}
	}
	for _, name := range throttlePairSets {
		if raw, ok := docs[name]; ok {
			index.addPairs(raw, shapeThrottled)
		}
	}
	for _, name := range gracePairSets {
		if raw, ok := docs[name]; ok {
			index.addSpentGrace(raw)
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

// readNeighbours, macForDevice and the rest of the neighbour-table reading
// live in neighbours.go, which is also where the two address families are
// merged into one device.

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
	names := make([]string, 0, len(shapingSets)+len(quotaPairSets)+len(throttlePairSets)+len(gracePairSets))
	for _, set := range shapingSets {
		names = append(names, set.name)
	}
	// Absent whenever the CDN quota is off, which is the same "less to say"
	// case as the imo sets below rather than a failure.
	names = append(names, quotaPairSets...)
	// Absent on a router with the low-trust pool off, for the same reason.
	names = append(names, throttlePairSets...)
	// Bounded by their declared size of 65536 pairs, and in practice a few
	// hundred: these hold only the pairs that have carried traffic within the
	// last hour, not an address list.
	names = append(names, gracePairSets...)
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
