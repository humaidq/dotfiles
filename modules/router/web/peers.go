package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"html/template"
	"log"
	"net/http"
	"net/netip"
	"os/exec"
	"sort"
	"strings"
	"time"
)

const conntrackTimeout = 10 * time.Second

type peerRow struct {
	Addr string
	// The peer's reverse DNS name, shown under the address. Empty either
	// because nothing is cached yet or because the address resolved to no PTR
	// at all; RDNSKnown is what separates those, and the template needs the
	// distinction — the first is a cell the browser is asked to fill in, the
	// second is settled and must not be asked about again.
	RDNS      string
	RDNSKnown bool
	// The name most recently resolved to this address by the router's own
	// resolver. Shown alongside RDNS rather than instead of it — they are
	// different claims and the template labels them apart. Empty when the
	// answer log is off or has not seen the address.
	DNSName  string
	ASN      uint32
	Org      string
	Country  string
	Bytes    string
	Up       string
	Down     string
	SharePct string
	High     bool
	Shape    string
	Traffic  traffic
	// How long ago this peer last carried a packet, already formatted. Empty
	// when it could not be determined, which the template renders as an
	// em-dash — the same "no answer" the other optional columns use, and
	// distinct from "0s", which is a real and very recent answer.
	LastSeen string
	// Whether that gap is long enough that the connection is best read as
	// left-over rather than live. Drives the greying-out in the template; the
	// text alone does not, because a table of durations is exactly the thing an
	// eye slides over.
	Stale bool
}

// How long a peer must be silent before the page greys it out.
//
// Two minutes rather than something tighter because the traffic this page is
// usually read against is not continuous: a phone on a messaging app, a browser
// tab holding a keep-alive. Those go quiet for tens of seconds at a time while
// being unambiguously in use, and a threshold that flagged them would make the
// column noise. What it is meant to separate out is the long tail — TCP entries
// the kernel keeps for five days after the last byte, which look identical to
// live ones by byte count.
const staleAfter = 2 * time.Minute

type peersPageData struct {
	Nav    navData
	Device string
	// How DHCP knows this device: the hostname it offered, and the hardware
	// address it holds. The lease file answers both when there is a lease; the
	// static reservations answer the name and the neighbour table the MAC when
	// there is not. Only a device that is in neither renders the em-dash.
	//
	// The MAC is here because it is the identifier the low-trust pool keys on:
	// making a device's membership permanent means copying this value into the
	// sops secret, and having it on the page saves a trip to the router.
	Name string
	MAC  string
	// Set when Name came from the reservation file rather than a live lease.
	// The template says so on hover: the two are different claims — one is what
	// the device called itself just now, the other is what an operator decided
	// it is called, possibly months ago and possibly about a MAC the device has
	// since rotated away from.
	NameReserved bool
	// The other addresses this device holds, beyond the one in the URL. Shown
	// because the peer table below is a union across all of them, and a page
	// that silently merged two address families would leave a reader unable to
	// tell whether a row is missing or merely on an address they did not know
	// the device had.
	AlsoAddrs []string
	Peers     []peerRow
	Error     string
	// What this device's capture slot is doing. Zero when no capture
	// directory is configured, which the template reads as "no banner".
	Capture captureSlot
	// Whether this router has the low-trust pool at all. False on a router
	// where the feature is off, and the template then renders none of the
	// block: no button promising drops that no chain implements, and no link
	// to routes that are not registered.
	LowTrustEnabled bool
	// Low-trust pool membership: "", "temp", or "permanent". Which set a
	// device came from decides whether a remove button is offered, because
	// the tool refuses to remove a permanent member and a button that cannot
	// work should not be shown.
	LowTrust string
	// Whether this router offers cooldowns at all. False leaves the whole block
	// out of the page, matching the routes: on a router with the feature off
	// there is no table for the drop to live in and no tool to write it.
	CooldownEnabled bool
	// Whether this device is currently in cooldown, and for how much longer.
	// Read from the ruleset on every render rather than remembered here, so the
	// page cannot claim a cooldown that a reboot or a ruleset reload has
	// already ended.
	Cooldown cooldownState
	// Set when the pool is enabled but no MAC could be found for this device,
	// in either the neighbour table or the lease file. Kept apart from a
	// LowTrust of "": that one means "asked the sets, not a member", this one
	// means "there was nothing to ask about". Conflating them is what made a
	// sleeping pool member render an add button — which then failed, because
	// `lowtrust add` resolves the address the same way the page just did.
	LowTrustUnknown bool
}

// deviceRow is one DHCP lease as the index renders it. The lease is embedded
// rather than copied field by field so the template's existing .Addr, .Name and
// .MAC keep working and this type only has to describe what it adds.
type deviceRow struct {
	lease
	// Same meaning, formatting and threshold as the peers page's column, and
	// deliberately so: a device reading "3s" here and on its own page is the
	// same claim about the same connection table.
	LastSeen string
	Stale    bool
	// Same meaning as the device page's field of the same name: this row's name
	// is an operator's reservation, not a hostname the device offered.
	NameReserved bool
	// How much of this device's cooldown is left, already formatted; empty when
	// it is not in one. On the index because a cooldown is the one state on
	// these pages that ENDS on its own — being able to see which devices are
	// cut off, without opening each page in turn, is most of what makes it
	// usable as a household instrument rather than a debugging one.
	Cooldown string
	// The unformatted gap behind LastSeen, and whether there was one. Kept
	// unexported because the template has no use for them — they exist so the
	// rows can be ordered by how recently a device was active, which a
	// formatted string cannot do: "3s" sorts after "1d 4h" as text.
	idle  time.Duration
	dated bool
	// Every address this device holds, which is what the row is dated against.
	// A device that has gone quiet on IPv4 and is busy over IPv6 is active, and
	// dating the lease address alone said the opposite.
	addrs []netip.Addr
}

