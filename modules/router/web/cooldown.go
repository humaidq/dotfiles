package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/netip"
	"os/exec"
	"strings"
	"sync"
	"time"
)

// Cooldown — this device, off the internet, until a deadline.
//
// The page's other buttons all act on a PEER: drop this conversation, throttle
// this address, block it. This one acts on the device, and it is the only
// instrument here with an end built into it — the deadline is an nftables
// element timeout, so nothing on this side has to remember to lift it and a
// router that reboots mid-cooldown releases the device rather than keeping it
// cut off with no record of why.
//
// Everything below is a reader of that state or a caller of the `cooldown`
// tool. The enforcement is entirely in the ruleset; see
// modules/router/cooldown.nix.
const (
	cooldownTable  = "router-cooldown"
	cooldownMACSet = "cooldown_macs"
	cooldownSet4   = "cooldown4"
	cooldownSet6   = "cooldown6"
)

// Mirrors the default of sifr.router.cooldown.maxSeconds, and used only when
// the unit does not pass one. The real ceiling is the tool's, which is set from
// the same option; this copy exists so a typo in the duration box comes back as
// a 400 with a sentence explaining it rather than as a 500 carrying a shell
// tool's stderr.
const defaultMaxCooldown = 24 * time.Hour

// How long a parsed view of the cooldown sets is reused. Shorter than the
// shaping cache's half-minute: these sets are tiny, and the number this feeds
// is a countdown — a page that says "5m left" for thirty seconds after the
// cooldown ended is reporting a punishment that is over.
const cooldownCacheTTL = 5 * time.Second

// parseCooldownDuration reads what was typed into the duration box.
//
// Go's own syntax, because that is what the prompt asks for and what anyone
// reading the code will expect "5m" to mean. Two guards on top of it: whole
// seconds, since that is the resolution an nftables element timeout is set in,
// and a ceiling, since "5h" is one keystroke away from "5m" and the difference
// between them is a device that is off the network until tomorrow.
func parseCooldownDuration(text string, max time.Duration) (time.Duration, error) {
	text = strings.TrimSpace(text)
	if text == "" {
		return 0, errors.New("no duration given — try 5m, 90s or 1h30m")
	}
	parsed, err := time.ParseDuration(text)
	if err != nil {
		return 0, fmt.Errorf("cannot read %q as a duration — try 5m, 90s or 1h30m", text)
	}
	// Truncated rather than rounded: a duration is a promise about when the
	// device comes back, and rounding 4.6s up to 5s makes it a slightly longer
	// one than was asked for.
	parsed = parsed.Truncate(time.Second)
	if parsed < time.Second {
		return 0, fmt.Errorf("%s is shorter than a second", text)
	}
	if max <= 0 {
		max = defaultMaxCooldown
	}
	if parsed > max {
		return 0, fmt.Errorf("%s is longer than the %s ceiling on this router", text, max)
	}
	return parsed, nil
}

// formatCooldownArg renders a duration for the tool's command line. Whole
// seconds with an explicit unit: nft's own grammar accepts "300s" everywhere,
// and a bare number would depend on the tool's fallback rather than saying what
// it means.
func formatCooldownArg(d time.Duration) string {
	return fmt.Sprintf("%ds", int64(d/time.Second))
}

// cooldownIndex answers "is this device in cooldown, and for how much longer?".
//
// Keyed on both the MAC and the addresses because the ruleset is: the MAC is
// what the drop is really keyed on, and the addresses are what cover the return
// direction and a device with no neighbour entry. A device matching either is
// in cooldown, and the longest remaining wins — the two are written in one
// transaction and should agree, and if they ever disagree the honest answer is
// the one that says the device is still cut off.
type cooldownIndex struct {
	macs  map[string]time.Duration
	addrs map[netip.Addr]time.Duration
}

func (i *cooldownIndex) remaining(mac string, addrs []netip.Addr) (time.Duration, bool) {
	if i == nil {
		return 0, false
	}
	best, found := time.Duration(0), false
	if mac != "" {
		if left, ok := i.macs[strings.ToLower(mac)]; ok {
			best, found = left, true
		}
	}
	for _, addr := range addrs {
		left, ok := i.addrs[addr.Unmap()]
		if ok && (!found || left > best) {
			best, found = left, true
		}
	}
	return best, found
}

// parseCooldownSet folds one `nft -j list set` document into the index.
//
// Elements of a set with a timeout arrive as {"elem": {"val": "…", "timeout":
// 300, "expires": 240}}, where both figures are whole seconds. The bare form —
// a plain value, no wrapper — is accepted too so the reader does not depend on
// the set keeping its timeout flag; such an element has no deadline to report
// and counts as a cooldown with an unknown remainder rather than as no
// cooldown at all.
//
// Decoded one element at a time, for the reason shaping.go's parser does the
// same: one element this parser does not recognise would otherwise fail the
// whole document and take every good element beside it.
func (i *cooldownIndex) add(raw []byte) {
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
			var value string
			var expires int64
			if err := json.Unmarshal(elem, &value); err != nil {
				var wrapper struct {
					Elem *struct {
						Val     string `json:"val"`
						Expires int64  `json:"expires"`
					} `json:"elem"`
				}
				if err := json.Unmarshal(elem, &wrapper); err != nil || wrapper.Elem == nil {
					continue
				}
				value, expires = wrapper.Elem.Val, wrapper.Elem.Expires
			}
			left := time.Duration(expires) * time.Second
			if addr, err := netip.ParseAddr(value); err == nil {
				addr = addr.Unmap()
				if prev, ok := i.addrs[addr]; !ok || left > prev {
					i.addrs[addr] = left
				}
				continue
			}
			mac := strings.ToLower(value)
			if prev, ok := i.macs[mac]; !ok || left > prev {
				i.macs[mac] = left
			}
		}
	}
}

