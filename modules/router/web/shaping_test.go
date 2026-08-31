package main

import (
	"context"
	"errors"
	"net/netip"
	"strings"
	"testing"
	"time"
)

func setDoc(elems string) []byte {
	return []byte(`{"nftables":[{"set":{"name":"x","elem":[` + elems + `]}}]}`)
}

func TestShapeIndexClassifies(t *testing.T) {
	index := parseShapingSets(map[string][]byte{
		"throttle4":    setDoc(`"203.0.113.10"`),
		"imo4":         setDoc(`"203.0.113.20"`),
		"local_block4": setDoc(`"203.0.113.30",{"prefix":{"addr":"198.51.100.0","len":24}}`),
		"imo_block4":   setDoc(`"203.0.113.40"`),
		"throttle6":    setDoc(`"2001:db8::1"`),
	})

	cases := []struct{ addr, want string }{
		{"203.0.113.10", shapeGrace},
		{"203.0.113.20", shapeIMO},
		{"203.0.113.30", shapeBlocked},
		// The imo estate on a blocking day: dropped, so it must not read as
		// the shaped imo tier.
		{"203.0.113.40", shapeBlocked},
		{"198.51.100.7", shapeBlocked},      // inside the blocked prefix
		{"198.51.101.7", shapeNone},         // just outside it
		{"203.0.113.99", shapeNone},         // in no set
		{"2001:db8::1", shapeGrace},         // v6 exact
		{"::ffff:203.0.113.10", shapeGrace}, // v4-mapped must resolve to the v4 entry
	}
	for _, tc := range cases {
		t.Run(tc.addr, func(t *testing.T) {
			if got := index.classify(netip.MustParseAddr(tc.addr)); got != tc.want {
				t.Fatalf("classify(%s) = %q, want %q", tc.addr, got, tc.want)
			}
		})
	}
}

func TestShapeIndexReportsMostSevere(t *testing.T) {
	// An address present in several sets must report the severest treatment,
	// because that is what actually happens to its packets.
	index := parseShapingSets(map[string][]byte{
		"imo4":         setDoc(`"203.0.113.10"`),
		"throttle4":    setDoc(`"203.0.113.10"`),
		"local_block4": setDoc(`"203.0.113.10"`),
	})
	if got := index.classify(netip.MustParseAddr("203.0.113.10")); got != shapeBlocked {
		t.Fatalf("classify = %q, want %q", got, shapeBlocked)
	}

	// Severity must win regardless of which set a prefix came from.
	index = parseShapingSets(map[string][]byte{
		"throttle4":    setDoc(`"198.51.100.7"`),
		"local_block4": setDoc(`{"prefix":{"addr":"198.51.100.0","len":24}}`),
	})
	if got := index.classify(netip.MustParseAddr("198.51.100.7")); got != shapeBlocked {
		t.Fatalf("prefix severity: classify = %q, want %q", got, shapeBlocked)
	}
}

func TestShapeIndexNilAndMalformed(t *testing.T) {
	var nilIndex *shapeIndex
	if got := nilIndex.classify(netip.MustParseAddr("203.0.113.1")); got != shapeNone {
		t.Fatalf("nil index returned %q", got)
	}
	index := parseShapingSets(map[string][]byte{
		"throttle4": setDoc(`"not-an-address",{"prefix":{"addr":"bad","len":24}},{"unknown":1},"203.0.113.10"`),
	})
	if got := index.classify(netip.MustParseAddr("203.0.113.10")); got != shapeGrace {
		t.Fatalf("a good element beside malformed ones was lost: %q", got)
	}
}

func TestShapeCacheReadsOncePerTTL(t *testing.T) {
	calls := 0
	cache := &shapeCache{
		ttl: time.Hour,
		read: func(context.Context, string) ([]byte, error) {
			calls++
			return setDoc(`"203.0.113.10"`), nil
		},
	}
	first := cache.get(context.Background())
	second := cache.get(context.Background())
	if first != second {
		t.Fatal("second call rebuilt the index instead of using the cache")
	}
	want := len(shapingSets) + len(quotaPairSets) + len(throttlePairSets) + len(gracePairSets)
	if calls != want {
		t.Fatalf("read %d times, want one pass over %d sets", calls, want)
	}
}

func TestShapeCacheSurvivesUnreadableSets(t *testing.T) {
	cache := &shapeCache{
		ttl: time.Hour,
		read: func(_ context.Context, set string) ([]byte, error) {
			if set == "throttle4" {
				return setDoc(`"203.0.113.10"`), nil
			}
			return nil, errors.New("no such set")
		},
	}
	index := cache.get(context.Background())
	if got := index.classify(netip.MustParseAddr("203.0.113.10")); got != shapeGrace {
		t.Fatalf("a readable set was lost because others failed: %q", got)
	}
}

