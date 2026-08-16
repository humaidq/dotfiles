package main

import (
	"encoding/json"
	"html/template"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

// The on-demand WireGuard tunnel, as the mesh listener sees it.
//
// This file changes nothing itself. The switch is one word in one file, and a
// root service (routervpn, see ../vpn.bash) watches that file and does the
// work: creates the interface, opens the port gate, publishes the ephemeral
// DNS name. router-web is in the group that can write that one file and holds
// no capability, no tool on its PATH and no access to the server key.
//
// That split is deliberate. This service listens on a network — two of them —
// and the alternative was giving it CAP_NET_ADMIN and the private key of the
// tunnel it switches on, to save a second of latency on a button press.
const (
	// The two words the switch file can hold. Anything else reads as off, on
	// both sides: see read_desired in vpn.bash.
	vpnOn  = "on"
	vpnOff = "off"

	vpnDesiredFile = "desired"
	vpnStatusFile  = "observed.json"
)

// vpnStatus is the reconciler's last report, verbatim. Every field is optional:
// a router that has just been switched on for the first time has a public key
// and no name yet, and one whose zone is unconfigured never has a name at all.
type vpnStatus struct {
	Enabled   bool   `json:"enabled"`
	Interface string `json:"interface"`
	Port      int    `json:"port"`
	Address   string `json:"address"`
	PublicKey string `json:"publicKey"`
	Peers     int    `json:"peers"`
	// The ephemeral name. Label is the random word this session was given and
	// survives a failed publish; FQDN is set only once the record actually
	// exists in the zone, so an endpoint offered here is one that resolves.
	Label string `json:"label"`
	FQDN  string `json:"fqdn"`
	// The line's public address as of the last pass rather than as of now —
	// the two differ for up to a minute after a redial, and which one this is
	// matters when the question being asked is why a client cannot connect.
	//
	// Recorded whether or not the zone is configured or reachable, because it
	// is what a client can be pointed at when there is no name to use.
	PublicAddress string `json:"publicAddress"`
	RecordID      string `json:"recordId"`
	Updated       string `json:"updated"`
	// Whatever went wrong that was not worth tearing the tunnel down for: a
	// zone that would not answer, a line behind carrier NAT. Rendered as a
	// notice rather than an error, because in every case the tunnel itself is
	// still doing what it was asked to do.
	Note string `json:"note"`
}

type vpnService struct {
	dir  string
	tmpl *template.Template
	// How long a switch flip waits for the reconciler to catch up before
	// answering. The page is honest either way — it says "settling" when the
	// two disagree — but a redirect that lands on a page already showing the
	// new state is worth a few seconds of waiting, because the alternative is
	// a reader reloading to find out whether their click did anything.
	settle time.Duration
	poll   time.Duration
	// Builds the shared nav strip. Set by main.go, exactly as peersServer's is;
	// its zero value renders a grey lamp and no links, which is what a test
	// server shows.
	nav navSource
}

func newVPNService(dir string, tmpl *template.Template) *vpnService {
	return &vpnService{
		dir:    dir,
		tmpl:   tmpl,
		settle: 8 * time.Second,
		poll:   200 * time.Millisecond,
	}
}

// startVPN wires the tunnel page up if a state directory is configured.
//
// Opt-in on the directory, the same idiom as the capture and uplink features: a
// router without one registers no routes, shows no entry in the strip and
// behaves exactly as it did before this existed. Every failure is logged and
// returns nil rather than being fatal — losing the status page because a
// template would not parse is a worse outcome than losing the switch.
func startVPN(staticRoot string) *vpnService {
	dir := strings.TrimSpace(os.Getenv("ROUTER_VPN_DIR"))
	if dir == "" {
		return nil
	}
	tmpl, err := template.ParseFiles(
		filepath.Join(staticRoot, "vpn.html"),
		filepath.Join(staticRoot, "nav.html"),
	)
	if err != nil {
		log.Printf("tunnel page disabled: parse vpn template: %v", err)
		return nil
	}
	return newVPNService(dir, tmpl)
}

func (s *vpnService) desiredPath() string { return filepath.Join(s.dir, vpnDesiredFile) }
func (s *vpnService) statusPath() string  { return filepath.Join(s.dir, vpnStatusFile) }

// desired reads the switch. Anything that is not exactly "on" — a missing file,
// an empty one, a word nobody recognises — is off, matching read_desired in
// vpn.bash exactly. The two implementations agreeing on that is what keeps the
// page from claiming a tunnel is on that the reconciler has taken down.
func (s *vpnService) desired() string {
	raw, err := os.ReadFile(s.desiredPath())
	if err != nil {
		return vpnOff
	}
	if strings.TrimSpace(string(raw)) == vpnOn {
		return vpnOn
	}
	return vpnOff
}

// setDesired flips the switch.
//
// Truncated in place rather than written to a temporary file and renamed. The
// path unit that wakes the reconciler watches this file for a close-after-write
// and would never see a rename, and the file's group ownership — which is the
// only reason this process can write it at all — belongs to the file, not to
// this process.
func (s *vpnService) setDesired(word string) error {
	file, err := os.OpenFile(s.desiredPath(), os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0o660)
	if err != nil {
		return err
	}
	if _, err := file.WriteString(word + "\n"); err != nil {
		file.Close()
		return err
	}
	return file.Close()
}

// status reads the reconciler's report. A missing file is not an error: it is
// what a router that has never had the tunnel switched on looks like.
func (s *vpnService) status() (vpnStatus, error) {
	raw, err := os.ReadFile(s.statusPath())
	if err != nil {
		if os.IsNotExist(err) {
			return vpnStatus{}, nil
		}
		return vpnStatus{}, err
	}
	var status vpnStatus
	if err := json.Unmarshal(raw, &status); err != nil {
		return vpnStatus{}, err
	}
	return status, nil
}

// settleFor waits until the report agrees with the switch, or the budget runs
// out. Bounded and short: a reconcile that has not finished in this long has
// hit something worth reading the page for rather than waiting on.
func (s *vpnService) settleFor(want bool) {
	deadline := time.Now().Add(s.settle)
	for {
		if status, err := s.status(); err == nil && status.Enabled == want {
			return
		}
		if !time.Now().Before(deadline) {
			return
		}
		time.Sleep(s.poll)
	}
}

type vpnPageData struct {
	Nav navData
	// What the switch says, as a word, so the template can render the right
	// button without a second boolean to keep in step with it.
	Switch string
	Status vpnStatus
	// The switch and the report disagree, which is either a reconcile still in
	// flight or one that failed. Named for what a reader can act on: wait, or
	// go and look at the journal.
	Settling bool
	// The band's colour and its words, resolved here rather than in the
	// template for the reason the uplink band's are: a three-way state written
	// as nested conditionals in HTML is where the fourth case gets lost.
	State     string
	StateText string
	// Where a client points itself: the ephemeral name when there is one, the
	// address when there is not, and empty when the tunnel is off.
	Endpoint string
	// How long ago the report was written, already formatted. Empty when the
	// timestamp could not be read, which the template renders as an em dash
	// rather than as "0s" — the latter would be a claim rather than a gap.
	Reported string
	// Set when the report itself could not be read. Distinct from Status.Note,
	// which is the reconciler telling us something: this one means we cannot
	// say what the reconciler did at all.
	Error string
}

func (s *vpnService) registerRoutes(mux *http.ServeMux) {
	mux.HandleFunc("GET /vpn", s.handlePage)
	mux.HandleFunc("GET /vpn/{$}", s.handlePage)
	mux.HandleFunc("POST /vpn/enable", s.handleSwitch(vpnOn))
	mux.HandleFunc("POST /vpn/disable", s.handleSwitch(vpnOff))
}

func (s *vpnService) page(nav navSource) vpnPageData {
	data := vpnPageData{
		Nav:    nav.data("vpn", true),
		Switch: s.desired(),
	}
	status, err := s.status()
	if err != nil {
		log.Printf("tunnel: read %s: %v", s.statusPath(), err)
		data.Error = "Cannot read what the tunnel service last did, so the state below is the switch alone."
		data.Settling = true
		return data
	}
	data.Status = status
	data.Settling = (data.Switch == vpnOn) != status.Enabled

	if status.Enabled {
		switch {
		case status.FQDN != "":
			data.Endpoint = status.FQDN
		case status.PublicAddress != "":
			data.Endpoint = status.PublicAddress
		}
		if data.Endpoint != "" && status.Port != 0 {
			data.Endpoint += ":" + strconv.Itoa(status.Port)
		}
	}

	if reported, err := time.Parse(time.RFC3339, status.Updated); err == nil {
		data.Reported = formatDuration(time.Since(reported))
	}
	data.State, data.StateText = vpnBandState(data.Switch, data.Settling)
	return data
}

// vpnBandState names the band. "settling" covers both directions on purpose:
// what a reader does about it is the same either way, and the words underneath
// say which way it is going.
func vpnBandState(sw string, settling bool) (string, string) {
	switch {
	case settling && sw == vpnOn:
		return "settling", "switching on"
	case settling:
		return "settling", "switching off"
	case sw == vpnOn:
		return "on", "tunnel is up"
	default:
		return "off", "tunnel is off"
	}
}

func (s *vpnService) handlePage(w http.ResponseWriter, _ *http.Request) {
	s.render(w, s.page(s.nav))
}

func (s *vpnService) render(w http.ResponseWriter, data vpnPageData) {
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	if err := s.tmpl.Execute(w, data); err != nil {
		log.Printf("tunnel: render: %v", err)
	}
}

// handleSwitch flips the switch and waits briefly for the reconciler.
//
// Guarded by the same origin check the peer actions use, and for a stronger
// reason: this one opens a port to the internet. It is the only mutation on
// this listener that a cross-site page could otherwise reach without knowing a
// device address.
func (s *vpnService) handleSwitch(word string) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if !sameOrigin(w, r) {
			return
		}
		if err := s.setDesired(word); err != nil {
			log.Printf("tunnel-action action=%s result=%q", word, err.Error())
			http.Error(w, "cannot write the tunnel switch", http.StatusInternalServerError)
			return
		}
		log.Printf("tunnel-action action=%s result=\"ok\"", word)
		s.settleFor(word == vpnOn)
		http.Redirect(w, r, "/vpn", http.StatusSeeOther)
	}
}
