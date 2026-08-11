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
	Up       string
	Down     string
	SharePct string
	High     bool
	Shape    string
	Traffic  traffic
}

type peersPageData struct {
	Device string
	Peers  []peerRow
	Error  string
}

type indexPageData struct {
	Leases   []lease
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
	lanNet     netip.Prefix
	asn        *ASNTable
	tmpl       *template.Template
	indexTmpl  *template.Template
	leasesPath string
	shapes     *shapeCache
	conntrack  func(context.Context) ([]byte, error)
	runTool    func(name string, args ...string) (string, error)
	// Names the traffic column. Its zero value is usable, so a caller that
	// does not set it gets ports without flags or call markers.
	namer namer
}

func newPeersServer(lanNet netip.Prefix, asn *ASNTable, tmpl, indexTmpl *template.Template, leasesPath string) *peersServer {
	return &peersServer{
		lanNet:     lanNet,
		asn:        asn,
		tmpl:       tmpl,
		indexTmpl:  indexTmpl,
		leasesPath: leasesPath,
		shapes:     newShapeCache(),
		conntrack:  readConntrack,
		runTool:    runTool,
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
	// Registered as "GET /{$}", which matches the root and nothing else, so a
	// request for any other path never reaches this handler. The check is kept
	// as a guard in case that pattern is ever loosened to "GET /", which would
	// silently make this the catch-all for the whole mux.
	if r.URL.Path != "/" {
		http.NotFound(w, r)
		return
	}

	var data indexPageData
	leases, err := readLeases(s.leasesPath, s.lanNet)
	if err != nil {
		log.Printf("peers index: read leases from %q: %v", s.leasesPath, err)
		data.Error = "Cannot read the DHCP lease file, so no devices can be listed. A peers page is still reachable directly at /peers/<address>."
	}
	data.Leases = leases
	data.Priority, data.PriorityError = s.priorityNow(r.Context(), leases)

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
func (s *peersServer) priorityNow(ctx context.Context, leases []lease) ([]priorityRow, string) {
	if s.namer.callMark == 0 {
		// No mark configured, so there is nothing to collect and an empty
		// table would be a claim rather than an answer.
		return nil, ""
	}

	ctx, cancel := context.WithTimeout(ctx, conntrackTimeout)
	defer cancel()

	raw, err := s.conntrack(ctx)
	if err != nil {
		log.Printf("peers index: read conntrack: %v", err)
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
		if info, found := s.asn.Lookup(conv.Peer.Addr); found {
			row.ASN, row.Org, row.Country = info.Number, info.Org, info.Country
		}
		rows = append(rows, row)
	}
	return rows, ""
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

func (s *peersServer) mux() *http.ServeMux {
	mux := http.NewServeMux()
	if s.indexTmpl != nil {
		mux.HandleFunc("GET /{$}", s.handleIndex)
	}
	mux.HandleFunc("GET /peers/{device}", s.handlePage)
	mux.HandleFunc("POST /peers/{device}/throttle", s.handleAction(peerAction{
		name: "throttle", tool: "tempthrottle", argv: addPeer, invalidate: true,
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

	// How the router is already treating each peer. A nil cache (tests, or a
	// router where the sets cannot be read) simply leaves the column blank.
	var shapes *shapeIndex
	if s.shapes != nil {
		shapes = s.shapes.get(ctx)
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
			Up:       formatBytes(peer.Up),
			Down:     formatBytes(peer.Down),
			SharePct: fmt.Sprintf("%.1f", share),
			High:     share >= 70,
		}
		row.Shape = shapes.classify(peer.Addr)
		row.Traffic = s.namer.describe(peer)
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

// handleAction returns a handler that runs one of the router's tools against a
// peer.
func (s *peersServer) handleAction(action peerAction) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		// Browsers send Sec-Fetch-Site on every request; a cross-site form POST
		// carries "cross-site". Non-browser callers (curl over the mesh) send
		// no such header, so absence is allowed and only an explicit
		// cross-origin value is refused. This is the whole CSRF defence: the
		// endpoint is otherwise unauthenticated by design.
		if site := r.Header.Get("Sec-Fetch-Site"); site != "" && site != "same-origin" {
			http.Error(w, "cross-site request refused", http.StatusForbidden)
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
	info, _ := s.asn.Lookup(peer)
	log.Printf("peer-action action=%s peer=%q asn=%d org=%q cc=%s device=%q result=%q",
		action, peer, info.Number, info.Org, info.Country, device, result)
}