// byLastActive orders the devices list: most recently active first, then the
// devices nothing could be dated for, then by address.
//
// The undated go last rather than first because "no flow this router can date"
// is the weakest claim on the page, not the strongest. It covers a device that
// is genuinely gone, one whose only traffic is a protocol timeoutSysctl does
// not map, and one that has been silent long enough for conntrack to reap its
// entries — and sorting those above a device that spoke three seconds ago would
// invert the whole point of the column.
//
// Address is the final tiebreak, which is also what makes this a no-op on a
// router with no timeout table: nothing is dated, so the list keeps exactly the
// address order readLeases already produced.
func byLastActive(rows []deviceRow) {
	sort.SliceStable(rows, func(i, j int) bool {
		a, b := rows[i], rows[j]
		if a.dated != b.dated {
			return a.dated
		}
		if a.dated && a.idle != b.idle {
			return a.idle < b.idle
		}
		return a.Addr.Less(b.Addr)
	})
}

type indexPageData struct {
	Nav      navData
	Leases   []deviceRow
	Priority []priorityRow
	Error    string
	// Set when the connection table could not be read. Kept apart from Error,
	// which is about the lease file: one failing must not make the page claim
	// the other is empty.
	PriorityError string
}

// priorityRow is one conversation the router is currently prioritising,
// attributed to the device holding it.
type priorityRow struct {
	Device     string
	DeviceName string
	Peer       string
	ASN        uint32
	Org        string
	Country    string
	Bytes      string
	Up         string
	Down       string
	Traffic    traffic
}

type peersServer struct {
	lanNet netip.Prefix
	// Both range tables, re-read when geoip-update replaces the files. Nil is
	// usable and means no attribution — see tables.go for why holding the
	// tables directly was wrong.
	tables     *tableWatcher
	tmpl       *template.Template
	indexTmpl  *template.Template
	leasesPath string
	shapes     *shapeCache
	conntrack  func(context.Context) ([]byte, error)
	runTool    func(name string, args ...string) (string, error)
	// Names the traffic column. Its zero value is usable, so a caller that
	// does not set it gets ports without flags or call markers.
	namer namer
	// Set by main.go when a capture directory is configured. Nil disables the
	// feature: no routes, no banner, and the page behaves exactly as it did
	// before captures existed.
	captures *captureManager
	// neighbours reads the kernel's neighbour table, the only place a device's
	// MAC is available to the page (leases carry an address and a name, not a
	// MAC). Injectable so tests never shell out to ip(8).
	//
	// Set by main.go alongside lowTrust, only when the low-trust pool is
	// enabled: nothing else on the page needs a MAC, so on a router without
	// the pool this would be a fork of ip(8) per page render for a value
	// nobody reads.
	neighbours *neighbourCache
	// lowTrust reports a MAC's low-trust pool membership. Injectable so tests
	// never shell out to nft(8); the real implementation is lowTrustMembership
	// in shaping.go.
	//
	// Nil disables the feature the same way a nil captures does: no routes, no
	// template block, no nft(8) calls that could only fail because the sets do
	// not exist. bongo runs this binary with the pool off, and must behave
	// exactly as it did before the pool existed.
	lowTrust func(ctx context.Context, mac string) string
	// The cooldown sets, read for the banner on a device page and the badge on
	// every index row. Nil disables the feature exactly as a nil captures does:
	// no routes, no banner, no badge, and no nft(8) calls that could only fail
	// because the table does not exist. See cooldown.go.
	cooldowns *cooldownCache
	// The longest cooldown this router will accept, from the same NixOS option
	// the tool's own ceiling comes from. Zero means the built-in default; the
	// tool refuses anything over its ceiling regardless, so this only decides
	// whether an over-long duration comes back as a sentence or as a shell
	// tool's stderr.
	cooldownMax time.Duration
	// Builds the shared nav strip. Zero value is usable: an empty hostname and
	// a grey lamp, which is what a test server renders and what a router with
	// no probing shows.
	nav navSource
	// Turns each flow's conntrack countdown into a last-seen time. Nil in
	// tests that pass their own fixture expectations; the page then renders
	// blank last-seen cells and is otherwise unchanged.
	timeouts *timeoutTable
	// The static DHCP reservations, which name a device the lease file has
	// forgotten — see reservations.go for why that is the normal state for the
	// devices someone bothered to name rather than an edge case.
	//
	// Nil disables it: a router with no reservation file configured reads none,
	// and every page is what it was before this existed.
	reservations *reservationFile
	// Reverse DNS names for the peer addresses. The render path only ever
	// reads this cache, never fills it — see rdns.go for why the resolver is
	// kept off the render path entirely, and for the browser's half of it.
	//
	// Nil disables the feature the way a nil captures does: no names, no
	// lookup route, and the template's fill-in script has nothing to ask.
	rdns *rdnsCache
	// The resolver's answer log, which names an address that has no PTR. Nil
	// disables it: no second line under any address, and the page is what it
	// was before. Read-only from here and never blocking — see answerlog.go.
	answers *answerLog
	// The dark-peer collector, which samples this server's own readers on a
	// timer and publishes what it found. Nil disables it and its route; it is
	// only ever non-nil when answers is, since without a name to test against
	// it has nothing to say. See darkpeer.go.
	dark *darkPeerMonitor
}

func newPeersServer(lanNet netip.Prefix, tables *tableWatcher, tmpl, indexTmpl *template.Template, leasesPath string) *peersServer {
	return &peersServer{
		lanNet:     lanNet,
		tables:     tables,
		tmpl:       tmpl,
		indexTmpl:  indexTmpl,
		leasesPath: leasesPath,
		shapes:     newShapeCache(),
		conntrack:  readConntrack,
		runTool:    runTool,
		timeouts:   newTimeoutTable(),
		rdns:       newRDNSCache(),
	}
}

