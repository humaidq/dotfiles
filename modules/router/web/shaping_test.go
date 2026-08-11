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
		{"203.0.113.10", shapeThrottled},
		{"203.0.113.20", shapeIMO},
		{"203.0.113.30", shapeBlocked},
		// The imo estate on a blocking day: dropped, so it must not read as
		// the shaped imo tier.
		{"203.0.113.40", shapeBlocked},
		{"198.51.100.7", shapeBlocked},          // inside the blocked prefix
		{"198.51.101.7", shapeNone},             // just outside it
		{"203.0.113.99", shapeNone},             // in no set
		{"2001:db8::1", shapeThrottled},         // v6 exact
		{"::ffff:203.0.113.10", shapeThrottled}, // v4-mapped must resolve to the v4 entry
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
	if got := index.classify(netip.MustParseAddr("203.0.113.10")); got != shapeThrottled {
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
	if calls != len(shapingSets) {
		t.Fatalf("read %d times, want one pass over %d sets", calls, len(shapingSets))
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
	if got := index.classify(netip.MustParseAddr("203.0.113.10")); got != shapeThrottled {
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
	if got := cache.get(context.Background()).classify(netip.MustParseAddr("203.0.113.10")); got != shapeThrottled {
		t.Fatalf("classify = %q, want %q", got, shapeThrottled)
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
