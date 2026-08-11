package main

import (
	"context"
	"errors"
	"net/netip"
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
		"throttle6":    setDoc(`"2001:db8::1"`),
	})

	cases := []struct{ addr, want string }{
		{"203.0.113.10", shapeThrottled},
		{"203.0.113.20", shapeIMO},
		{"203.0.113.30", shapeBlocked},
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