// handleIndex lists the devices currently holding a DHCP lease, each linking to
// its peers page. It is the entry point for the whole feature: without it the
// mesh address answers 404 at the root and the operator has to already know a
// device address to get anywhere.
//
// A missing or unreadable lease file renders the page with a notice rather than
// failing it. The peers pages remain reachable by address, so a broken index is
// an inconvenience and not an outage.
func (s *peersServer) handleIndex(w http.ResponseWriter, r *http.Request) {
	// Registered as "GET /peers" and "GET /peers/{$}", which match those two
	// paths and nothing else, so a request for any other path never reaches
	// this handler. The check is kept as a guard in case either pattern is
	// ever loosened to a prefix match, which would silently make this the
	// catch-all for everything under /peers.
	if r.URL.Path != "/peers" && r.URL.Path != "/peers/" {
		http.NotFound(w, r)
		return
	}

	var data indexPageData
	leases, err := readLeases(s.leasesPath, s.lanNet)
	if err != nil {
		log.Printf("peers index: read leases from %q: %v", s.leasesPath, err)
		data.Error = "Cannot read the DHCP lease file, so no devices can be listed. A peers page is still reachable directly at /peers/<address>."
	}
	data.Nav = s.nav.data("devices", true)
	data.Leases = s.deviceRows(r.Context(), leases)

	// One dump serves both the prioritised table and the last-seen column. The
	// connection table is the largest thing this page reads, and sampling it
	// twice would also give the two tables views of the LAN seconds apart —
	// a device could be prioritised in one and idle in the other.
	raw, rawErr := s.conntrackDump(r.Context())
	data.Priority, data.PriorityError = s.priorityNow(raw, rawErr, leases)
	s.annotateLastSeen(data.Leases, raw, rawErr)
	byLastActive(data.Leases)

	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	if err := s.indexTmpl.Execute(w, data); err != nil {
		log.Printf("peers index: render: %v", err)
	}
}

// priorityNow lists every conversation on the LAN currently carrying the
// router's high-priority conntrack mark, newest state each time the page is
// loaded. It answers "what is being prioritised right now, anywhere on this
// network" without opening each device's page in turn.
//
// Returns a notice rather than an error: the device list is the page's job and
// must survive an unreadable connection table. An empty result with no notice
// genuinely means nothing is prioritised.
// conntrackDump reads the connection table once for the whole index page.
//
// Returns (nil, nil) when nothing on the page needs it, which is the case on a
// router with no call mark configured and no timeout table: the prioritised
// table would have nothing to select on and the last-seen column nothing to
// date with, so the fork is pure cost.
func (s *peersServer) conntrackDump(ctx context.Context) ([]byte, error) {
	if s.namer.callMark == 0 && s.timeouts == nil {
		return nil, nil
	}
	ctx, cancel := context.WithTimeout(ctx, conntrackTimeout)
	defer cancel()
	raw, err := s.conntrack(ctx)
	if err != nil {
		log.Printf("peers index: read conntrack: %v", err)
		return nil, err
	}
	return raw, nil
}

// annotateLastSeen fills in how long ago each listed device last carried a
// packet, in place.
//
// A failure here is silent by design. The prioritised table above already
// carries a banner for an unreadable connection table, and a second notice
// about the same failure would read as two things being broken. Blank cells are
// the honest fallback and the column already renders them for a device with no
// datable flow.
func (s *peersServer) annotateLastSeen(rows []deviceRow, raw []byte, readErr error) {
	if s.timeouts == nil || readErr != nil || raw == nil {
		return
	}
	interest := newAddrSet()
	for _, row := range rows {
		interest.add(row.addrs...)
	}
	idle, err := deviceIdle(strings.NewReader(string(raw)), interest, s.timeouts)
	if err != nil {
		log.Printf("peers index: parse conntrack for last seen: %v", err)
		return
	}
	for i := range rows {
		// The freshest of the device's addresses, for the reason the peers page
		// takes the freshest flow: a device is as awake as its liveliest
		// address, and a stale IPv4 entry must not bury a busy IPv6 one.
		for _, addr := range rows[i].addrs {
			seen, ok := idle[addr.Unmap()]
			if !ok || (rows[i].dated && seen >= rows[i].idle) {
				continue
			}
			rows[i].idle, rows[i].dated = seen, true
		}
		if rows[i].dated {
			rows[i].LastSeen = formatDuration(rows[i].idle)
			rows[i].Stale = rows[i].idle >= staleAfter
		}
	}
}

// deviceRows turns the DHCP leases and the neighbour table into one list.
//
// Leases first, each folded together with every other address its MAC holds, so
// a phone appears once carrying its IPv4 lease and its SLAAC addresses rather
// than once per address or — as before — only in IPv4.
//
// Then whatever the neighbour table knows that no lease does: a device with a
// static address, or one that only ever configured itself over IPv6. Those had
// no way to appear at all, because the list was the DHCP lease file and nothing
// hands out an IPv6 address here for a lease file to record.
func (s *peersServer) deviceRows(ctx context.Context, leases []lease) []deviceRow {
	neigh := s.neighbours.get(ctx)
	entries := parseNeighbours(neigh)

	byMAC := map[string][]netip.Addr{}
	for _, entry := range entries {
		byMAC[entry.MAC] = append(byMAC[entry.MAC], entry.Addr)
	}

	rows := make([]deviceRow, 0, len(leases))
	claimed := map[string]bool{}
	for _, entry := range leases {
		row := deviceRow{lease: entry, addrs: []netip.Addr{entry.Addr}}
		mac := strings.ToLower(entry.MAC)
		if mac == "" {
			// No MAC on the lease, so nothing to join the families on. The
			// live table may still know one for the address.
			mac = macForDevice(neigh, entry.Addr)
		}
		if mac != "" {
			claimed[mac] = true
			for _, addr := range byMAC[mac] {
				if addr != entry.Addr {
					row.addrs = append(row.addrs, addr)
				}
			}
		}
		rows = append(rows, row)
	}

	for mac, addrs := range byMAC {
		if claimed[mac] {
			continue
		}
		rows = append(rows, deviceRow{
			// Keyed on the address the page will be reached by, chosen with
			// pickDeviceAddr rather than taken at random: a map iterates in a
			// different order every render, and a link that moves between
			// reloads is not a link.
			lease: lease{Addr: pickDeviceAddr(addrs), MAC: mac},
			addrs: addrs,
		})
	}

	// Names for the rows the lease file could not name: a device that offered
	// no hostname, and — the case this was written for — a device whose
	// reservation is `infinite`, which stops it renewing and so eventually
	// takes it out of the lease file altogether. Read once for the whole page.
	reserved := s.reservations.load()
	for i := range rows {
		if rows[i].Name != "" {
			continue
		}
		if name := reserved.name(rows[i].MAC, rows[i].Addr); name != "" {
			rows[i].Name, rows[i].NameReserved = name, true
		}
	}
	// One read of the cooldown sets for the whole page — the cache is what
	// keeps this from being three forks of nft(8) per row.
	if s.cooldowns != nil {
		index := s.cooldowns.get(ctx)
		for i := range rows {
			if left, ok := index.remaining(rows[i].MAC, rows[i].addrs); ok {
				rows[i].Cooldown = formatDuration(left)
			}
		}
	}
	return rows
}

