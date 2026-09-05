package main

import (
	"context"
	"html/template"
	"log"
	"net/http"
	"net/http/httptest"
	"net/netip"
	"os"
	"slices"
	"strings"
	"testing"
	"time"
)

// Real `nft -j list set` output, copied from a kernel rather than written by
// hand: the shape of the elem wrapper and the units of the expires field are
// exactly what this parser exists to get right, and a fixture invented from the
// documentation would agree with the parser and not with nft.
const (
	cooldownMACFixture = `{"nftables": [{"metainfo": {"version": "1.1.6", "release_name": "Commodore Bullmoose #7", "json_schema_version": 1}}, {"set": {"family": "inet", "name": "cooldown_macs", "table": "router-cooldown", "type": "ether_addr", "handle": 2, "flags": ["timeout"], "elem": [{"elem": {"val": "aa:bb:cc:dd:ee:01", "timeout": 300, "expires": 298}}]}}]}`
	cooldownV4Fixture  = `{"nftables": [{"metainfo": {"version": "1.1.6", "release_name": "Commodore Bullmoose #7", "json_schema_version": 1}}, {"set": {"family": "inet", "name": "cooldown4", "table": "router-cooldown", "type": "ipv4_addr", "handle": 3, "flags": ["timeout"], "elem": [{"elem": {"val": "192.168.0.20", "timeout": 60, "expires": 58}}, {"elem": {"val": "192.168.0.10", "timeout": 300, "expires": 298}}]}}]}`
	// An empty set, which is what every one of these looks like on a router
	// where nobody is in cooldown.
	cooldownEmptyFixture = `{"nftables": [{"metainfo": {"version": "1.1.6", "json_schema_version": 1}}, {"set": {"family": "inet", "name": "cooldown6", "table": "router-cooldown", "type": "ipv6_addr", "handle": 4, "flags": ["timeout"]}}]}`
)

// cooldownReaderFor answers with a fixture per set name, and errors for
// anything else — a missing set is the normal state on a router mid-reload.
func cooldownReaderFor(docs map[string]string) func(context.Context, string) ([]byte, error) {
	return func(_ context.Context, set string) ([]byte, error) {
		doc, ok := docs[set]
		if !ok {
			return nil, errFake
		}
		return []byte(doc), nil
	}
}

func testCooldownCache(docs map[string]string) *cooldownCache {
	return &cooldownCache{ttl: cooldownCacheTTL, read: cooldownReaderFor(docs)}
}

func TestParseCooldownDuration(t *testing.T) {
	max := 24 * time.Hour
	for _, tc := range []struct {
		in   string
		want time.Duration
		bad  bool
	}{
		{in: "5m", want: 5 * time.Minute},
		{in: "90s", want: 90 * time.Second},
		{in: "1h30m", want: 90 * time.Minute},
		// Whitespace is what a prompt dialog hands back when someone types with
		// a thumb; it must not be the difference between a cooldown and a 400.
		{in: "  15m\n", want: 15 * time.Minute},
		{in: "24h", want: 24 * time.Hour},
		// Truncated to whole seconds, downwards, so the device comes back no
		// later than the duration promised.
		{in: "90.6s", want: 90 * time.Second},
		// Under a second is not a cooldown, it is a typo.
		{in: "500ms", bad: true},
		{in: "0", bad: true},
		{in: "-5m", bad: true},
		// The ceiling. "5h" is one key away from "5m" and this is the guard
		// that stops the slip becoming a device that is off until tomorrow.
		{in: "48h", bad: true},
		// No unit is Go's own error, and the message says what to type.
		{in: "5", bad: true},
		{in: "later", bad: true},
		{in: "", bad: true},
		{in: "   ", bad: true},
	} {
		t.Run(tc.in, func(t *testing.T) {
			got, err := parseCooldownDuration(tc.in, max)
			if tc.bad {
				if err == nil {
					t.Fatalf("parseCooldownDuration(%q) = %s, want an error", tc.in, got)
				}
				return
			}
			if err != nil {
				t.Fatalf("parseCooldownDuration(%q): %v", tc.in, err)
			}
			if got != tc.want {
				t.Fatalf("parseCooldownDuration(%q) = %s, want %s", tc.in, got, tc.want)
			}
		})
	}
}

