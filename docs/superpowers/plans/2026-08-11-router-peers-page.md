# Router Peers Page Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Serve a mesh-only page on each router listing a LAN device's current peers with ASN attribution, and a throttle or block button per peer.

**Architecture:** The existing `router-web` Go service gains a second `http.Server` bound to the router's mesh address, carrying the peers routes; the LAN listener keeps serving only the landing page. Peers come from `conntrack -L -o extended` aggregated per peer, annotated from a vendored `ip2asn-combined.tsv` read at startup. Mutations shell out to the existing `tempthrottle` and `tempblock` scripts and log one structured line to the journal.

**Tech Stack:** Go 1.24.2, standard library only (no new module dependencies). NixOS module wiring in `modules/router/web.nix`. Existing `tempthrottle` / `tempblock` bash tools.

## Global Constraints

- Spec: `docs/superpowers/specs/2026-08-11-router-peers-page-design.md`. Read it before starting.
- **Standard library only.** `modules/router/web/go.mod` has no dependencies and `vendorHash = null`. Adding a dependency breaks the Nix build.
- Go version is `1.24.2`, declared in `go.mod`. Do not raise it.
- Package is `main` throughout `modules/router/web/`.
- Live data only. No persistence, no history, no writes to any tracked list file.
- Mutations are **POST only**. Never wire a mutation to GET.
- Peers must be public addresses. RFC1918, loopback, link-local, multicast and unspecified are refused.
- The repository is public. No device names, no real capture data, no household addresses in code, tests, fixtures or comments. Test fixtures use documentation ranges (`203.0.113.0/24`, `198.51.100.0/24`) and generic RFC1918 (`192.168.0.0/24`).
- Commit with `--no-gpg-sign` (the signing key is a hardware key unavailable to an agent session).
- `nix build .#nixosConfigurations.bingo.config.system.build.toplevel` runs `go test` via `buildGoModule`'s check phase. That is the integration gate.

## File Structure

| File | Responsibility |
|---|---|
| `modules/router/web/asn.go` | Load and query the ip2asn table. No HTTP, no I/O beyond the one file read. |
| `modules/router/web/asn_test.go` | Range boundaries, unmatched addresses, malformed rows. |
| `modules/router/web/netguard.go` | `isPublicAddr`. Used by both the conntrack filter and the mutation guard, so it lives alone rather than being duplicated. |
| `modules/router/web/netguard_test.go` | Every refused class plus a public address. |
| `modules/router/web/conntrack.go` | Parse `conntrack -L -o extended`, aggregate per peer for one device. |
| `modules/router/web/conntrack_test.go` | Fixtures in the real output format. |
| `modules/router/web/peers.go` | HTTP handlers, the peers mux, and the shell-out to the tools. |
| `modules/router/web/peers_test.go` | Handler behaviour, guards, mutation logging, route isolation. |
| `modules/router/web/peers.html` | Page template. |
| `modules/router/web/main.go` | Modified: config for the new env vars, two listeners. |
| `modules/router/ip2asn-combined.tsv` | Vendored data, outside `web/` so it is not part of the Go build context. |
| `modules/router/web.nix` | Modified: mesh listener flag, env vars, `CAP_NET_ADMIN`, runtime path. |
| `modules/router/default.nix` | Modified: adds the `sifr.router.meshAddress` option. |

---

### Task 1: ASN table

**Files:**
- Create: `modules/router/ip2asn-combined.tsv` (copied from `../pdb/src/routes/ip2asn-combined.tsv`, ~15 MB)
- Create: `modules/router/web/asn.go`
- Test: `modules/router/web/asn_test.go`

**Interfaces:**
- Consumes: nothing.
- Produces: `type ASNInfo struct { Number uint32; Org, Country string }`, `func LoadASNTable(path string) (*ASNTable, error)`, `func (t *ASNTable) Lookup(addr netip.Addr) (ASNInfo, bool)`. A nil `*ASNTable` is valid and its `Lookup` returns `false`, so a missing data file degrades instead of crashing.

**Note on the data file:** this adds ~15 MB to a public git repository. That is the spec's decision (vendored, read from the store path) and is deliberate — it keeps the build reproducible without a network fetch. If that size is unwanted, the alternative is `pkgs.fetchurl` with a pinned hash, which changes only `web.nix` and this task's first step.

- [ ] **Step 1: Vendor the data file**

```bash
cp ../pdb/src/routes/ip2asn-combined.tsv modules/router/ip2asn-combined.tsv
head -1 modules/router/ip2asn-combined.tsv
```

Expected first line format (tab separated): `1.0.0.0	1.0.0.255	13335	US	CLOUDFLARENET`

- [ ] **Step 2: Write the failing test**

Create `modules/router/web/asn_test.go`:

```go
package main

import (
	"net/netip"
	"os"
	"path/filepath"
	"testing"
)

func writeTSV(t *testing.T, body string) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "ip2asn.tsv")
	if err := os.WriteFile(path, []byte(body), 0o600); err != nil {
		t.Fatalf("write fixture: %v", err)
	}
	return path
}

func TestASNLookup(t *testing.T) {
	path := writeTSV(t, strings.Join([]string{
		"203.0.113.0\t203.0.113.255\t64496\tNL\tExample Hosting",
		"198.51.100.0\t198.51.100.127\t64497\tDE\tOther Hosting",
		"2001:db8::\t2001:db8::ffff\t64498\tFR\tExample Six",
		"",
	}, "\n"))

	table, err := LoadASNTable(path)
	if err != nil {
		t.Fatalf("LoadASNTable: %v", err)
	}

	cases := []struct {
		name  string
		addr  string
		want  ASNInfo
		found bool
	}{
		{"first address in range", "203.0.113.0", ASNInfo{64496, "Example Hosting", "NL"}, true},
		{"last address in range", "203.0.113.255", ASNInfo{64496, "Example Hosting", "NL"}, true},
		{"middle of range", "203.0.113.10", ASNInfo{64496, "Example Hosting", "NL"}, true},
		{"second range", "198.51.100.5", ASNInfo{64497, "Other Hosting", "DE"}, true},
		{"just past a range", "198.51.100.128", ASNInfo{}, false},
		{"unmatched", "192.0.2.1", ASNInfo{}, false},
		{"ipv6 in range", "2001:db8::1", ASNInfo{64498, "Example Six", "FR"}, true},
		{"ipv6 unmatched", "2001:db9::1", ASNInfo{}, false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got, ok := table.Lookup(netip.MustParseAddr(tc.addr))
			if ok != tc.found {
				t.Fatalf("found = %v, want %v", ok, tc.found)
			}
			if ok && got != tc.want {
				t.Fatalf("got %+v, want %+v", got, tc.want)
			}
		})
	}
}

func TestASNNilTableIsSafe(t *testing.T) {
	var table *ASNTable
	if _, ok := table.Lookup(netip.MustParseAddr("203.0.113.1")); ok {
		t.Fatal("nil table returned a result")
	}
}

func TestASNSkipsMalformedRows(t *testing.T) {
	path := writeTSV(t, strings.Join([]string{
		"not-an-address\t203.0.113.255\t64496\tNL\tBroken",
		"203.0.113.0\t203.0.113.255\t64496\tNL\tExample Hosting",
		"too\tfew\tcolumns",
		"",
	}, "\n"))
	table, err := LoadASNTable(path)
	if err != nil {
		t.Fatalf("LoadASNTable: %v", err)
	}
	if _, ok := table.Lookup(netip.MustParseAddr("203.0.113.1")); !ok {
		t.Fatal("good row was not loaded alongside malformed ones")
	}
}
```