// ruleDoc builds the shape of `nft -j list chain inet router_tempblock block`.
func ruleDoc(comments ...string) []byte {
	parts := make([]string, 0, len(comments))
	for _, c := range comments {
		if c == "" {
			parts = append(parts, `{"rule":{"handle":1}}`)
			continue
		}
		parts = append(parts, `{"rule":{"handle":1,"comment":"`+c+`"}}`)
	}
	return []byte(`{"nftables":[` + strings.Join(parts, ",") + `]}`)
}

func TestTempblockRulesClassifyAsBlocked(t *testing.T) {
	index := parseShapingSets(nil)
	// tempblock writes two rules per address, one per direction, both carrying
	// the same comment. They must collapse to one entry.
	index.addTempblockRules(ruleDoc(
		"tempblock:203.0.113.50", "tempblock:203.0.113.50",
		"tempblock:2001:db8::9",
		"tempblock:198.51.100.0/24",
		"tempblock:not-an-address",
		"unrelated comment",
		"",
	))

	cases := []struct{ addr, want string }{
		{"203.0.113.50", shapeBlocked},
		{"2001:db8::9", shapeBlocked},
		{"198.51.100.7", shapeBlocked}, // inside the blocked prefix
		{"198.51.101.7", shapeNone},    // just outside it
		{"203.0.113.99", shapeNone},    // never blocked
	}
	for _, tc := range cases {
		t.Run(tc.addr, func(t *testing.T) {
			if got := index.classify(netip.MustParseAddr(tc.addr)); got != tc.want {
				t.Fatalf("classify(%s) = %q, want %q", tc.addr, got, tc.want)
			}
		})
	}
}

func TestTempblockRulesSurviveMalformedDocument(t *testing.T) {
	index := parseShapingSets(nil)
	index.addTempblockRules([]byte("not json"))
	if got := index.classify(netip.MustParseAddr("203.0.113.50")); got != shapeNone {
		t.Fatalf("classify = %q, want %q", got, shapeNone)
	}
}

func TestTempblockRulesOutrankAThrottle(t *testing.T) {
	// An address in throttle4 that is then temp-blocked must read as blocked:
	// that is what actually happens to its packets.
	index := parseShapingSets(map[string][]byte{"throttle4": setDoc(`"203.0.113.50"`)})
	index.addTempblockRules(ruleDoc("tempblock:203.0.113.50"))
	if got := index.classify(netip.MustParseAddr("203.0.113.50")); got != shapeBlocked {
		t.Fatalf("classify = %q, want %q", got, shapeBlocked)
	}
}

func TestShapeCacheFoldsInTempblock(t *testing.T) {
	cache := &shapeCache{
		ttl:  time.Hour,
		read: func(context.Context, string) ([]byte, error) { return nil, errors.New("absent") },
		readTempblock: func(context.Context) ([]byte, error) {
			return ruleDoc("tempblock:203.0.113.50"), nil
		},
	}
	if got := cache.get(context.Background()).classify(netip.MustParseAddr("203.0.113.50")); got != shapeBlocked {
		t.Fatalf("classify = %q, want %q", got, shapeBlocked)
	}
}

func TestShapeCacheSurvivesAbsentTempblockTable(t *testing.T) {
	// The common case: a router with no temp blocks set has no such table, and
	// nft exits non-zero. That must not cost the sets their entries.
	cache := &shapeCache{
		ttl: time.Hour,
		read: func(_ context.Context, set string) ([]byte, error) {
			if set == "throttle4" {
				return setDoc(`"203.0.113.10"`), nil
			}
			return nil, errors.New("absent")
		},
		readTempblock: func(context.Context) ([]byte, error) {
			return nil, errors.New("No such file or directory")
		},
	}
	if got := cache.get(context.Background()).classify(netip.MustParseAddr("203.0.113.10")); got != shapeGrace {
		t.Fatalf("classify = %q, want %q", got, shapeGrace)
	}
}

func TestShapeCacheInvalidateForcesAReread(t *testing.T) {
	calls := 0
	cache := &shapeCache{
		ttl: time.Hour,
		read: func(context.Context, string) ([]byte, error) {
			calls++
			return setDoc(`"203.0.113.10"`), nil
		},
	}
	cache.get(context.Background())
	first := calls
	cache.get(context.Background())
	if calls != first {
		t.Fatalf("cache re-read without being invalidated: %d then %d", first, calls)
	}
	cache.invalidate()
	cache.get(context.Background())
	if calls != first*2 {
		t.Fatalf("read %d times after invalidate, want %d", calls, first*2)
	}
}