// A zero ceiling is what an unset environment variable produces, and it must
// mean the built-in default rather than "refuse everything".
func TestParseCooldownDurationZeroMaxUsesDefault(t *testing.T) {
	if _, err := parseCooldownDuration("1h", 0); err != nil {
		t.Fatalf("1h with no ceiling configured: %v", err)
	}
	if _, err := parseCooldownDuration("48h", 0); err == nil {
		t.Fatal("48h was accepted with no ceiling configured; the default ceiling must still apply")
	}
}

func TestFormatCooldownArg(t *testing.T) {
	for _, tc := range []struct {
		in   time.Duration
		want string
	}{
		{5 * time.Minute, "300s"},
		{90 * time.Second, "90s"},
		{time.Hour + 30*time.Minute, "5400s"},
	} {
		if got := formatCooldownArg(tc.in); got != tc.want {
			t.Fatalf("formatCooldownArg(%s) = %q, want %q", tc.in, got, tc.want)
		}
	}
}

func TestCooldownIndexReadsMACAndAddresses(t *testing.T) {
	cache := testCooldownCache(map[string]string{
		cooldownMACSet: cooldownMACFixture,
		cooldownSet4:   cooldownV4Fixture,
		cooldownSet6:   cooldownEmptyFixture,
	})
	index := cache.get(context.Background())

	// By MAC alone: the case that matters most, because it is the only handle
	// that covers a phone's IPv6 addresses.
	left, ok := index.remaining("aa:bb:cc:dd:ee:01", nil)
	if !ok || left != 298*time.Second {
		t.Fatalf("by MAC = %s, %v; want 298s, true", left, ok)
	}
	// Case-insensitively: the neighbour table and the lease file disagree about
	// case, and both feed this lookup.
	if _, ok := index.remaining("AA:BB:CC:DD:EE:01", nil); !ok {
		t.Fatal("an upper-case MAC was not found; the lease file writes them either way")
	}
	// By address alone, for a device the neighbour table has forgotten.
	left, ok = index.remaining("", []netip.Addr{netip.MustParseAddr("192.168.0.20")})
	if !ok || left != 58*time.Second {
		t.Fatalf("by address = %s, %v; want 58s, true", left, ok)
	}
	// The longest remaining wins when both match, so a page can never report a
	// device as nearly free while another element still cuts it off.
	left, ok = index.remaining("aa:bb:cc:dd:ee:01", []netip.Addr{netip.MustParseAddr("192.168.0.20")})
	if !ok || left != 298*time.Second {
		t.Fatalf("MAC and address together = %s, %v; want the longer 298s", left, ok)
	}
	if _, ok := index.remaining("aa:bb:cc:dd:ee:99", []netip.Addr{netip.MustParseAddr("192.168.0.99")}); ok {
		t.Fatal("a device in neither set reported a cooldown")
	}
}

// Every set unreadable is the state of a router with the table absent — mid
// ruleset reload, or with the feature compiled in and never used. It must read
// as "nothing is in cooldown", not as a failure and not as a panic.
func TestCooldownIndexSurvivesUnreadableSets(t *testing.T) {
	cache := testCooldownCache(nil)
	if _, ok := cache.get(context.Background()).remaining("aa:bb:cc:dd:ee:01", nil); ok {
		t.Fatal("an unreadable table reported a cooldown")
	}
}

// A nil cache is how the feature is switched off, and every reader has to
// tolerate it — this is the shape bongo runs if cooldowns are disabled.
func TestNilCooldownCacheIsUsable(t *testing.T) {
	var cache *cooldownCache
	if index := cache.get(context.Background()); index != nil {
		t.Fatal("a nil cache returned an index")
	}
	if _, ok := cache.get(context.Background()).remaining("aa:bb:cc:dd:ee:01", nil); ok {
		t.Fatal("a nil cache reported a cooldown")
	}
	cache.invalidate()
}

// An element with no timeout — which is what the set holds if the timeout flag
// is ever dropped from the ruleset — is still a device that is cut off. It has
// to read as in-cooldown-with-no-deadline rather than as free, because free is
// the answer that hides a device nobody can see is blocked.
func TestCooldownIndexReadsBareElements(t *testing.T) {
	const bare = `{"nftables": [{"set": {"name": "cooldown4", "elem": ["192.168.0.10"]}}]}`
	index := &cooldownIndex{macs: map[string]time.Duration{}, addrs: map[netip.Addr]time.Duration{}}
	index.add([]byte(bare))
	left, ok := index.remaining("", []netip.Addr{netip.MustParseAddr("192.168.0.10")})
	if !ok {
		t.Fatal("an element with no timeout read as not in cooldown")
	}
	if left != 0 {
		t.Fatalf("remaining = %s, want 0 for an element with no deadline", left)
	}
}