// pickDeviceAddr chooses the address that names a device with no DHCP lease.
//
// A routable address wins over a link-local one: fe80:: works as a page key but
// tells a reader nothing they can use elsewhere, and IPv4 wins over IPv6 among
// routable ones because it is the shorter thing to read and to type. Lowest
// address breaks the remaining ties, so the choice is stable across renders.
func pickDeviceAddr(addrs []netip.Addr) netip.Addr {
	best := netip.Addr{}
	rank := func(a netip.Addr) int {
		switch {
		case a.IsLinkLocalUnicast():
			return 2
		case a.Is4():
			return 0
		default:
			return 1
		}
	}
	for _, addr := range addrs {
		if !best.IsValid() || rank(addr) < rank(best) ||
			(rank(addr) == rank(best) && addr.Less(best)) {
			best = addr
		}
	}
	return best
}

func (s *peersServer) priorityNow(raw []byte, readErr error, leases []lease) ([]priorityRow, string) {
	if s.namer.callMark == 0 {
		// No mark configured, so there is nothing to collect and an empty
		// table would be a claim rather than an answer.
		return nil, ""
	}
	if readErr != nil {
		return nil, "Cannot read the connection table, so prioritised traffic cannot be listed. The device list below is unaffected."
	}
	marked, err := parseMarkedFlows(strings.NewReader(string(raw)), s.lanNet, s.namer.callMark)
	if err != nil {
		log.Printf("peers index: parse conntrack: %v", err)
		return nil, "Cannot parse the connection table, so prioritised traffic cannot be listed. The device list below is unaffected."
	}

	names := map[netip.Addr]string{}
	for _, entry := range leases {
		names[entry.Addr] = entry.Name
	}

	rows := make([]priorityRow, 0, len(marked))
	for _, conv := range marked {
		row := priorityRow{
			Device:     conv.Device.String(),
			DeviceName: names[conv.Device],
			Peer:       conv.Peer.Addr.String(),
			Bytes:      formatBytes(conv.Peer.Bytes),
			Up:         formatBytes(conv.Peer.Up),
			Down:       formatBytes(conv.Peer.Down),
			Traffic:    s.namer.describe(conv.Peer),
		}
		if info, found := s.tables.asnTable().Lookup(conv.Peer.Addr); found {
			row.ASN, row.Org = info.Number, info.Org
		}
		if code, found := s.tables.geoTable().Lookup(conv.Peer.Addr); found {
			row.Country = code
		}
		rows = append(rows, row)
	}
	return rows, ""
}

// How many addresses one fill-in request may ask about, and how long the
// server spends on them.
//
// The cap is a bound on work per request, not a limit the page runs into: the
// script sends its addresses in batches of this size, so a device with three
// hundred peers takes three requests rather than being truncated. The deadline
// is generous because this request blocks nothing — the page is already on
// screen and readable — but finite, because a nameserver that blackholes would
// otherwise hold the connection open until the browser gave up.
const (
	rdnsBatchLimit   = 64
	rdnsBatchTimeout = 8 * time.Second
)