// A concatenated set with a timeout wraps each element as
// {"elem":{"val":{"concat":[...]},"expires":N}}; one without a timeout emits
// the bare {"concat":[...]}. Both forms are accepted, so the parser does not
// break if the set ever loses its timeout.
func pairDoc(elems string) []byte {
	return []byte(`{"nftables":[{"set":{"name":"cdn_throttled4","elem":[` + elems + `]}}]}`)
}

func TestClassifyPairIsPerDeviceNotPerPeer(t *testing.T) {
	index := parseShapingSets(map[string][]byte{
		"cdn_throttled4": pairDoc(
			`{"elem":{"val":{"concat":["192.168.0.10","203.0.113.10"]},"expires":299}}`),
	})

	device := netip.MustParseAddr("192.168.0.10")
	peer := netip.MustParseAddr("203.0.113.10")
	if got := index.classifyPair(device, peer); got != shapeQuota {
		t.Fatalf("the device over its budget got %q, want %q", got, shapeQuota)
	}
	// The whole point of keying on the pair: the same Akamai edge is untouched
	// for every other device on the LAN at the same moment.
	other := netip.MustParseAddr("192.168.0.20")
	if got := index.classifyPair(other, peer); got != shapeNone {
		t.Fatalf("a device with its own budget intact got %q, want none", got)
	}
	// And the same device's other peers are not implicated either.
	elsewhere := netip.MustParseAddr("203.0.113.99")
	if got := index.classifyPair(device, elsewhere); got != shapeNone {
		t.Fatalf("an unmetered peer of a throttled device got %q, want none", got)
	}
}

func TestClassifyPairAcceptsBareConcatAndIPv6(t *testing.T) {
	index := parseShapingSets(map[string][]byte{
		"cdn_throttled4": pairDoc(`{"concat":["192.168.0.10","203.0.113.10"]}`),
		"cdn_throttled6": pairDoc(
			`{"elem":{"val":{"concat":["2001:db8::10","2606:4700::1"]},"expires":120}}`),
	})
	for _, tc := range []struct{ device, peer string }{
		{"192.168.0.10", "203.0.113.10"},
		{"2001:db8::10", "2606:4700::1"},
	} {
		got := index.classifyPair(
			netip.MustParseAddr(tc.device), netip.MustParseAddr(tc.peer))
		if got != shapeQuota {
			t.Fatalf("%s -> %s got %q, want %q", tc.device, tc.peer, got, shapeQuota)
		}
	}
}

func TestClassifyPairSurvivesMalformedElements(t *testing.T) {
	index := parseShapingSets(map[string][]byte{
		"cdn_throttled4": pairDoc(
			`{"concat":["not-an-address","203.0.113.10"]},` +
				`{"concat":["192.168.0.10"]},` +
				`"192.168.0.10",` +
				`{"concat":["192.168.0.10","203.0.113.10"]}`),
	})
	got := index.classifyPair(
		netip.MustParseAddr("192.168.0.10"), netip.MustParseAddr("203.0.113.10"))
	if got != shapeQuota {
		t.Fatalf("a good pair beside malformed ones was lost: %q", got)
	}
}

func TestQuotaOutranksNothingButLosesToABlock(t *testing.T) {
	// Both end in the same tc class, so the ordering only decides the wording.
	// A peer that is blocked outright must not be described as merely metered.
	if shapeRank[shapeQuota] <= shapeRank[shapeNone] {
		t.Fatal("the quota badge must outrank no status at all")
	}
	if shapeRank[shapeQuota] >= shapeRank[shapeBlocked] {
		t.Fatal("a blocked peer must not be reported as merely quota-shaped")
	}
}

func TestNilIndexClassifiesPairAsNone(t *testing.T) {
	var index *shapeIndex
	got := index.classifyPair(
		netip.MustParseAddr("192.168.0.10"), netip.MustParseAddr("203.0.113.10"))
	if got != shapeNone {
		t.Fatalf("nil index got %q, want none", got)
	}
}

// A grace element carries the allowance itself, which is what makes it a
// durable answer where throttle_active4's five-minute display window is not.
func graceDoc(name, elems string) []byte {
	return []byte(`{"nftables":[{"set":{"name":"` + name + `","elem":[` + elems + `]}}]}`)
}