func TestCooldownCacheInvalidateForcesReread(t *testing.T) {
	reads := 0
	cache := &cooldownCache{ttl: time.Minute, read: func(context.Context, string) ([]byte, error) {
		reads++
		return []byte(cooldownEmptyFixture), nil
	}}
	cache.get(context.Background())
	first := reads
	cache.get(context.Background())
	if reads != first {
		t.Fatalf("a second read inside the TTL re-read the sets (%d then %d)", first, reads)
	}
	cache.invalidate()
	cache.get(context.Background())
	if reads == first {
		t.Fatal("invalidate did not force a re-read; the page after a button press would show stale state")
	}
}

func testCooldownServer(t *testing.T) *peersServer {
	t.Helper()
	server := testPeersServer(t)
	server.cooldowns = testCooldownCache(map[string]string{
		cooldownMACSet: cooldownMACFixture,
		cooldownSet4:   cooldownV4Fixture,
		cooldownSet6:   cooldownEmptyFixture,
	})
	server.cooldownMax = 24 * time.Hour
	return server
}

func TestCooldownStartRunsTool(t *testing.T) {
	server := testCooldownServer(t)
	var gotName string
	var gotArgs []string
	server.runTool = func(name string, args ...string) (string, error) {
		gotName, gotArgs = name, args
		return "cooldown: aa:bb:cc:dd:ee:01 for 5m", nil
	}

	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodPost, "/peers/192.168.0.10/cooldown",
		strings.NewReader("duration=5m"))
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	server.mux().ServeHTTP(rec, req)

	if rec.Code != http.StatusSeeOther {
		t.Fatalf("status = %d, want 303", rec.Code)
	}
	// Whole seconds with an explicit unit: what the tool and nft both take
	// without having to guess at a default.
	want := []string{"add", "192.168.0.10", "300s"}
	if gotName != "cooldown" || !slices.Equal(gotArgs, want) {
		t.Fatalf("ran %s %v, want cooldown %v", gotName, gotArgs, want)
	}
}

func TestCooldownStartRefusesBadDuration(t *testing.T) {
	for _, duration := range []string{"", "later", "5", "48h", "0s"} {
		t.Run(duration, func(t *testing.T) {
			server := testCooldownServer(t)
			called := false
			server.runTool = func(string, ...string) (string, error) {
				called = true
				return "", nil
			}
			rec := httptest.NewRecorder()
			req := httptest.NewRequest(http.MethodPost, "/peers/192.168.0.10/cooldown",
				strings.NewReader("duration="+duration))
			req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
			server.mux().ServeHTTP(rec, req)
			if called {
				t.Fatalf("the tool was invoked for duration %q", duration)
			}
			if rec.Code != http.StatusBadRequest {
				t.Fatalf("status = %d, want 400", rec.Code)
			}
		})
	}
}

// A tool that fails must not redirect to a page that then renders no cooldown,
// which reads as the button having quietly worked.
func TestCooldownStartReportsToolFailure(t *testing.T) {
	server := testCooldownServer(t)
	server.runTool = func(string, ...string) (string, error) {
		return "cooldown: no MAC and no address for 192.168.0.10", errFake
	}
	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodPost, "/peers/192.168.0.10/cooldown",
		strings.NewReader("duration=5m"))
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	server.mux().ServeHTTP(rec, req)
	if rec.Code != http.StatusInternalServerError {
		t.Fatalf("status = %d, want 500", rec.Code)
	}
	if !strings.Contains(rec.Body.String(), "no MAC and no address") {
		t.Fatalf("the tool's own words are missing from the answer: %q", rec.Body.String())
	}
}

func TestCooldownEndRunsTool(t *testing.T) {
	server := testCooldownServer(t)
	var gotName string
	var gotArgs []string
	server.runTool = func(name string, args ...string) (string, error) {
		gotName, gotArgs = name, args
		return "cooldown: released aa:bb:cc:dd:ee:01", nil
	}
	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodPost, "/peers/192.168.0.10/cooldown/end", nil)
	server.mux().ServeHTTP(rec, req)

	if rec.Code != http.StatusSeeOther {
		t.Fatalf("status = %d, want 303", rec.Code)
	}
	want := []string{"del", "192.168.0.10"}
	if gotName != "cooldown" || !slices.Equal(gotArgs, want) {
		t.Fatalf("ran %s %v, want cooldown %v", gotName, gotArgs, want)
	}
}