Add `"strings"` to that file's imports.

- [ ] **Step 3: Run test to verify it fails**

Run: `cd modules/router/web && go test ./... -run TestASN -v`
Expected: FAIL — `undefined: LoadASNTable`, `undefined: ASNInfo`.

- [ ] **Step 4: Write the implementation**

Create `modules/router/web/asn.go`:

```go
package main

import (
	"bufio"
	"net/netip"
	"os"
	"sort"
	"strconv"
	"strings"
)

// ASNInfo is the attribution shown next to a peer.
type ASNInfo struct {
	Number  uint32
	Org     string
	Country string
}

type asnRange struct {
	start netip.Addr
	end   netip.Addr
	info  ASNInfo
}

// ASNTable holds v4 and v6 ranges separately, each sorted by start address so
// a lookup is a binary search rather than a scan of ~688k rows.
type ASNTable struct {
	v4 []asnRange
	v6 []asnRange
}

// LoadASNTable reads an ip2asn-combined.tsv. Malformed rows are skipped rather
// than failing the load: the file is third-party data and one bad line should
// not cost the whole table.
func LoadASNTable(path string) (*ASNTable, error) {
	handle, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer handle.Close()

	table := &ASNTable{}
	scanner := bufio.NewScanner(handle)
	scanner.Buffer(make([]byte, 0, 64*1024), 1024*1024)
	for scanner.Scan() {
		fields := strings.Split(scanner.Text(), "\t")
		if len(fields) < 5 {
			continue
		}
		start, err := netip.ParseAddr(fields[0])
		if err != nil {
			continue
		}
		end, err := netip.ParseAddr(fields[1])
		if err != nil {
			continue
		}
		number, err := strconv.ParseUint(fields[2], 10, 32)
		if err != nil {
			continue
		}
		entry := asnRange{
			start: start,
			end:   end,
			info: ASNInfo{
				Number:  uint32(number),
				Org:     fields[4],
				Country: fields[3],
			},
		}
		if start.Is4() {
			table.v4 = append(table.v4, entry)
		} else {
			table.v6 = append(table.v6, entry)
		}
	}
	if err := scanner.Err(); err != nil {
		return nil, err
	}

	sortRanges(table.v4)
	sortRanges(table.v6)
	return table, nil
}

func sortRanges(ranges []asnRange) {
	sort.Slice(ranges, func(i, j int) bool {
		return ranges[i].start.Less(ranges[j].start)
	})
}

// Lookup returns the ASN covering addr. A nil table always misses, which is
// what makes a missing data file degrade to "ASN unknown" rather than crash.
func (t *ASNTable) Lookup(addr netip.Addr) (ASNInfo, bool) {
	if t == nil {
		return ASNInfo{}, false
	}
	ranges := t.v6
	if addr.Is4() {
		ranges = t.v4
	}
	// First range whose start is greater than addr; the candidate is the one
	// before it.
	index := sort.Search(len(ranges), func(i int) bool {
		return addr.Less(ranges[i].start)
	})
	if index == 0 {
		return ASNInfo{}, false
	}
	candidate := ranges[index-1]
	if addr.Less(candidate.start) || candidate.end.Less(addr) {
		return ASNInfo{}, false
	}
	return candidate.info, true
}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `cd modules/router/web && go test ./... -run TestASN -v`
Expected: PASS, all subtests.

- [ ] **Step 6: Commit**

```bash
git add modules/router/ip2asn-combined.tsv modules/router/web/asn.go modules/router/web/asn_test.go
git commit --no-gpg-sign -m "router-web: add ip2asn table lookup"
```

---

### Task 2: Public-address guard

**Files:**
- Create: `modules/router/web/netguard.go`
- Test: `modules/router/web/netguard_test.go`

**Interfaces:**
- Consumes: nothing.
- Produces: `func isPublicAddr(addr netip.Addr) bool`. Used by Task 3 to drop non-public peers from the listing and by Task 5 to refuse a mutation.

- [ ] **Step 1: Write the failing test**

Create `modules/router/web/netguard_test.go`:

```go
package main

import (
	"net/netip"
	"testing"
)

func TestIsPublicAddr(t *testing.T) {
	cases := []struct {
		addr string
		want bool
	}{
		{"203.0.113.10", true},
		{"198.51.100.1", true},
		{"2001:db8::1", true},
		{"192.168.0.10", false},
		{"10.10.0.18", false},
		{"10.20.0.1", false},
		{"172.16.5.4", false},
		{"127.0.0.1", false},
		{"169.254.1.1", false},
		{"224.0.0.1", false},
		{"0.0.0.0", false},
		{"::1", false},
		{"fe80::1", false},
		{"fc00::1", false},
	}
	for _, tc := range cases {
		t.Run(tc.addr, func(t *testing.T) {
			if got := isPublicAddr(netip.MustParseAddr(tc.addr)); got != tc.want {
				t.Fatalf("isPublicAddr(%s) = %v, want %v", tc.addr, got, tc.want)
			}
		})
	}
}