// The reading this exists for: a pair that has spent its whole allowance is
// being marked on every packet, and reporting it as "throttle-grace" said the
// opposite about a peer ten megabytes deep.
func TestASpentGraceReadsAsThrottled(t *testing.T) {
	index := parseShapingSets(map[string][]byte{
		"throttle4": setDoc(`"139.162.42.169"`),
		"throttle_grace4": graceDoc("throttle_grace4",
			`{"elem":{"val":{"concat":["192.168.50.221","139.162.42.169"]},"expires":3599,`+
				`"quota":{"val":2,"val_unit":"mbytes","inv":true,"used":2,"used_unit":"mbytes"}}}`),
	})
	device := netip.MustParseAddr("192.168.50.221")
	peer := netip.MustParseAddr("139.162.42.169")
	if got := index.classifyPair(device, peer); got != shapeThrottled {
		t.Fatalf("a pair with its allowance spent got %q, want %q", got, shapeThrottled)
	}
	// The peer-level answer is unchanged: membership of throttle4 still says
	// only that the NEXT pair to talk to it gets an allowance first.
	if got := index.classify(peer); got != shapeGrace {
		t.Fatalf("the peer itself got %q, want %q", got, shapeGrace)
	}
}

// A pair still inside its allowance genuinely is in grace, and the peer-level
// answer already says so. Claiming it at pair level would be the same error in
// the other direction.
func TestAnUnspentGraceIsNotReportedAsThrottled(t *testing.T) {
	index := parseShapingSets(map[string][]byte{
		"throttle_grace4": graceDoc("throttle_grace4",
			`{"elem":{"val":{"concat":["192.168.50.221","139.162.42.169"]},"expires":3599,`+
				`"quota":{"val":2,"val_unit":"mbytes","inv":true,"used":152,"used_unit":"bytes"}}}`),
	})
	got := index.classifyPair(
		netip.MustParseAddr("192.168.50.221"), netip.MustParseAddr("139.162.42.169"))
	if got != shapeNone {
		t.Fatalf("a pair inside its allowance got %q, want none", got)
	}
}

// Mixed units are the normal case — nft prints the allowance in the units it
// was configured with and the usage in whichever it likes — so the comparison
// has to normalise both ends.
func TestSpentGraceComparesAcrossUnits(t *testing.T) {
	index := parseShapingSets(map[string][]byte{
		"throttle_grace6": graceDoc("throttle_grace6",
			`{"elem":{"val":{"concat":["2001:db8::10","2606:4700::1"]},`+
				`"quota":{"val":512,"val_unit":"kbytes","inv":true,"used":524288,"used_unit":"bytes"}}}`),
	})
	got := index.classifyPair(
		netip.MustParseAddr("2001:db8::10"), netip.MustParseAddr("2606:4700::1"))
	if got != shapeThrottled {
		t.Fatalf("512 kbytes used against a 512 kbyte allowance got %q, want %q",
			got, shapeThrottled)
	}
}

// A unit this code has not been taught must not be guessed at: treating it as
// bytes would report a pair with a gigabyte allowance as exhausted on its first
// megabyte.
func TestAnUnknownQuotaUnitIsIgnored(t *testing.T) {
	index := parseShapingSets(map[string][]byte{
		"throttle_grace4": graceDoc("throttle_grace4",
			`{"elem":{"val":{"concat":["192.168.50.221","139.162.42.169"]},`+
				`"quota":{"val":2,"val_unit":"tbytes","inv":true,"used":2,"used_unit":"tbytes"}}}`),
	})
	got := index.classifyPair(
		netip.MustParseAddr("192.168.50.221"), netip.MustParseAddr("139.162.42.169"))
	if got != shapeNone {
		t.Fatalf("an unreadable unit got %q, want none", got)
	}
}

// A block outranks a spent allowance, for the same reason it outranks the CDN
// quota: both end in a mark, and the more severe word is the true one.
func TestABlockOutranksASpentGrace(t *testing.T) {
	index := parseShapingSets(map[string][]byte{
		"remote_block4": setDoc(`"139.162.42.169"`),
		"throttle_grace4": graceDoc("throttle_grace4",
			`{"elem":{"val":{"concat":["192.168.50.221","139.162.42.169"]},`+
				`"quota":{"val":2,"val_unit":"mbytes","inv":true,"used":2,"used_unit":"mbytes"}}}`),
	})
	peer := netip.MustParseAddr("139.162.42.169")
	if got := index.classify(peer); got != shapeBlocked {
		t.Fatalf("a blocked peer got %q, want %q", got, shapeBlocked)
	}
	pair := index.classifyPair(netip.MustParseAddr("192.168.50.221"), peer)
	if shapeRank[pair] > shapeRank[shapeBlocked] {
		t.Fatalf("the pair answer %q outranked the block", pair)
	}
}
