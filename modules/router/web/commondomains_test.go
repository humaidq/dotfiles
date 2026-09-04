package main

import (
	"os"
	"path/filepath"
	"testing"
)

func testCommonDomains(t *testing.T, body string) *commonDomains {
	t.Helper()
	path := filepath.Join(t.TempDir(), "dns-common-domains.txt")
	if err := os.WriteFile(path, []byte(body), 0o600); err != nil {
		t.Fatalf("write fixture: %v", err)
	}
	list := newCommonDomains(path)
	if list == nil {
		t.Fatal("newCommonDomains returned nil for a real path")
	}
	list.reload()
	if !list.ready() {
		t.Fatal("list did not load")
	}
	return list
}

func TestCommonDomainsCovers(t *testing.T) {
	list := testCommonDomains(t, `# Domains a DNS review can skip.
akamai.net
googlevideo.com   # the GGC caches answer for these
.gvt2.com.

`)

	covered := []string{
		"a1507.d.akamai.net",
		"AKAMAI.NET",
		"rr3---sn-xupn5a5u5x-4wge6.googlevideo.com",
		// Leading and trailing dots in the file are trimmed, and so is the
		// trailing dot a resolver puts on a name.
		"beacons5.gvt2.com.",
	}
	for _, name := range covered {
		if !list.covers(name) {
			t.Errorf("covers(%q) = false, want true", name)
		}
	}

	// The domain that started all this, plus the lookalike attack a plain
	// suffix match would let through.
	bare := []string{
		"tcdn1.driftwoodmetrics.com",
		"notakamai.net",
		"akamai.net.example.org",
		"",
	}
	for _, name := range bare {
		if list.covers(name) {
			t.Errorf("covers(%q) = true, want false", name)
		}
	}
}

// A nil list claims nothing rather than everything. The collector reads ready()
// to tell "not in the list" from "there is no list", and covers() must not
// blur the two by answering true.
func TestCommonDomainsNilIsSafe(t *testing.T) {
	var list *commonDomains
	if list.covers("akamai.net") {
		t.Error("nil list covered a domain")
	}
	if list.ready() {
		t.Error("nil list reported itself ready")
	}
	list.reload()
	if newCommonDomains("  ") != nil {
		t.Error("newCommonDomains returned non-nil for a blank path")
	}
}

// A file that is all comments loads without error and reports itself not
// ready, so a truncated deploy degrades to the blunt test rather than to
// "nothing is ordinary".
func TestCommonDomainsEmptyFileIsNotReady(t *testing.T) {
	path := filepath.Join(t.TempDir(), "empty.txt")
	if err := os.WriteFile(path, []byte("# nothing here\n\n"), 0o600); err != nil {
		t.Fatalf("write fixture: %v", err)
	}
	list := newCommonDomains(path)
	list.reload()
	if list.ready() {
		t.Error("a file with no entries reported itself ready")
	}
}

func TestCommonDomainsReloadsOnChange(t *testing.T) {
	path := filepath.Join(t.TempDir(), "dns-common-domains.txt")
	if err := os.WriteFile(path, []byte("akamai.net\n"), 0o600); err != nil {
		t.Fatalf("write fixture: %v", err)
	}
	list := newCommonDomains(path)
	list.reload()
	if list.covers("example.com") {
		t.Fatal("covered a domain that is not in the file")
	}

	if err := os.WriteFile(path, []byte("akamai.net\nexample.com\n"), 0o600); err != nil {
		t.Fatalf("rewrite fixture: %v", err)
	}
	// The stamp is size and mtime; the rewrite changes the size, so this does
	// not depend on the clock's resolution.
	list.reload()
	if !list.covers("example.com") {
		t.Error("a rewritten file was not picked up")
	}
}