// The same CSRF and method guards every other mutation route carries. These are
// unauthenticated firewall mutations; a route that forgot one would be the
// whole defence gone.
func TestCooldownRoutesRefuseCrossSiteAndGET(t *testing.T) {
	for _, path := range []string{"/peers/192.168.0.10/cooldown", "/peers/192.168.0.10/cooldown/end"} {
		t.Run(path, func(t *testing.T) {
			server := testCooldownServer(t)
			called := false
			server.runTool = func(string, ...string) (string, error) { called = true; return "", nil }

			req := httptest.NewRequest(http.MethodPost, path, strings.NewReader("duration=5m"))
			req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
			req.Header.Set("Sec-Fetch-Site", "cross-site")
			rec := httptest.NewRecorder()
			server.mux().ServeHTTP(rec, req)
			if called {
				t.Fatal("the tool was invoked for a cross-site request")
			}
			if rec.Code != http.StatusForbidden {
				t.Fatalf("cross-site status = %d, want 403", rec.Code)
			}

			rec = httptest.NewRecorder()
			server.mux().ServeHTTP(rec, httptest.NewRequest(http.MethodGet, path, nil))
			if rec.Code == http.StatusSeeOther || rec.Code == http.StatusOK {
				t.Fatalf("GET on a mutation route returned %d; it must not act", rec.Code)
			}
		})
	}
}

// An address outside the LAN must not be cooled down — the same guard every
// other device route has, tested here because these two are registered
// separately from the peerAction table that carries it for the others.
func TestCooldownRoutesRejectAddressOutsideLAN(t *testing.T) {
	server := testCooldownServer(t)
	called := false
	server.runTool = func(string, ...string) (string, error) { called = true; return "", nil }
	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodPost, "/peers/203.0.113.10/cooldown",
		strings.NewReader("duration=5m"))
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	server.mux().ServeHTTP(rec, req)
	if called {
		t.Fatal("the tool was invoked for an address off this LAN")
	}
	if rec.Code != http.StatusNotFound {
		t.Fatalf("status = %d, want 404", rec.Code)
	}
}

// A router with the feature off registers neither route, so a stale bookmark
// gets a 404 rather than a 500 from a tool that is not installed.
func TestCooldownRoutesAbsentWhenDisabled(t *testing.T) {
	server := testPeersServer(t)
	server.cooldowns = nil
	for _, path := range []string{"/peers/192.168.0.10/cooldown", "/peers/192.168.0.10/cooldown/end"} {
		rec := httptest.NewRecorder()
		server.mux().ServeHTTP(rec, httptest.NewRequest(http.MethodPost, path, nil))
		if rec.Code != http.StatusNotFound {
			t.Fatalf("%s with the feature off returned %d, want 404", path, rec.Code)
		}
	}
}

func TestCooldownActionLogsToJournal(t *testing.T) {
	var buf strings.Builder
	log.SetOutput(&buf)
	log.SetFlags(0)
	t.Cleanup(func() { log.SetOutput(os.Stderr) })

	server := testCooldownServer(t)
	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodPost, "/peers/192.168.0.10/cooldown",
		strings.NewReader("duration=5m"))
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	server.mux().ServeHTTP(rec, req)

	line := buf.String()
	for _, want := range []string{
		"peer-action",
		"action=cooldown",
		// Device-wide, so there is no peer — rendered as "-" rather than as the
		// zero address's "invalid IP".
		`peer="-"`,
		`device="192.168.0.10"`,
		// The duration is in the journal, because "this device was cut off" and
		// "for twenty minutes" are not the same record.
		`result="ok: 5m0s"`,
	} {
		if !strings.Contains(line, want) {
			t.Fatalf("log line missing %q: %s", want, line)
		}
	}
}

// A refused duration is still someone having tried to cut a device off, and the
// journal is where that is read back months later.
func TestCooldownRefusalIsLogged(t *testing.T) {
	var buf strings.Builder
	log.SetOutput(&buf)
	log.SetFlags(0)
	t.Cleanup(func() { log.SetOutput(os.Stderr) })

	server := testCooldownServer(t)
	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodPost, "/peers/192.168.0.10/cooldown",
		strings.NewReader("duration=48h"))
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	server.mux().ServeHTTP(rec, req)

	if !strings.Contains(buf.String(), "refused") {
		t.Fatalf("a refused cooldown left no journal line: %s", buf.String())
	}
}

