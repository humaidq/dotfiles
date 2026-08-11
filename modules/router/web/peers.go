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

func (s *peersServer) mux() *http.ServeMux {
	mux := http.NewServeMux()
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
