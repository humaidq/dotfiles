package main

import (
	"context"
	"errors"
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
	// What this device's capture slot is doing. Zero when no capture
	// directory is configured, which the template reads as "no banner".
	Capture captureSlot
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
	// Set by main.go when a capture directory is configured. Nil disables the
	// feature: no routes, no banner, and the page behaves exactly as it did
	// before captures existed.
	captures *captureManager
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
	// Absent unless a capture directory is configured, so a router without one
	// answers 404 here exactly as it did before this feature.
	if s.captures != nil {
		mux.HandleFunc("POST /peers/{device}/capture/start", s.handleCaptureStart)
		mux.HandleFunc("POST /peers/{device}/capture/stop", s.handleCaptureStop)
		mux.HandleFunc("POST /peers/{device}/capture/discard", s.handleCaptureDiscard)
		mux.HandleFunc("GET /peers/{device}/capture.pcap", s.handleCaptureDownload)
	}
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
	if s.captures != nil {
		data.Capture = s.captures.Get(device)
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
	info, _ := s.asn.Lookup(peer)
	log.Printf("peer-action action=%s peer=%q asn=%d org=%q cc=%s device=%q result=%q",
		action, peer, info.Number, info.Org, info.Country, device, result)
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