// The device page reports live set contents, so a cooldown that a reboot or a
// ruleset reload has already ended can never be rendered as still running.
func TestPeersPageShowsCooldown(t *testing.T) {
	server := testCooldownServer(t)
	server.tmpl = template.Must(template.New("peers.html").Parse(
		`enabled={{.CooldownEnabled}} active={{.Cooldown.Active}} left={{.Cooldown.Left}}`))
	// The device's own address is in cooldown4 in the fixture, and the stub
	// neighbour table has no MAC — which is exactly the sleeping-device case
	// the address sets exist for.
	rec := httptest.NewRecorder()
	server.mux().ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/peers/192.168.0.10", nil))
	if body := rec.Body.String(); !strings.Contains(body, "enabled=true active=true left=4m") {
		t.Fatalf("cooldown banner data missing: %q", body)
	}

	// And a device with nothing in the sets renders no banner at all.
	rec = httptest.NewRecorder()
	server.mux().ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/peers/192.168.0.30", nil))
	if body := rec.Body.String(); !strings.Contains(body, "active=false") {
		t.Fatalf("a device not in cooldown rendered as in one: %q", body)
	}
}

func TestPeersIndexBadgesCooldown(t *testing.T) {
	server := testCooldownServer(t)
	server.indexTmpl = template.Must(template.New("peers-index.html").Parse(
		`{{range .Leases}}{{.Addr}}={{.Cooldown}};{{end}}`))
	rec := httptest.NewRecorder()
	server.mux().ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/peers", nil))
	body := rec.Body.String()
	if !strings.Contains(body, "192.168.0.10=4m;") {
		t.Fatalf("index row missing its cooldown badge: %q", body)
	}
	// The second lease is in the set too, with less than a minute left — which
	// must render as the seconds it is, not rounded away to nothing.
	if !strings.Contains(body, "192.168.0.20=58s;") {
		t.Fatalf("index row for the second cooled device is wrong: %q", body)
	}
}

// The real template, not a fixture: the form action, the field name and the
// class the enhancement script hooks are all markup, and a fixture template
// cannot catch losing them.
func TestRealTemplateRendersCooldownControls(t *testing.T) {
	tmpl, err := template.ParseFiles("peers.html", "nav.html")
	if err != nil {
		t.Fatalf("parse peers.html: %v", err)
	}

	var idle strings.Builder
	if err := tmpl.Execute(&idle, peersPageData{Device: "192.168.0.10", CooldownEnabled: true}); err != nil {
		t.Fatalf("execute peers.html: %v", err)
	}
	for _, want := range []string{
		`action="/peers/192.168.0.10/cooldown"`,
		`class="cooldown-start"`,
		// The field the script rewrites and the form submits. Both halves have
		// to keep this name or the duration silently stops arriving.
		`name="duration"`,
		`value="15m"`,
	} {
		if !strings.Contains(idle.String(), want) {
			t.Fatalf("idle cooldown form missing %q", want)
		}
	}
	if strings.Contains(idle.String(), "/cooldown/end") {
		t.Fatal("a device not in cooldown was offered an end button")
	}

	var active strings.Builder
	err = tmpl.Execute(&active, peersPageData{
		Device:          "192.168.0.10",
		CooldownEnabled: true,
		Cooldown:        cooldownState{Active: true, Left: "12m", Until: "21:40"},
	})
	if err != nil {
		t.Fatalf("execute peers.html: %v", err)
	}
	for _, want := range []string{
		`action="/peers/192.168.0.10/cooldown/end"`,
		"12m left",
		"back at 21:40",
	} {
		if !strings.Contains(active.String(), want) {
			t.Fatalf("active cooldown banner missing %q", want)
		}
	}
	// The duration box itself, not the string `name="duration"`, which also
	// appears in the enhancement script's own selector at the foot of every
	// render of this page.
	if strings.Contains(active.String(), `id="cooldown-duration"`) {
		t.Fatal("a device already in cooldown was offered a second duration box")
	}

	// A router with the feature off renders none of it — no button promising a
	// drop that no chain implements.
	var off strings.Builder
	if err := tmpl.Execute(&off, peersPageData{Device: "192.168.0.10"}); err != nil {
		t.Fatalf("execute peers.html: %v", err)
	}
	if strings.Contains(off.String(), "/cooldown") {
		t.Fatal("the cooldown block rendered on a router with the feature off")
	}
}