func TestIsPublicAddrRejectsInvalid(t *testing.T) {
	if isPublicAddr(netip.Addr{}) {
		t.Fatal("zero Addr accepted")
	}
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd modules/router/web && go test ./... -run TestIsPublic -v`
Expected: FAIL — `undefined: isPublicAddr`.

- [ ] **Step 3: Write the implementation**

Create `modules/router/web/netguard.go`:

```go
package main

import "net/netip"

// isPublicAddr reports whether addr is a globally routable unicast address.
//
// The mesh needs no rule of its own: 10.10.0.0/24 is inside 10.0.0.0/8 and is
// already refused as private. Without this guard a crafted POST could throttle
// the router itself or another device on the LAN.
func isPublicAddr(addr netip.Addr) bool {
	if !addr.IsValid() {
		return false
	}
	addr = addr.Unmap()
	switch {
	case addr.IsPrivate(),
		addr.IsLoopback(),
		addr.IsLinkLocalUnicast(),
		addr.IsLinkLocalMulticast(),
		addr.IsMulticast(),
		addr.IsUnspecified(),
		addr.IsInterfaceLocalMulticast():
		return false
	}
	return true
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd modules/router/web && go test ./... -run TestIsPublic -v`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add modules/router/web/netguard.go modules/router/web/netguard_test.go
git commit --no-gpg-sign -m "router-web: add public-address guard"
```

---

### Task 3: Conntrack aggregation

**Files:**
- Create: `modules/router/web/conntrack.go`
- Test: `modules/router/web/conntrack_test.go`

**Interfaces:**
- Consumes: `isPublicAddr` from Task 2.
- Produces: `type Peer struct { Addr netip.Addr; Bytes, Packets uint64 }`, `func parseConntrack(r io.Reader, device netip.Addr) ([]Peer, error)` returning peers sorted by `Bytes` descending, and `func readConntrack(ctx context.Context) ([]byte, error)`.

The device is the LAN address being inspected. A flow counts when exactly one end matches it; the other end is the peer, and non-public peers are dropped, which removes router-originated and LAN-to-LAN traffic without a separate rule.

- [ ] **Step 1: Write the failing test**

Create `modules/router/web/conntrack_test.go`:

```go
package main

import (
	"net/netip"
	"strings"
	"testing"
)

// Real `conntrack -L -o extended` output shape, with accounting enabled.
const conntrackFixture = `ipv4     2 tcp      6 431876 ESTABLISHED src=192.168.0.10 dst=203.0.113.10 sport=42957 dport=55199 packets=100 bytes=4000 src=203.0.113.10 dst=198.51.100.1 sport=55199 dport=42957 packets=90 bytes=26000 [ASSURED] mark=0 use=1
ipv4     2 tcp      6 431876 ESTABLISHED src=192.168.0.10 dst=203.0.113.10 sport=49710 dport=443 packets=10 bytes=500 src=203.0.113.10 dst=198.51.100.1 sport=443 dport=49710 packets=8 bytes=300 [ASSURED] mark=0 use=1
ipv4     2 tcp      6 110 TIME_WAIT src=192.168.0.10 dst=203.0.113.20 sport=1111 dport=443 packets=5 bytes=1000 src=203.0.113.20 dst=198.51.100.1 sport=443 dport=1111 packets=5 bytes=4000 [ASSURED] mark=0 use=1
ipv4     2 tcp      6 60 TIME_WAIT src=198.51.100.1 dst=203.0.113.99 sport=51342 dport=853 packets=3 bytes=900 src=203.0.113.99 dst=198.51.100.1 sport=853 dport=51342 packets=3 bytes=1200 [ASSURED] mark=0 use=1
ipv4     2 udp      17 30 src=192.168.0.10 dst=192.168.0.1 sport=5353 dport=53 packets=2 bytes=200 src=192.168.0.1 dst=192.168.0.10 sport=53 dport=5353 packets=2 bytes=400 mark=0 use=1
ipv4     2 tcp      6 100 ESTABLISHED src=192.168.0.99 dst=203.0.113.50 sport=2222 dport=443 packets=9 bytes=9000 src=203.0.113.50 dst=198.51.100.1 sport=443 dport=2222 packets=9 bytes=9000 [ASSURED] mark=0 use=1
`

func TestParseConntrackAggregatesPerPeer(t *testing.T) {
	peers, err := parseConntrack(strings.NewReader(conntrackFixture), netip.MustParseAddr("192.168.0.10"))
	if err != nil {
		t.Fatalf("parseConntrack: %v", err)
	}
	if len(peers) != 2 {
		t.Fatalf("got %d peers, want 2: %+v", len(peers), peers)
	}
	// 203.0.113.10 = 4000+26000+500+300 = 30800, two flows summed.
	if peers[0].Addr != netip.MustParseAddr("203.0.113.10") {
		t.Fatalf("top peer = %s, want 203.0.113.10", peers[0].Addr)
	}
	if peers[0].Bytes != 30800 {
		t.Fatalf("top peer bytes = %d, want 30800", peers[0].Bytes)
	}
	if peers[0].Packets != 208 {
		t.Fatalf("top peer packets = %d, want 208", peers[0].Packets)
	}
	// 203.0.113.20 = 1000+4000 = 5000, sorted second.
	if peers[1].Addr != netip.MustParseAddr("203.0.113.20") || peers[1].Bytes != 5000 {
		t.Fatalf("second peer = %+v, want 203.0.113.20 with 5000 bytes", peers[1])
	}
}

func TestParseConntrackSkipsUnrelatedFlows(t *testing.T) {
	peers, err := parseConntrack(strings.NewReader(conntrackFixture), netip.MustParseAddr("192.168.0.10"))
	if err != nil {
		t.Fatalf("parseConntrack: %v", err)
	}
	for _, peer := range peers {
		switch peer.Addr.String() {
		case "203.0.113.99":
			t.Fatal("router-originated flow was attributed to the device")
		case "192.168.0.1":
			t.Fatal("LAN-to-LAN flow was reported as a peer")
		case "203.0.113.50":
			t.Fatal("another device's flow was attributed to this device")
		}
	}
}

func TestParseConntrackEmptyForIdleDevice(t *testing.T) {
	peers, err := parseConntrack(strings.NewReader(conntrackFixture), netip.MustParseAddr("192.168.0.77"))
	if err != nil {
		t.Fatalf("parseConntrack: %v", err)
	}
	if len(peers) != 0 {
		t.Fatalf("got %d peers for an idle device, want 0", len(peers))
	}
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd modules/router/web && go test ./... -run TestParseConntrack -v`
Expected: FAIL — `undefined: parseConntrack`.

- [ ] **Step 3: Write the implementation**

Create `modules/router/web/conntrack.go`:

```go
package main

import (
	"bufio"
	"context"
	"io"
	"net/netip"
	"os/exec"
	"sort"
	"strconv"
	"strings"
)

// Peer is one address the inspected device currently holds flows with.
type Peer struct {
	Addr    netip.Addr
	Bytes   uint64
	Packets uint64
}

// readConntrack dumps the live connection table. Requires CAP_NET_ADMIN and
// net.netfilter.nf_conntrack_acct=1 for the byte counters to be present.
func readConntrack(ctx context.Context) ([]byte, error) {
	return exec.CommandContext(ctx, "conntrack", "-L", "-o", "extended").Output()
}

// parseConntrack aggregates flows into per-peer totals for one device.
//
// Each line repeats src/dst/packets/bytes once per direction. A flow counts
// when exactly one end is the device; the other end is the peer. Non-public
// peers are dropped, which removes router-originated and LAN-to-LAN traffic
// without needing a separate rule for either.
func parseConntrack(r io.Reader, device netip.Addr) ([]Peer, error) {
	totals := map[netip.Addr]*Peer{}

	scanner := bufio.NewScanner(r)
	scanner.Buffer(make([]byte, 0, 64*1024), 1024*1024)
	for scanner.Scan() {
		var addrs []netip.Addr
		var bytes, packets uint64
		for _, token := range strings.Fields(scanner.Text()) {
			key, value, found := strings.Cut(token, "=")
			if !found {
				continue
			}
			switch key {
			case "src", "dst":
				if addr, err := netip.ParseAddr(value); err == nil {
					addrs = append(addrs, addr.Unmap())
				}
			case "bytes":
				if parsed, err := strconv.ParseUint(value, 10, 64); err == nil {
					bytes += parsed
				}
			case "packets":
				if parsed, err := strconv.ParseUint(value, 10, 64); err == nil {
					packets += parsed
				}
			}
		}
		if len(addrs) < 2 || bytes == 0 {
			continue
		}

		// addrs[0] and addrs[1] are the original tuple's src and dst. Later
		// pairs are the reply tuple, whose destination is the router's WAN
		// address after NAT and therefore not useful for attribution.
		src, dst := addrs[0], addrs[1]
		var peer netip.Addr
		switch {
		case src == device:
			peer = dst
		case dst == device:
			peer = src
		default:
			continue
		}
		if !isPublicAddr(peer) {
			continue
		}

		entry := totals[peer]
		if entry == nil {
			entry = &Peer{Addr: peer}
			totals[peer] = entry
		}
		entry.Bytes += bytes
		entry.Packets += packets
	}
	if err := scanner.Err(); err != nil {
		return nil, err
	}

	peers := make([]Peer, 0, len(totals))
	for _, entry := range totals {
		peers = append(peers, *entry)
	}
	sort.Slice(peers, func(i, j int) bool {
		if peers[i].Bytes != peers[j].Bytes {
			return peers[i].Bytes > peers[j].Bytes
		}
		return peers[i].Addr.Less(peers[j].Addr)
	})
	return peers, nil
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd modules/router/web && go test ./... -run TestParseConntrack -v`
Expected: PASS, all three tests.

- [ ] **Step 5: Commit**

```bash
git add modules/router/web/conntrack.go modules/router/web/conntrack_test.go
git commit --no-gpg-sign -m "router-web: aggregate conntrack flows per peer"
```

---

### Task 4: Peers page handler and template

**Files:**
- Create: `modules/router/web/peers.go`
- Create: `modules/router/web/peers.html`
- Test: `modules/router/web/peers_test.go`

**Interfaces:**
- Consumes: `ASNTable.Lookup`, `parseConntrack`, `isPublicAddr`, and `formatBytes` (already in `main.go:79`).
- Produces: `type peersServer struct { lanNet netip.Prefix; asn *ASNTable; tmpl *template.Template; conntrack func(context.Context) ([]byte, error); runTool func(name string, args ...string) (string, error) }`, `func (s *peersServer) mux() *http.ServeMux`, and `func newPeersServer(lanNet netip.Prefix, asn *ASNTable, tmpl *template.Template) *peersServer`.

The `conntrack` and `runTool` fields are function values so tests can substitute them without running privileged commands. `newPeersServer` sets them to the real implementations.

- [ ] **Step 1: Write the failing test**

Create `modules/router/web/peers_test.go`:

```go
package main

import (
	"context"
	"html/template"
	"net/http"
	"net/http/httptest"
	"net/netip"
	"strings"
	"testing"
)

func testPeersServer(t *testing.T) *peersServer {
	t.Helper()
	tmpl, err := template.New("peers.html").Parse(
		`{{.Device}}|{{range .Peers}}{{.Addr}},{{.ASN}},{{.Org}},{{.Country}},{{.SharePct}};{{end}}|{{.Error}}`)
	if err != nil {
		t.Fatalf("parse template: %v", err)
	}
	table, err := LoadASNTable(writeTSV(t,
		"203.0.113.0\t203.0.113.255\t64496\tNL\tExample Hosting\n"))
	if err != nil {
		t.Fatalf("LoadASNTable: %v", err)
	}
	server := newPeersServer(netip.MustParsePrefix("192.168.0.0/24"), table, tmpl)
	server.conntrack = func(context.Context) ([]byte, error) {
		return []byte(conntrackFixture), nil
	}
	server.runTool = func(string, ...string) (string, error) { return "ok", nil }
	return server
}

func TestPeersPageListsPeersWithASN(t *testing.T) {
	rec := httptest.NewRecorder()
	testPeersServer(t).mux().ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/peers/192.168.0.10", nil))

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200", rec.Code)
	}
	body := rec.Body.String()
	if !strings.Contains(body, "203.0.113.10,64496,Example Hosting,NL,") {
		t.Fatalf("peer row with ASN attribution missing from body: %q", body)
	}
	// 30800 of 35800 total bytes = 86.0%.
	if !strings.Contains(body, "86.0") {
		t.Fatalf("top-peer share missing from body: %q", body)
	}
}

func TestPeersPageRejectsAddressOutsideLAN(t *testing.T) {
	rec := httptest.NewRecorder()
	testPeersServer(t).mux().ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/peers/203.0.113.10", nil))
	if rec.Code != http.StatusNotFound {
		t.Fatalf("status = %d, want 404", rec.Code)
	}
}

func TestPeersPageRejectsUnparseableAddress(t *testing.T) {
	rec := httptest.NewRecorder()
	testPeersServer(t).mux().ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/peers/not-an-ip", nil))
	if rec.Code != http.StatusNotFound {
		t.Fatalf("status = %d, want 404", rec.Code)
	}
}

func TestPeersPageErrorsWhenConntrackFails(t *testing.T) {
	server := testPeersServer(t)
	server.conntrack = func(context.Context) ([]byte, error) { return nil, errFake }
	rec := httptest.NewRecorder()
	server.mux().ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/peers/192.168.0.10", nil))
	if rec.Code != http.StatusInternalServerError {
		t.Fatalf("status = %d, want 500 — an unreadable table must not look like an idle device", rec.Code)
	}
}
```

Add to the same file:

```go
import "errors"

var errFake = errors.New("conntrack unavailable")
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd modules/router/web && go test ./... -run TestPeersPage -v`
Expected: FAIL — `undefined: newPeersServer`, `undefined: peersServer`.

- [ ] **Step 3: Write the template**

Create `modules/router/web/peers.html`:

```html
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>Peers — {{.Device}}</title>
<style>
body { font-family: system-ui, sans-serif; margin: 2rem; }
table { border-collapse: collapse; width: 100%; }
th, td { text-align: left; padding: .4rem .6rem; border-bottom: 1px solid #ddd; }
th { font-weight: 600; }
td.num { text-align: right; font-variant-numeric: tabular-nums; }
tr.high td { background: #fff0f0; }
button { padding: .25rem .6rem; cursor: pointer; }
p.note { color: #666; }
p.error { color: #a00; font-weight: 600; }
</style>
</head>
<body>
<h1>Peers for {{.Device}}</h1>
<p class="note">Live connection table. A peer that has stopped is not listed, and an idle device shows nothing. History lives on the dashboard.</p>
{{if .Error}}<p class="error">{{.Error}}</p>{{end}}
{{if .Peers}}
<table>
<tr><th>Peer</th><th>AS</th><th>Organisation</th><th>Country</th><th class="num">Bytes</th><th class="num">Share</th><th>Actions</th></tr>
{{range .Peers}}
<tr{{if .High}} class="high"{{end}}>
<td>{{.Addr}}</td>
<td>{{if .ASN}}AS{{.ASN}}{{else}}—{{end}}</td>
<td>{{if .Org}}{{.Org}}{{else}}unknown{{end}}</td>
<td>{{.Country}}</td>
<td class="num">{{.Bytes}}</td>
<td class="num">{{.SharePct}}%</td>
<td>
<form method="post" action="/peers/{{$.Device}}/throttle" style="display:inline">
<input type="hidden" name="peer" value="{{.Addr}}">
<button type="submit">throttle</button>
</form>
<form method="post" action="/peers/{{$.Device}}/block" style="display:inline">
<input type="hidden" name="peer" value="{{.Addr}}">
<button type="submit">block</button>
</form>
</td>
</tr>
{{end}}
</table>
{{else}}
<p>No current peers.</p>
{{end}}
</body>
</html>
```

- [ ] **Step 4: Write the handler**

Create `modules/router/web/peers.go`:

```go
package main

import (
	"context"
	"fmt"
	"html/template"
	"log"
	"net/http"
	"net/netip"
	"os/exec"
	"strings"
	"time"
)

const conntrackTimeout = 10 * time.Second

type peerRow struct {
	Addr     string
	ASN      uint32
	Org      string
	Country  string
	Bytes    string
	SharePct string
	High     bool
}

type peersPageData struct {
	Device string
	Peers  []peerRow
	Error  string
}

type peersServer struct {
	lanNet    netip.Prefix
	asn       *ASNTable
	tmpl      *template.Template
	conntrack func(context.Context) ([]byte, error)
	runTool   func(name string, args ...string) (string, error)
}

func newPeersServer(lanNet netip.Prefix, asn *ASNTable, tmpl *template.Template) *peersServer {
	return &peersServer{
		lanNet:    lanNet,
		asn:       asn,
		tmpl:      tmpl,
		conntrack: readConntrack,
		runTool:   runTool,
	}
}

// runTool invokes one of the router's shell tools and returns its combined
// output. The output is surfaced on the page so a failed action is never
// reported as a success.
func runTool(name string, args ...string) (string, error) {
	ctx, cancel := context.WithTimeout(context.Background(), conntrackTimeout)
	defer cancel()
	out, err := exec.CommandContext(ctx, name, args...).CombinedOutput()
	return strings.TrimSpace(string(out)), err
}

// mux registers the read-only route. Task 5 adds the two mutation routes here.
func (s *peersServer) mux() *http.ServeMux {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /peers/{device}", s.handlePage)
	return mux
}

// device parses and validates the {device} path value against the LAN prefix.
func (s *peersServer) device(r *http.Request) (netip.Addr, bool) {
	addr, err := netip.ParseAddr(r.PathValue("device"))
	if err != nil {
		return netip.Addr{}, false
	}
	addr = addr.Unmap()
	if !s.lanNet.Contains(addr) {
		return netip.Addr{}, false
	}
	return addr, true
}

func (s *peersServer) handlePage(w http.ResponseWriter, r *http.Request) {
	device, ok := s.device(r)
	if !ok {
		http.NotFound(w, r)
		return
	}
	s.render(w, r, device, "")
}

func (s *peersServer) render(w http.ResponseWriter, r *http.Request, device netip.Addr, notice string) {
	ctx, cancel := context.WithTimeout(r.Context(), conntrackTimeout)
	defer cancel()

	raw, err := s.conntrack(ctx)
	if err != nil {
		// Deliberately not an empty page: an unreadable table and an idle
		// device must not look alike.
		log.Printf("peers: read conntrack: %v", err)
		http.Error(w, "cannot read connection table", http.StatusInternalServerError)
		return
	}
	peers, err := parseConntrack(strings.NewReader(string(raw)), device)
	if err != nil {
		log.Printf("peers: parse conntrack: %v", err)
		http.Error(w, "cannot parse connection table", http.StatusInternalServerError)
		return
	}

	var total uint64
	for _, peer := range peers {
		total += peer.Bytes
	}

	data := peersPageData{Device: device.String(), Error: notice}
	for _, peer := range peers {
		share := 0.0
		if total > 0 {
			share = float64(peer.Bytes) / float64(total) * 100
		}
		row := peerRow{
			Addr:     peer.Addr.String(),
			Bytes:    formatBytes(peer.Bytes),
			SharePct: fmt.Sprintf("%.1f", share),
			High:     share >= 70,
		}
		if info, found := s.asn.Lookup(peer.Addr); found {
			row.ASN, row.Org, row.Country = info.Number, info.Org, info.Country
		}
		data.Peers = append(data.Peers, row)
	}

	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	if err := s.tmpl.Execute(w, data); err != nil {
		log.Printf("peers: render: %v", err)
	}
}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `cd modules/router/web && go test ./... -run TestPeersPage -v`
Expected: PASS, all four `TestPeersPage` tests. The package compiles at this
point because `mux()` registers only the GET route; the mutation routes and
`handleAction` arrive in Task 5.

- [ ] **Step 6: Commit**

```bash
git add modules/router/web/peers.go modules/router/web/peers.html modules/router/web/peers_test.go
git commit --no-gpg-sign -m "router-web: add peers page with ASN attribution"
```

---

### Task 5: Mutations and journal logging

**Files:**
- Modify: `modules/router/web/peers.go` (add `handleAction`)
- Test: `modules/router/web/peers_test.go` (append)

**Interfaces:**
- Consumes: `peersServer`, `isPublicAddr`, `ASNTable.Lookup`.
- Produces: `func (s *peersServer) handleAction(action, tool string) http.HandlerFunc`.

- [ ] **Step 1: Write the failing test**

Append to `modules/router/web/peers_test.go`:

```go
func TestActionThrottlesPeer(t *testing.T) {
	server := testPeersServer(t)
	var gotName string
	var gotArgs []string
	server.runTool = func(name string, args ...string) (string, error) {
		gotName, gotArgs = name, args
		return "throttled: 203.0.113.10", nil
	}

	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodPost, "/peers/192.168.0.10/throttle",
		strings.NewReader("peer=203.0.113.10"))
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	server.mux().ServeHTTP(rec, req)

	if rec.Code != http.StatusSeeOther {
		t.Fatalf("status = %d, want 303", rec.Code)
	}
	if gotName != "tempthrottle" || len(gotArgs) != 2 || gotArgs[0] != "add" || gotArgs[1] != "203.0.113.10" {
		t.Fatalf("ran %s %v, want tempthrottle add 203.0.113.10", gotName, gotArgs)
	}
}

func TestActionBlocksPeer(t *testing.T) {
	server := testPeersServer(t)
	var gotName string
	server.runTool = func(name string, args ...string) (string, error) {
		gotName = name
		return "blocked", nil
	}
	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodPost, "/peers/192.168.0.10/block",
		strings.NewReader("peer=203.0.113.10"))
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	server.mux().ServeHTTP(rec, req)
	if gotName != "tempblock" {
		t.Fatalf("ran %q, want tempblock", gotName)
	}
}