// handleRDNS answers the reverse-DNS names for a batch of peer addresses.
//
// This is the one place a PTR lookup happens, and it is reached only from the
// script at the bottom of peers.html, after the page has rendered. Anything it
// resolves is cached, so the next render of this page serves the same names
// from the template instead.
func (s *peersServer) handleRDNS(w http.ResponseWriter, r *http.Request) {
	if !sameOrigin(w, r) {
		return
	}
	// The {device} check is applied for the same reason every other route
	// applies it: it keeps these URLs from being pointed somewhere outside the
	// LAN. It does not restrict which addresses may be asked about — those are
	// the peers the page is already showing, and this listener is reachable
	// only from the LAN and the mesh.
	if _, ok := s.device(r); !ok {
		http.NotFound(w, r)
		return
	}

	seen := map[netip.Addr]bool{}
	wanted := make([]netip.Addr, 0, rdnsBatchLimit)
	for _, raw := range r.URL.Query()["addr"] {
		addr, err := netip.ParseAddr(raw)
		if err != nil {
			// One unparseable address does not fail the batch. The rest are
			// still names the operator asked for, and a 400 here would blank
			// every other cell in the table.
			continue
		}
		addr = addr.Unmap()
		if seen[addr] {
			continue
		}
		seen[addr] = true
		if wanted = append(wanted, addr); len(wanted) >= rdnsBatchLimit {
			break
		}
	}

	ctx, cancel := context.WithTimeout(r.Context(), rdnsBatchTimeout)
	defer cancel()
	found := s.rdns.resolveMany(ctx, wanted)

	// Keyed by address, and an empty string means a resolved absence — the
	// script uses that to stop asking about the address rather than rendering
	// anything. An address missing from the object entirely is one that did
	// not resolve in time, which the next page load will ask about again.
	names := make(map[string]string, len(found))
	for addr, name := range found {
		names[addr.String()] = name
	}
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	if err := json.NewEncoder(w).Encode(names); err != nil {
		log.Printf("peers: rdns encode: %v", err)
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

// peerAction is one button on the peers page. Kept as data rather than as three
// near-identical handlers so the CSRF check, the address guards and the journal
// line stay written once — a route that forgot one of them would be an
// unauthenticated firewall mutation.
type peerAction struct {
	// name labels the action in the journal.
	name string
	tool string
	// argv builds the command line. A function rather than a fixed prefix
	// because killconn takes the device as well as the peer, and the other two
	// would otherwise carry a parameter they never use.
	argv func(peer, device netip.Addr) []string
	// invalidate says whether this action changes what shaping.go reads.
	// killconn touches no firewall state, and invalidating for it would force a
	// re-read of feeds running to tens of thousands of elements — the cost the
	// cache exists to avoid.
	invalidate bool
	// peerless marks an action on the device as a whole. The peer form field is
	// not read and argv receives the zero Addr. The public-address guard is
	// skipped because there is no peer to guard — the {device} check is what
	// keeps the route from being pointed anywhere else.
	peerless bool
}

func addPeer(peer, _ netip.Addr) []string { return []string{"add", peer.String()} }

// mux builds a mux carrying only the peers routes. Used by the tests; the mesh
// listener composes them onto the status routes through registerRoutes.
func (s *peersServer) mux() *http.ServeMux {
	mux := http.NewServeMux()
	s.registerRoutes(mux)
	return mux
}

// registerRoutes adds every route that can see or change a device.
//
// The list lives under /peers rather than at the root because the root is now
// the status page on both listeners. Both spellings are registered: a trailing
// slash is what a browser produces after following a relative link, and a
// redirect between them would be a third behaviour to remember.
func (s *peersServer) registerRoutes(mux *http.ServeMux) {
	if s.indexTmpl != nil {
		mux.HandleFunc("GET /peers", s.handleIndex)
		mux.HandleFunc("GET /peers/{$}", s.handleIndex)
	}
	mux.HandleFunc("GET /peers/{device}", s.handlePage)
	// The dark-peer collector's scrape endpoint, registered here rather than
	// beside the uplink prober's /metrics because of what it says: which
	// device is talking to which address, which is the same claim every route
	// in this function makes and the reason none of them is on the LAN
	// listener. Alloy reaches it over the mesh address.
	if s.dark != nil {
		mux.HandleFunc("GET /metrics/peers", s.dark.handleMetrics)
	}
	// The browser's half of the reverse-DNS column. Absent when the cache is
	// nil, matching the template: a page that renders no fill-in script must
	// not leave a route behind that nothing calls.
	if s.rdns != nil {
		mux.HandleFunc("GET /peers/{device}/rdns", s.handleRDNS)
	}
	// Scoped like drop below, but for a different reason: the address goes into
	// the throttle set for everyone, and only the WAIT before it bites is
	// waived, and only for the device whose page the button was on. Without
	// that the row keeps moving bytes at full speed until the pair has spent
	// graceBytes, which on a conversation already megabytes deep reads as the
	// button having done nothing. See seed_spent_grace in tempthrottle.bash.
	mux.HandleFunc("POST /peers/{device}/throttle", s.handleAction(peerAction{
		name: "throttle", tool: "tempthrottle", invalidate: true,
		argv: func(peer, device netip.Addr) []string {
			return []string{"add", peer.String(), "for", device.String()}
		},
	}))
	mux.HandleFunc("POST /peers/{device}/block", s.handleAction(peerAction{
		name: "block", tool: "tempblock", argv: addPeer, invalidate: true,
	}))
	// Scoped to the device whose page this was posted from: the row is that
	// device's connection, and cutting another device's flows to the same peer
	// is more than the button implies. The unscoped form stays available from
	// the CLI.
	mux.HandleFunc("POST /peers/{device}/drop", s.handleAction(peerAction{
		name: "drop", tool: "killconn",
		argv: func(peer, device netip.Addr) []string {
			return []string{peer.String(), "from", device.String()}
		},
	}))
	// The whole device at once. An app whose session survives one endpoint
	// dying does not survive its entire flow table going, which is what
	// "make it reconnect" actually takes.
	mux.HandleFunc("POST /peers/{device}/drop-all", s.handleAction(peerAction{
		name: "drop-all", tool: "killconn", peerless: true,
		argv: func(_, device netip.Addr) []string {
			return []string{"from", device.String()}
		},
	}))
	// Absent unless the low-trust pool is enabled, for the same reason the
	// capture routes are: the `lowtrust` tool is only installed on a router
	// that has the pool, so registering these elsewhere would offer a button
	// whose only possible outcome is a 500.
	//
	// Device-scoped like drop-all: the pool is a property of the device, not of
	// one conversation, so there is no peer form field and peerless skips the
	// public-address guard that would have nothing to guard. invalidate is
	// deliberately left false: the shaping cache keyed by peer address is
	// unaffected by device membership.
	if s.lowTrust != nil {
		mux.HandleFunc("POST /peers/{device}/lowtrust", s.handleAction(peerAction{
			name: "lowtrust", tool: "lowtrust", peerless: true,
			argv: func(_, device netip.Addr) []string {
				return []string{"add", device.String()}
			},
		}))
		mux.HandleFunc("POST /peers/{device}/lowtrust/remove", s.handleAction(peerAction{
			name: "lowtrust-remove", tool: "lowtrust", peerless: true,
			argv: func(_, device netip.Addr) []string {
				return []string{"del", device.String()}
			},
		}))
	}
	// Absent unless this router has the cooldown table and tool, for the same
	// reason the low-trust routes are: a button whose only possible outcome is
	// a 500 should not be offered. Not a peerAction, because it is the one
	// action here that carries a value from the operator — see cooldown.go.
	if s.cooldowns != nil {
		mux.HandleFunc("POST /peers/{device}/cooldown", s.handleCooldownStart)
		mux.HandleFunc("POST /peers/{device}/cooldown/end", s.handleCooldownEnd)
	}
	// Absent unless a capture directory is configured, so a router without one
	// answers 404 here exactly as it did before this feature.
	if s.captures != nil {
		mux.HandleFunc("POST /peers/{device}/capture/start", s.handleCaptureStart)
		mux.HandleFunc("POST /peers/{device}/capture/stop", s.handleCaptureStop)
		mux.HandleFunc("POST /peers/{device}/capture/discard", s.handleCaptureDiscard)
		mux.HandleFunc("GET /peers/{device}/capture.pcap", s.handleCaptureDownload)
	}
}

// device parses and validates the {device} path value against the LAN prefix.
// device parses and vets the address in the URL.
//
// The vetting is what keeps this page pointed at the LAN. Without it, /peers
// followed by any address would report which of this network's devices are
// talking to it, which is the network's business and not a visitor's.
//
// Two ways to pass, because there are now two kinds of device. One is inside
// the configured IPv4 range, which is every DHCP client. The other is a
// neighbour on the LAN interface, which is how an IPv6-only or statically
// addressed device qualifies — there is no configured IPv6 prefix to test
// against, the delegated one changes on every redial, and a neighbour on lan0
// is on the local link by definition. Neither route admits an internet address.
func (s *peersServer) device(r *http.Request) (netip.Addr, bool) {
	addr, err := netip.ParseAddr(r.PathValue("device"))
	if err != nil {
		return netip.Addr{}, false
	}
	addr = addr.Unmap()
	if s.lanNet.Contains(addr) {
		return addr, true
	}
	if macForDevice(s.neighbours.get(r.Context()), addr) != "" {
		return addr, true
	}
	return netip.Addr{}, false
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

	// Read once and use for everything that needs it: the address union below,
	// the MAC on the page, and low-trust membership. Three reads would be three
	// forks of ip(8) per render, and worse, three views of a table that changes
	// under them.
	neigh := s.neighbours.get(ctx)

	raw, err := s.conntrack(ctx)
	if err != nil {
		// Deliberately not an empty page: an unreadable table and an idle
		// device must not look alike.
		log.Printf("peers: read conntrack: %v", err)
		http.Error(w, "cannot read connection table", http.StatusInternalServerError)
		return
	}
	// Every address this device holds, not just the one in the URL. The lease
	// address is always in the set even when the neighbour table has nothing —
	// a device the kernel has evicted still gets its own page, it just gets the
	// IPv4 half of it.
	mac := macForDevice(neigh, device)
	others := addressesForMAC(neigh, mac)
	addresses := newAddrSet(device)
	addresses.add(others...)

	peers, err := parseConntrack(strings.NewReader(string(raw)), addresses, s.timeouts)
	if err != nil {
		log.Printf("peers: parse conntrack: %v", err)
		http.Error(w, "cannot parse connection table", http.StatusInternalServerError)
		return
	}

	var total uint64
	for _, peer := range peers {
		total += peer.Bytes
	}

	// How the router is already treating each peer. A nil cache (tests, or a
	// router where the sets cannot be read) simply leaves the column blank.
	var shapes *shapeIndex
	if s.shapes != nil {
		shapes = s.shapes.get(ctx)
	}

	data := peersPageData{Device: device.String(), Error: notice}
	// Both peers pages mark "devices" current: a device page is a leaf of that
	// section, and a strip that highlighted nothing there would read as a page
	// that had fallen outside the site.
	data.Nav = s.nav.data("devices", true)

	// How DHCP knows this device. Read from the lease file rather than the
	// neighbour table because that lookup is gated on the low-trust feature
	// being enabled, and the identity of the device is not — a router with the
	// pool switched off should still say whose page this is.
	//
	// A failure here is deliberately silent: the lease file being unreadable
	// costs a name and a MAC, and saying so in the page's error banner would
	// imply the connection table below it is suspect, which it is not.
	sort.Slice(others, func(i, j int) bool { return others[i].Less(others[j]) })
	for _, addr := range others {
		if addr != device {
			data.AlsoAddrs = append(data.AlsoAddrs, addr.String())
		}
	}

	if leases, err := readLeases(s.leasesPath, s.lanNet); err == nil {
		for _, entry := range leases {
			if entry.Addr == device {
				data.Name, data.MAC = entry.Name, entry.MAC
				break
			}
		}
	}

	// What the lease file could not say. The MAC is the neighbour table's,
	// already read above for the address union, and the name is the operator's
	// reservation.
	//
	// Both matter most for the same device: one with an `infinite` reservation,
	// which never renews and so has no lease line to be found in. That device
	// used to render an em-dash for its name and an em-dash for its MAC — and
	// with no MAC on the page there was nothing to copy into the low-trust
	// secret, so the pool could not be made permanent for the very devices
	// someone had already gone to the trouble of naming.
	if data.MAC == "" {
		data.MAC = mac
	}
	if data.Name == "" {
		if name := s.reservations.load().name(data.MAC, device); name != "" {
			data.Name, data.NameReserved = name, true
		}
	}

	if s.captures != nil {
		data.Capture = s.captures.Get(device)
	}
	// Asked with both handles, because the ruleset holds both: the MAC, which
	// is what the drop is really keyed on, and every address this device is
	// known to hold, which is what covers a device the neighbour table has no
	// entry for. The lease MAC stands in when the live table has none, the same
	// fallback the low-trust lookup below makes and for the same reason — a
	// sleeping device is evicted from the neighbour table within minutes, and a
	// device in cooldown has every reason to have gone quiet.
	if s.cooldowns != nil {
		data.CooldownEnabled = true
		cooldownMAC := mac
		if cooldownMAC == "" {
			cooldownMAC = data.MAC
		}
		cooldownAddrs := make([]netip.Addr, 0, len(addresses))
		for addr := range addresses {
			cooldownAddrs = append(cooldownAddrs, addr)
		}
		data.Cooldown = s.cooldownFor(ctx, cooldownMAC, cooldownAddrs)
	}
	// The pool is keyed on MAC, not address, so the address has to be resolved
	// first, and from two places rather than one. The neighbour table is the
	// live answer and wins when it has an entry — it is the only source that
	// notices an address changing hands. But the kernel evicts an entry within
	// minutes of a device going quiet, while the device's conntrack flows and
	// its DHCP lease both outlive that by hours, so a page rendered from the
	// neighbour table alone reports a sleeping pool member as a non-member for
	// most of the time it is asleep. The lease MAC is already on this page
	// under data.MAC; falling back to it costs nothing and covers exactly that
	// window.
	//
	// Only when both are empty is membership genuinely unknown, and that is
	// recorded as its own state rather than folded into "not a member".
	//
	// Both nil on a router without the pool, which is what keeps the whole
	// lookup — a fork of ip(8) and up to two of nft(8), per page render — off
	// a router that has no sets for them to read.
	if s.lowTrust != nil {
		data.LowTrustEnabled = true
		// The live MAC wins, and the lease MAC covers the window where the
		// kernel has evicted a sleeping device's entry but its lease has not
		// expired. Only when both are empty is membership genuinely unknown.
		poolMAC := mac
		if poolMAC == "" {
			poolMAC = data.MAC
		}
		if poolMAC == "" {
			data.LowTrustUnknown = true
		} else {
			data.LowTrust = s.lowTrust(ctx, poolMAC)
		}
	}
	for _, peer := range peers {
		share := 0.0
		if total > 0 {
			share = float64(peer.Bytes) / float64(total) * 100
		}
		row := peerRow{
			Addr:     peer.Addr.String(),
			Bytes:    formatBytes(peer.Bytes),
			Up:       formatBytes(peer.Up),
			Down:     formatBytes(peer.Down),
			SharePct: fmt.Sprintf("%.1f", share),
			High:     share >= 70,
		}
		row.Shape = shapes.classify(peer.Addr)
		// The CDN quota is per device-and-peer, so it cannot come from the
		// address lookup above. Applied as an upgrade rather than an override:
		// a peer that is also blocked outright should still say blocked.
		if quota := shapes.classifyPair(device, peer.Addr); shapeRank[quota] > shapeRank[row.Shape] {
			row.Shape = quota
		}
		if peer.HaveIdle {
			row.LastSeen = formatDuration(peer.Idle)
			row.Stale = peer.Idle >= staleAfter
		}
		row.Traffic = s.namer.describe(peer)
		// Cache read only. A miss leaves RDNSKnown false, which is the
		// template's cue to let the browser ask for this one — nothing here
		// waits on a resolver.
		row.RDNS, row.RDNSKnown = s.rdns.cached(peer.Addr)
		// No lookup and no wait: the answer log is read by its own goroutine,
		// so this is a map read like the two table lookups below it.
		row.DNSName, _ = s.answers.Lookup(peer.Addr)
		if info, found := s.tables.asnTable().Lookup(peer.Addr); found {
			row.ASN, row.Org = info.Number, info.Org
		}
		if code, found := s.tables.geoTable().Lookup(peer.Addr); found {
			row.Country = code
		}
		data.Peers = append(data.Peers, row)
	}

	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	if err := s.tmpl.Execute(w, data); err != nil {
		log.Printf("peers: render: %v", err)
	}
}

// sameOrigin refuses a cross-site request, answering it and reporting false.
//
// Browsers send Sec-Fetch-Site on every request, and a cross-site form POST
// carries "cross-site". Non-browser callers (curl over the mesh) send no such
// header, so absence is allowed and only an explicit cross-origin value is
// refused. This is the whole CSRF defence: these endpoints are otherwise
// unauthenticated by design.
//
// Browsers also send "none" for a typed URL, a bookmark, or a link opened
// from another application — never something a cross-site page can produce —
// so it is allowed alongside absence and "same-origin". That matters for
// capture.pcap specifically: it is exactly the URL an operator bookmarks to
// collect a capture later.
//
// Shared rather than repeated per handler. If it were copied into each of the
// eight routes that need it, one copy would eventually drift — and on these
// routes that means an unauthenticated firewall mutation or a capture handed
// to another origin.
func sameOrigin(w http.ResponseWriter, r *http.Request) bool {
	if site := r.Header.Get("Sec-Fetch-Site"); site != "" && site != "same-origin" && site != "none" {
		http.Error(w, "cross-site request refused", http.StatusForbidden)
		return false
	}
	return true
}

// handleAction returns a handler that runs one of the router's tools against a
// peer.
func (s *peersServer) handleAction(action peerAction) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if !sameOrigin(w, r) {
			return
		}

		device, ok := s.device(r)
		if !ok {
			http.NotFound(w, r)
			return
		}
		// A peerless action operates on the device as a whole, so there is no
		// form field to read and nothing for the address guard below to guard.
		// peer stays the zero Addr, which argv ignores and logAction renders
		// as "-".
		var peer netip.Addr
		if !action.peerless {
			parsed, err := netip.ParseAddr(r.PostFormValue("peer"))
			if err != nil {
				http.Error(w, "unparseable peer address", http.StatusBadRequest)
				return
			}
			peer = parsed.Unmap()
			if !isPublicAddr(peer) {
				// Refused before the tool is invoked: shaping the gateway or
				// another LAN device is hard to undo from the far side of it.
				// Applied to drop as well, where it is a weaker requirement —
				// killing a flow is recoverable in a way firewalling one is not
				// — because an inconsistent rule between adjacent buttons is
				// worse than a strict one.
				s.logAction(action.name, peer, device, "refused: not a public address")
				http.Error(w, "peer must be a public address", http.StatusBadRequest)
				return
			}
		}

		output, runErr := s.runTool(action.tool, action.argv(peer, device)...)
		result := "ok"
		if runErr != nil {
			result = fmt.Sprintf("error: %v: %s", runErr, output)
		}
		s.logAction(action.name, peer, device, result)

		if runErr != nil {
			http.Error(w, fmt.Sprintf("%s failed: %s", action.tool, output), http.StatusInternalServerError)
			return
		}
		// Before the redirect, or the page it lands on is served from an index
		// up to a TTL old and the peer still reads as untouched.
		if action.invalidate && s.shapes != nil {
			s.shapes.invalidate()
		}
		http.Redirect(w, r, "/peers/"+device.String(), http.StatusSeeOther)
	}
}