// cooldownCache keeps a parsed index for a few seconds. Both peers pages read
// it — the device page for its banner, the index for a badge on every row — and
// the index page would otherwise fork nft(8) three times per render.
type cooldownCache struct {
	mu     sync.Mutex
	ttl    time.Duration
	index  *cooldownIndex
	loaded time.Time
	read   func(ctx context.Context, set string) ([]byte, error)
}

func newCooldownCache() *cooldownCache {
	return &cooldownCache{ttl: cooldownCacheTTL, read: readCooldownSet}
}

func readCooldownSet(ctx context.Context, set string) ([]byte, error) {
	return exec.CommandContext(ctx, "nft", "-j", "list", "set", "inet", cooldownTable, set).Output()
}

func (c *cooldownCache) get(ctx context.Context) *cooldownIndex {
	if c == nil {
		return nil
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.index != nil && time.Since(c.loaded) < c.ttl {
		return c.index
	}
	index := &cooldownIndex{macs: map[string]time.Duration{}, addrs: map[netip.Addr]time.Duration{}}
	for _, set := range []string{cooldownMACSet, cooldownSet4, cooldownSet6} {
		// A set that cannot be read is not an error worth failing a page for:
		// the table is absent for the moment between a ruleset reload and the
		// next one, and an unreadable set simply means no badge.
		if raw, err := c.read(ctx, set); err == nil {
			index.add(raw)
		}
	}
	c.index, c.loaded = index, time.Now()
	return c.index
}

// invalidate drops the cached index so the page the button redirects to shows
// what the button just did. Without it a cooldown started at second four of the
// TTL renders as a device that is not in cooldown, which reads as the button
// having failed and invites a second press.
func (c *cooldownCache) invalidate() {
	if c == nil {
		return
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	c.index = nil
}

// cooldownState is what the template renders. Left is already formatted; Until
// is the wall-clock time it ends, which is the form anyone actually wants when
// deciding whether to wait or to lift it.
type cooldownState struct {
	Active bool
	Left   string
	Until  string
}

func (s *peersServer) cooldownFor(ctx context.Context, mac string, addrs []netip.Addr) cooldownState {
	left, ok := s.cooldowns.get(ctx).remaining(mac, addrs)
	if !ok {
		return cooldownState{}
	}
	state := cooldownState{Active: true, Left: formatDuration(left)}
	if left > 0 {
		state.Until = time.Now().Add(left).Format("15:04")
	}
	return state
}

// handleCooldownStart puts the device on the page into cooldown for the
// duration in the form.
//
// Its own handler rather than another peerAction because it is the only action
// here that carries an operator-supplied value. Everything else about it is the
// same, and deliberately so: the same origin check, the same {device} guard,
// and the same one journal line whatever happens.
func (s *peersServer) handleCooldownStart(w http.ResponseWriter, r *http.Request) {
	if !sameOrigin(w, r) {
		return
	}
	device, ok := s.device(r)
	if !ok {
		http.NotFound(w, r)
		return
	}
	duration, err := parseCooldownDuration(r.PostFormValue("duration"), s.cooldownMax)
	if err != nil {
		// Logged as well as answered: a refused cooldown is still someone
		// having tried to cut a device off, and the journal is where that
		// history is read months later.
		s.logAction("cooldown", netip.Addr{}, device, "refused: "+err.Error())
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}
	output, runErr := s.runTool("cooldown", "add", device.String(), formatCooldownArg(duration))
	result := "ok: " + duration.String()
	if runErr != nil {
		result = fmt.Sprintf("error: %v: %s", runErr, output)
	}
	s.logAction("cooldown", netip.Addr{}, device, result)
	if runErr != nil {
		http.Error(w, fmt.Sprintf("cooldown failed: %s", output), http.StatusInternalServerError)
		return
	}
	s.cooldowns.invalidate()
	http.Redirect(w, r, "/peers/"+device.String(), http.StatusSeeOther)
}

// handleCooldownEnd lets a device back on the network early.
func (s *peersServer) handleCooldownEnd(w http.ResponseWriter, r *http.Request) {
	if !sameOrigin(w, r) {
		return
	}
	device, ok := s.device(r)
	if !ok {
		http.NotFound(w, r)
		return
	}
	output, runErr := s.runTool("cooldown", "del", device.String())
	result := "ok"
	if runErr != nil {
		result = fmt.Sprintf("error: %v: %s", runErr, output)
	}
	s.logAction("cooldown-end", netip.Addr{}, device, result)
	if runErr != nil {
		http.Error(w, fmt.Sprintf("cooldown del failed: %s", output), http.StatusInternalServerError)
		return
	}
	s.cooldowns.invalidate()
	http.Redirect(w, r, "/peers/"+device.String(), http.StatusSeeOther)
}