func TestActionRefusesNonPublicPeer(t *testing.T) {
	for _, peer := range []string{"192.168.0.1", "10.10.0.18", "127.0.0.1"} {
		t.Run(peer, func(t *testing.T) {
			server := testPeersServer(t)
			called := false
			server.runTool = func(string, ...string) (string, error) {
				called = true
				return "", nil
			}
			rec := httptest.NewRecorder()
			req := httptest.NewRequest(http.MethodPost, "/peers/192.168.0.10/throttle",
				strings.NewReader("peer="+peer))
			req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
			server.mux().ServeHTTP(rec, req)
			if called {
				t.Fatal("tool was invoked for a non-public peer")
			}
			if rec.Code != http.StatusBadRequest {
				t.Fatalf("status = %d, want 400", rec.Code)
			}
		})
	}
}

func TestActionRejectsGET(t *testing.T) {
	rec := httptest.NewRecorder()
	testPeersServer(t).mux().ServeHTTP(rec,
		httptest.NewRequest(http.MethodGet, "/peers/192.168.0.10/throttle", nil))
	if rec.Code == http.StatusSeeOther || rec.Code == http.StatusOK {
		t.Fatalf("GET on a mutation route returned %d; it must not act", rec.Code)
	}
}

func TestActionLogsToJournal(t *testing.T) {
	var buf strings.Builder
	log.SetOutput(&buf)
	log.SetFlags(0)
	t.Cleanup(func() { log.SetOutput(os.Stderr) })

	server := testPeersServer(t)
	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodPost, "/peers/192.168.0.10/throttle",
		strings.NewReader("peer=203.0.113.10"))
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	server.mux().ServeHTTP(rec, req)

	line := buf.String()
	for _, want := range []string{
		"peer-action",
		"action=throttle",
		"peer=203.0.113.10",
		"asn=64496",
		`org="Example Hosting"`,
		"cc=NL",
		"device=192.168.0.10",
		"result=ok",
	} {
		if !strings.Contains(line, want) {
			t.Fatalf("log line missing %q: %s", want, line)
		}
	}
}
```

Add `"log"` and `"os"` to the test file's imports.

- [ ] **Step 2: Run test to verify it fails**

Run: `cd modules/router/web && go test ./... -run TestAction -v`
Expected: FAIL — `undefined: handleAction` (or compile error if you stubbed it in Task 4).

- [ ] **Step 3: Register the mutation routes**

In `modules/router/web/peers.go`, extend `mux()` to its final form:

```go
func (s *peersServer) mux() *http.ServeMux {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /peers/{device}", s.handlePage)
	mux.HandleFunc("POST /peers/{device}/throttle", s.handleAction("throttle", "tempthrottle"))
	mux.HandleFunc("POST /peers/{device}/block", s.handleAction("block", "tempblock"))
	return mux
}
```

- [ ] **Step 4: Write the implementation**

Append to `modules/router/web/peers.go`:

```go
// handleAction returns a handler that runs one of the router's tools against a
// peer. action names it for the journal; tool is the executable.
func (s *peersServer) handleAction(action, tool string) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		device, ok := s.device(r)
		if !ok {
			http.NotFound(w, r)
			return
		}
		peer, err := netip.ParseAddr(r.PostFormValue("peer"))
		if err != nil {
			http.Error(w, "unparseable peer address", http.StatusBadRequest)
			return
		}
		peer = peer.Unmap()
		if !isPublicAddr(peer) {
			// Refused before the tool is invoked: shaping the gateway or
			// another LAN device is hard to undo from the far side of it.
			s.logAction(action, peer, device, "refused: not a public address")
			http.Error(w, "peer must be a public address", http.StatusBadRequest)
			return
		}

		output, runErr := s.runTool(tool, "add", peer.String())
		result := "ok"
		if runErr != nil {
			result = fmt.Sprintf("error: %v: %s", runErr, output)
		}
		s.logAction(action, peer, device, result)

		if runErr != nil {
			http.Error(w, fmt.Sprintf("%s failed: %s", tool, output), http.StatusInternalServerError)
			return
		}
		http.Redirect(w, r, "/peers/"+device.String(), http.StatusSeeOther)
	}
}