// logAction writes the one line that makes blocks collectable later. The ASN,
// share-bearing device and outcome are included deliberately: an address on its
// own ages badly, and the reason is what is wanted months later.
func (s *peersServer) logAction(action string, peer, device netip.Addr, result string) {
	// A device-wide action has no peer. Rendered as "-" rather than left to
	// print the zero Addr's "invalid IP", which reads like a rejected request
	// in a log people grep months later.
	if !peer.IsValid() {
		log.Printf("peer-action action=%s peer=\"-\" device=%q result=%q", action, device, result)
		return
	}
	info, _ := s.tables.asnTable().Lookup(peer)
	// The country here is the geolocation, not the AS registration the info
	// struct carries — the log line names the same thing the page does, or it
	// is useless for correlating one against the other.
	country, _ := s.tables.geoTable().Lookup(peer)
	log.Printf("peer-action action=%s peer=%q asn=%d org=%q cc=%s device=%q result=%q",
		action, peer, info.Number, info.Org, country, device, result)
}

// captureRequest applies the two guards every capture route needs: the CSRF
// check, and the {device} check that keeps the route from being pointed at an
// address outside the LAN. It answers the request itself when either fails.
func (s *peersServer) captureRequest(w http.ResponseWriter, r *http.Request) (netip.Addr, bool) {
	if !sameOrigin(w, r) {
		return netip.Addr{}, false
	}
	device, ok := s.device(r)
	if !ok {
		http.NotFound(w, r)
		return netip.Addr{}, false
	}
	return device, true
}

