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
	Shape    string
	Traffic  traffic
}

type peersPageData struct {
	Device string
	Peers  []peerRow
	Error  string
}

type indexPageData struct {
	Leases []lease
	Error  string
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

	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	if err := s.indexTmpl.Execute(w, data); err != nil {
		log.Printf("peers index: render: %v", err)
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

func (s *peersServer) mux() *http.ServeMux {
	mux := http.NewServeMux()
	if s.indexTmpl != nil {
		mux.HandleFunc("GET /{$}", s.handleIndex)
	}
	mux.HandleFunc("GET /peers/{device}", s.handlePage)
	mux.HandleFunc("POST /peers/{device}/throttle", s.handleAction("throttle", "tempthrottle"))
	mux.HandleFunc("POST /peers/{device}/block", s.handleAction("block", "tempblock"))
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
// peer. action names it for the journal; tool is the executable.
func (s *peersServer) handleAction(action, tool string) http.HandlerFunc {
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
	log.Printf("peer-action action=%s peer=%q asn=%d org=%q cc=%s device=%q result=%q",
		action, peer, info.Number, info.Org, info.Country, device, result)
}