// logAction writes the one line that makes blocks collectable later. The ASN,
// share-bearing device and outcome are included deliberately: an address on its
// own ages badly, and the reason is what is wanted months later.
func (s *peersServer) logAction(action string, peer, device netip.Addr, result string) {
	info, _ := s.asn.Lookup(peer)
	log.Printf("peer-action action=%s peer=%s asn=%d org=%q cc=%s device=%s result=%s",
		action, peer, info.Number, info.Org, info.Country, device, result)
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `cd modules/router/web && go test ./... -v`
Expected: PASS, every test in the package.

- [ ] **Step 6: Commit**

```bash
git add modules/router/web/peers.go modules/router/web/peers_test.go
git commit --no-gpg-sign -m "router-web: throttle and block peers, logged to the journal"
```

---

### Task 6: Two listeners

**Files:**
- Modify: `modules/router/web/main.go:348-392` (the `main` function) and the config block at `modules/router/web/main.go:332-347`
- Test: `modules/router/web/peers_test.go` (append)

**Interfaces:**
- Consumes: `newPeersServer`, `LoadASNTable`.
- Produces: nothing consumed by later tasks.

- [ ] **Step 1: Write the failing test**

Append to `modules/router/web/peers_test.go`:

```go
func TestLANMuxHasNoPeersRoutes(t *testing.T) {
	tmpl, err := template.New("index.html").Parse("landing")
	if err != nil {
		t.Fatalf("parse: %v", err)
	}
	lan := landingMux(pageData{}, tmpl)

	for _, path := range []string{"/peers/192.168.0.10", "/peers/192.168.0.10/throttle"} {
		rec := httptest.NewRecorder()
		lan.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, path, nil))
		if rec.Code != http.StatusNotFound {
			t.Fatalf("LAN mux served %s with %d; peers routes must be mesh-only", path, rec.Code)
		}
	}
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd modules/router/web && go test ./... -run TestLANMux -v`
Expected: FAIL — `undefined: landingMux`.

- [ ] **Step 3: Extract the landing mux**

In `modules/router/web/main.go`, replace the inline `mux := http.NewServeMux()` block inside `main` with a named function, placed above `main`:

```go
// landingMux serves the LAN landing page and nothing else. Kept separate from
// the peers mux so that a route added here cannot become mesh-only by
// accident, and a peers route cannot become LAN-reachable by forgetting a
// check.
func landingMux(config pageData, tmpl *template.Template) *http.ServeMux {
	mux := http.NewServeMux()
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/" {
			http.NotFound(w, r)
			return
		}
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		if err := tmpl.Execute(w, readSystemState(config)); err != nil {
			log.Printf("render template: %v", err)
			http.Error(w, "internal server error", http.StatusInternalServerError)
		}
	})
	return mux
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd modules/router/web && go test ./... -run TestLANMux -v`
Expected: PASS.

- [ ] **Step 5: Wire the second listener**

Replace the server-startup section at the end of `main` with:

```go
	lanAddr := getenvDefault("ROUTER_LISTEN_LAN", *addr)
	meshAddr := os.Getenv("ROUTER_LISTEN_MESH")
	asnPath := os.Getenv("ROUTER_IP2ASN_FILE")
	lanCIDR := os.Getenv("ROUTER_LAN_CIDR")

	lanServer := &http.Server{Addr: lanAddr, Handler: landingMux(config, tmpl)}

	errs := make(chan error, 2)
	go func() {
		log.Printf("serving landing page on http://%s", lanAddr)
		errs <- lanServer.ListenAndServe()
	}()

	// The peers routes exist only when a mesh address is configured. A router
	// without one behaves exactly as it did before this feature.
	if meshAddr != "" && lanCIDR != "" {
		prefix, err := netip.ParsePrefix(lanCIDR)
		if err != nil {
			log.Fatalf("ROUTER_LAN_CIDR %q: %v", lanCIDR, err)
		}
		var table *ASNTable
		if asnPath != "" {
			table, err = LoadASNTable(asnPath)
			if err != nil {
				// Degrade rather than fail: attribution is the nice-to-have,
				// the peer list is the point.
				log.Printf("ip2asn table unavailable, peers will show unknown ASNs: %v", err)
				table = nil
			}
		}
		peersTmpl, err := template.ParseFiles(filepath.Join(staticRoot, "peers.html"))
		if err != nil {
			log.Fatalf("parse peers template: %v", err)
		}
		meshServer := &http.Server{
			Addr:    meshAddr,
			Handler: newPeersServer(prefix, table, peersTmpl).mux(),
		}
		go func() {
			log.Printf("serving peers page on http://%s", meshAddr)
			errs <- meshServer.ListenAndServe()
		}()
	}

	if err := <-errs; err != nil && err != http.ErrServerClosed {
		log.Fatalf("server failed: %v", err)
	}
```

Add `"net/netip"` to the imports in `main.go`.

- [ ] **Step 6: Verify the whole package builds and passes**

Run: `cd modules/router/web && go vet ./... && go test ./... -v`
Expected: vet clean, all tests PASS.

- [ ] **Step 7: Commit**

```bash
git add modules/router/web/main.go modules/router/web/peers_test.go
git commit --no-gpg-sign -m "router-web: serve peers routes on a separate mesh listener"
```

---

### Task 7: NixOS wiring

**Files:**
- Modify: `modules/router/default.nix` (options block, near `lanAddress` at line 37)
- Modify: `modules/router/web.nix`
- Modify: `modules/router/web/package.nix` (install `peers.html` alongside `index.html`)

**Interfaces:**
- Consumes: the env vars read in Task 6 — `ROUTER_LISTEN_LAN`, `ROUTER_LISTEN_MESH`, `ROUTER_IP2ASN_FILE`, `ROUTER_LAN_CIDR`.
- Produces: `sifr.router.meshAddress`.

- [ ] **Step 1: Add the option**

In `modules/router/default.nix`, directly after the `lanAddress` option block:

```nix
    meshAddress = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "10.10.0.18";
      description = ''
        Address on the mesh interface to serve the peers page from, without a
        prefix length. When null the peers routes are not served at all and
        router-web behaves exactly as it did before the feature existed.

        Deliberately explicit rather than resolved from the mesh interface at
        startup: the interface may not be up when router-web starts, and a
        service that sometimes fails to bind depending on start order is worse
        than one that is configured.
      '';
    };
```

- [ ] **Step 2: Install the new template**

In `modules/router/web/package.nix`, extend `postInstall`:

```nix
  postInstall = ''
    install -Dm644 ${./index.html} "$out/share/router-web/index.html"
    install -Dm644 ${./peers.html} "$out/share/router-web/peers.html"
  '';
```

- [ ] **Step 3: Wire the service**

In `modules/router/web.nix`, inside `systemd.services.router-web`:

Add to `path`:

```nix
      path = with pkgs; [
        iproute2
        procps
        conntrack-tools
        nftables
      ];
```

Add to `serviceConfig` — note `DynamicUser` is kept:

```nix
        AmbientCapabilities = [
          "CAP_NET_BIND_SERVICE"
          "CAP_NET_ADMIN"
        ];
        CapabilityBoundingSet = [
          "CAP_NET_BIND_SERVICE"
          "CAP_NET_ADMIN"
        ];
```

Add to `Environment`, after the existing entries:

```nix
          "ROUTER_LISTEN_LAN=${lib.head (lib.splitString "/" cfg.lanAddress)}:80"
          "ROUTER_LAN_CIDR=${cfg.lanAddress}"
          "ROUTER_IP2ASN_FILE=${../ip2asn-combined.tsv}"
        ]
        ++ lib.optional (cfg.meshAddress != null) "ROUTER_LISTEN_MESH=${cfg.meshAddress}:80"
```

`tempthrottle` and `tempblock` are on the service `PATH` because `modules/router/tools.nix` puts them in `environment.systemPackages`; confirm with Step 5 rather than assuming.

- [ ] **Step 4: Set the mesh address on both routers**

In `hosts/bongo/default.nix` and `hosts/bingo/default.nix`, inside the `sifr.router` block:

```nix
      meshAddress = "10.10.0.16";  # bongo
```

```nix
      meshAddress = "10.10.0.18";  # bingo
```

- [ ] **Step 5: Build both routers**

Run:

```bash
nix build .#nixosConfigurations.bingo.config.system.build.toplevel --no-link
nix build .#nixosConfigurations.bongo.config.system.build.toplevel --no-link
```

Expected: both succeed. `buildGoModule` runs `go test` during the build, so a failing test fails the build.

Then confirm the tools resolve on the unit's path:

```bash
nix eval --raw '.#nixosConfigurations.bingo.config.systemd.services.router-web.serviceConfig.Environment' | tr ' ' '\n' | grep ROUTER_
```

Expected: `ROUTER_LISTEN_LAN`, `ROUTER_LAN_CIDR`, `ROUTER_IP2ASN_FILE` and `ROUTER_LISTEN_MESH` all present.

- [ ] **Step 6: Commit**

```bash
git add modules/router/default.nix modules/router/web.nix modules/router/web/package.nix hosts/bongo/default.nix hosts/bingo/default.nix
git commit --no-gpg-sign -m "router: serve the peers page on the mesh address"
```

---

## Deployment note

Not a task — a warning for whoever deploys this. Rebuilding a router flushes every `tempthrottle` and `tempblock` entry, because both sets are non-persistent by design. At the time of writing there are thirteen live throttles that exist only in the running ruleset. Capture them first:

```bash
ssh <router> 'tempthrottle list; tempblock list'
```

and make sure anything worth keeping is already in `custom-throttle-list.txt` or `custom-ip-blocklist.txt` before switching.

## Manual verification

After deploying to one router, from a machine on the mesh:

1. `curl -s http://10.10.0.18/peers/192.168.50.1 | head -20` — expect the page, likely with few peers for the router's own LAN address.
2. Pick a busy device from the dashboard's "Devices ranked by VPN indicators" panel and open `/peers/<that address>`. Expect peers with ASN attribution, sorted by bytes, share on the right.
3. Confirm the LAN listener no longer serves the route: `curl -so /dev/null -w '%{http_code}' http://<lan-address>/peers/192.168.50.1` — expect `404`.
4. Throttle a peer you are willing to shape, then `ssh <router> tempthrottle list` to confirm it is present.
5. `ssh <router> 'journalctl -u router-web | grep peer-action | tail -3'` — expect the structured line with ASN, org, country, device and `result=ok`.