// captureResult renders an action's outcome for the journal.
func captureResult(err error) string {
	if err != nil {
		return "error: " + err.Error()
	}
	return "ok"
}

func (s *peersServer) handleCaptureStart(w http.ResponseWriter, r *http.Request) {
	device, ok := s.captureRequest(w, r)
	if !ok {
		return
	}
	err := s.captures.Start(device)
	s.logAction("capture-start", netip.Addr{}, device, captureResult(err))
	if err != nil {
		// Rendered rather than returned as an error status: the device's peers
		// are why the operator is on this page, and a capture that would not
		// start must not take them away.
		s.render(w, r, device, "Cannot start a capture: "+err.Error())
		return
	}
	http.Redirect(w, r, "/peers/"+device.String(), http.StatusSeeOther)
}

// handleCaptureStop ends the capture and sends the browser to the download, so
// one click both stops and collects. The file stays on disk either way, so a
// download that fails or is cancelled has not lost the capture.
func (s *peersServer) handleCaptureStop(w http.ResponseWriter, r *http.Request) {
	device, ok := s.captureRequest(w, r)
	if !ok {
		return
	}
	err := s.captures.Stop(device)
	s.logAction("capture-stop", netip.Addr{}, device, captureResult(err))
	if err != nil {
		s.render(w, r, device, "Cannot stop the capture: "+err.Error())
		return
	}
	http.Redirect(w, r, "/peers/"+device.String()+"/capture.pcap", http.StatusSeeOther)
}

func (s *peersServer) handleCaptureDiscard(w http.ResponseWriter, r *http.Request) {
	device, ok := s.captureRequest(w, r)
	if !ok {
		return
	}
	err := s.captures.Discard(device)
	s.logAction("capture-discard", netip.Addr{}, device, captureResult(err))
	if err != nil {
		s.render(w, r, device, "Cannot discard the capture: "+err.Error())
		return
	}
	http.Redirect(w, r, "/peers/"+device.String(), http.StatusSeeOther)
}

func (s *peersServer) handleCaptureDownload(w http.ResponseWriter, r *http.Request) {
	device, ok := s.captureRequest(w, r)
	if !ok {
		return
	}
	file, info, err := s.captures.Open(device)
	if errors.Is(err, errCaptureRunning) {
		// Distinct from "no capture": an operator who bookmarks or reloads
		// this URL mid-capture must not be told the capture doesn't exist
		// when the page they came from says it's running.
		http.Error(w, "capture still running; stop it first", http.StatusConflict)
		return
	}
	if err != nil {
		http.Error(w, "no capture to download", http.StatusNotFound)
		return
	}
	defer file.Close()
	s.logAction("capture-download", netip.Addr{}, device, "ok")

	// Named for the device and the time it stopped, because a directory of
	// files called capture.pcap is a directory nobody can read later. No
	// quoting needed: both halves come from a parsed address and a formatted
	// time, neither of which can carry a quote.
	name := fmt.Sprintf("%s-%s.pcap", device, info.ModTime().Format("20060102-1504"))
	w.Header().Set("Content-Type", "application/vnd.tcpdump.pcap")
	w.Header().Set("Content-Disposition", `attachment; filename="`+name+`"`)
	http.ServeContent(w, r, name, info.ModTime(), file)
}
