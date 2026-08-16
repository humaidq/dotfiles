package main

import (
	"bufio"
	"bytes"
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net"
	"net/http"
	"net/http/cookiejar"
	"net/netip"
	neturl "net/url"
	"os"
	"strings"
	"sync"
	"time"
)

// The access point list on the status page: one lamp per AP and the one word
// that says whether to go and look at it.
//
// Deliberately three states and no numbers. The page is read by someone
// standing in a room where the wifi is bad, and what they need from it is which
// box to walk to — a latency figure or a negotiated speed invites reading the
// page instead of fixing the AP. Everything measured here stays in this file
// and comes out as "off", "degraded" or "healthy".
//
// The APs are not on this router. They hang off a switch, so there is no link
// state to read and no PHY to interrogate: everything below is inferred from
// ICMP, which is the only thing a router can ask an unmanaged AP without
// credentials for it.
const (
	// The large probe's payload. Sized so that the time to clock it onto the
	// wire dominates every other term in the round trip: 65000 bytes is 520000
	// bits, which takes 5.2 ms to send at 100 Mbit and 0.52 ms at 1 Gbit.
	//
	// Just under the 65507-byte ceiling an ICMP echo can carry, rather than at
	// it, so that the fragmenting is the kernel's ordinary path rather than its
	// edge case.
	apLargeProbeBytes = 65000

	// How many small probes decide reachability. Five rather than one because a
	// single lost packet on a wifi-adjacent device is normal and should not
	// paint a lamp, and rather than twenty because this runs against every AP
	// on every cycle.
	apSmallProbes = 5

	apSmallTimeout = 1 * time.Second
	// Longer than the small one by more than the ratio of their sizes: the
	// large probe is ~45 fragments each way, and an AP with a slow CPU takes
	// visibly longer to reassemble them than to bounce a 64-byte packet.
	apLargeTimeout = 3 * time.Second

	apInterval = 60 * time.Second

	// The round trip below which a 65000-byte echo proves the path is faster
	// than 100 Mbit.
	//
	// This is physics rather than a tuned threshold: the payload has to be
	// clocked onto the wire in each direction, so a path with a 100 Mbit link
	// anywhere on it cannot answer in less than 2 x 5.2 = 10.4 ms however fast
	// the AP is. Measured, a gigabit-linked AP answers in about 2 ms and a
	// 100 Mbit one in about 11.6 ms, so the gap either side of this is wide.
	//
	// It only proves things in one direction, which is why sawLarge exists in
	// apState: under the ceiling is proof of a fast link, but over it is not
	// proof of a slow one — reassembling 45 fragments on a weak CPU costs real
	// milliseconds too. See the note on apState.
	apGigabitCeiling = 10 * time.Millisecond
)

// accessPoint is one AP to watch: the label to print, where to reach it, and
// the admin login the reboot button uses.
//
// Username and Password are empty for an AP listed with no credentials, which is
// the whole of the per-AP reboot switch: no login, no button, no route that can
// reach that AP's admin interface. They are per-AP because the APs on one site
// turned out not to share a password, and one of them does not even share a
// firmware — see rebootAccessPoint.
type accessPoint struct {
	Name     string
	Addr     netip.Addr
	Username string
	Password string
}

// canReboot reports whether this AP was listed with a login. Password alone
// decides it: parseAccessPoints only ever sets the two together.
func (p accessPoint) canReboot() bool { return p.Password != "" }

// apReport is what the template renders. State is the lamp class shared with
// the nav strip and the uplink band; StateText is the word beside it.
type apReport struct {
	Name      string
	State     string
	StateText string
	// Whether to draw a reboot button for this AP: it was listed with a login
	// and the monitor has a reboot function wired. Set in reports() rather than
	// carried through a cycle because it does not depend on the probe.
	CanReboot bool
}

// apSample is one cycle's measurement of one AP, before it is turned into a
// state. Kept separate from the verdict so the classification is a pure
// function over it and can be tested without a network.
type apSample struct {
	Sent     int
	Received int
	// The large probe. Large is meaningless unless LargeOK.
	Large   time.Duration
	LargeOK bool
}

// parseAccessPoints reads the AP list: one `name,address` or
// `name,address,username,password` per line, `#` comments and blank lines
// skipped. The two-field form lists an AP with a lamp and no reboot button; the
// four-field form adds the login the button uses.
//
// Malformed input disables the feature rather than being skipped, matching
// parseAnchors. The failure that a skipped line produces here is the worst one
// available: an AP silently missing from the page reads as an AP that is fine,
// and the entire point of the list is to notice the one that is not.
func parseAccessPoints(raw string) ([]accessPoint, error) {
	var points []accessPoint
	seen := map[string]bool{}

	scanner := bufio.NewScanner(strings.NewReader(raw))
	for line := 1; scanner.Scan(); line++ {
		text := strings.TrimSpace(scanner.Text())
		if cut := strings.IndexByte(text, '#'); cut >= 0 {
			text = strings.TrimSpace(text[:cut])
		}
		if text == "" {
			continue
		}

		// Split into up to four fields. A password may not contain a comma, which
		// is the one character the list format spends on separators; nothing else
		// about it is constrained.
		fields := strings.SplitN(text, ",", 4)
		point := accessPoint{Name: strings.TrimSpace(fields[0])}

		switch len(fields) {
		case 2:
			// name,address — a lamp and no button.
		case 4:
			point.Username = strings.TrimSpace(fields[2])
			point.Password = strings.TrimSpace(fields[3])
			if point.Username == "" || point.Password == "" {
				return nil, fmt.Errorf("line %d: username and password must both be set, got %q", line, text)
			}
		default:
			return nil, fmt.Errorf("line %d: want `name,address` or `name,address,username,password`, got %q", line, text)
		}

		address := strings.TrimSpace(fields[1])
		if point.Name == "" || address == "" {
			return nil, fmt.Errorf("line %d: want `name,address`, got %q", line, text)
		}

		addr, err := netip.ParseAddr(address)
		if err != nil {
			return nil, fmt.Errorf("line %d: address %q: %w", line, address, err)
		}
		// IPv4 only, because the probe socket is. An AP named here by its IPv6
		// address would otherwise be a lamp that is permanently off.
		if !addr.Is4() {
			return nil, fmt.Errorf("line %d: address %q is not IPv4", line, address)
		}
		if seen[point.Name] {
			return nil, fmt.Errorf("line %d: duplicate name %q", line, point.Name)
		}
		seen[point.Name] = true

		point.Addr = addr
		points = append(points, point)
	}
	if err := scanner.Err(); err != nil {
		return nil, err
	}
	if len(points) == 0 {
		return nil, fmt.Errorf("no access points listed")
	}
	return points, nil
}

// apState turns one cycle's measurement into a lamp.
//
// sawLarge is whether this AP has ever answered a large probe since the service
// started, and it guards the only inference here that can be wrong in a way the
// reader cannot see. Some devices refuse oversized pings outright; on those,
// judging the link by a probe that was never going to come back would paint a
// permanent amber lamp on an AP that is fine. So the large probe only counts
// against an AP that has previously shown it will answer one.
func apState(sample apSample, sawLarge bool, ceiling time.Duration) (string, string) {
	switch {
	case sample.Received == 0 && !sample.LargeOK:
		return stateDown, "off"
	case sample.Received < sample.Sent:
		// Any loss at all. These are wired devices one hop away on an idle
		// link; a dropped packet here is not the background rate it would be
		// across the internet.
		return stateDegraded, "degraded"
	case sawLarge && !sample.LargeOK:
		// It used to answer large probes and now does not, while still
		// answering small ones. A path that has started dropping fragments is
		// exactly the shape of a link that has gone half-broken rather than
		// down.
		return stateDegraded, "degraded"
	case sample.LargeOK && sample.Large >= ceiling:
		return stateDegraded, "degraded"
	default:
		return stateOK, "healthy"
	}
}

// apProbe measures one AP. Injected so the monitor can be tested without a raw
// socket, which a test process is not given.
type apProbe func(addr netip.Addr) apSample

type apMonitor struct {
	points   []accessPoint
	probe    apProbe
	interval time.Duration
	ceiling  time.Duration
	// Reboots one AP, or nil in a test that does not exercise it. In production
	// it is always set; whether any given AP can actually be rebooted is decided
	// per AP by whether it was listed with a login. Injected so rebootByName can
	// be tested without an access point to talk to.
	reboot func(accessPoint) error

	mu sync.Mutex
	// Last verdict per AP, by name, and whether each has ever answered a large
	// probe. Held rather than recomputed because the page renders from whatever
	// the last cycle found, not from a probe run inside the request.
	last     map[string]apReport
	sawLarge map[string]bool
}

func newAPMonitor(points []accessPoint, probe apProbe) *apMonitor {
	return &apMonitor{
		points:   points,
		probe:    probe,
		interval: apInterval,
		ceiling:  apGigabitCeiling,
		last:     map[string]apReport{},
		sawLarge: map[string]bool{},
	}
}

// reports returns the list in configured order, which is the order someone
// wrote the APs down in and so the order they think about them.
//
// An AP with no verdict yet renders as unknown rather than being omitted: a
// list whose length changes in the first minute after a restart is a list that
// cannot be counted.
func (m *apMonitor) reports() []apReport {
	m.mu.Lock()
	defer m.mu.Unlock()

	out := make([]apReport, 0, len(m.points))
	for _, point := range m.points {
		report, ok := m.last[point.Name]
		if !ok {
			report = apReport{Name: point.Name, State: stateUnknown, StateText: "checking"}
		}
		// Set here rather than at cycle time: it does not depend on the probe, and
		// putting it here means the placeholder before the first cycle carries it
		// too — a button that only appears a minute after a restart would be a
		// button someone waits for and reloads to find.
		report.CanReboot = m.reboot != nil && point.canReboot()
		out = append(out, report)
	}
	return out
}

// cycle probes every AP once and replaces the verdicts.
func (m *apMonitor) cycle() {
	for _, point := range m.points {
		sample := m.probe(point.Addr)

		m.mu.Lock()
		if sample.LargeOK {
			m.sawLarge[point.Name] = true
		}
		state, text := apState(sample, m.sawLarge[point.Name], m.ceiling)
		m.last[point.Name] = apReport{Name: point.Name, State: state, StateText: text}
		m.mu.Unlock()
	}
}

// run probes immediately and then on the interval.
//
// Immediately because the alternative is a page that says "checking" for a
// minute after every restart, and a restart is exactly what someone does before
// reloading this page.
func (m *apMonitor) run() {
	go func() {
		m.cycle()
		ticker := time.NewTicker(m.interval)
		defer ticker.Stop()
		for range ticker.C {
			m.cycle()
		}
	}()
}

// errUnknownAP is what rebootByName returns for a name that is not on the list,
// so the handler can answer 404 for it rather than 502 — the two mean different
// things to whoever clicked, and the list is not something a reader chose.
var errUnknownAP = errors.New("unknown access point")

// errNoRebootCreds is what rebootByName returns for an AP that exists on the
// list but carries no login, which is a 404 to the handler for the same reason:
// no button was ever drawn for it, so a request to reboot it did not come from
// this page.
var errNoRebootCreds = errors.New("access point has no reboot credentials")

// canReboot reports whether the reboot feature is on: a reboot function is
// wired and at least one AP was listed with a login. A nil receiver counts as
// off, so the mux and the template can ask the question without first checking
// whether a monitor exists at all.
func (m *apMonitor) canReboot() bool {
	if m == nil || m.reboot == nil {
		return false
	}
	for _, point := range m.points {
		if point.canReboot() {
			return true
		}
	}
	return false
}

// rebootByName resolves a name to its AP and reboots it.
//
// The name is what the page rendered and posted back, so it is resolved against
// the same list the lamps were drawn from rather than trusting an address off
// the wire — the button can only ever reach an AP that was configured. An AP
// listed without a login answers errNoRebootCreds rather than errUnknownAP: the
// name is real, the button simply was never drawn for it.
func (m *apMonitor) rebootByName(name string) error {
	for _, point := range m.points {
		if point.Name != name {
			continue
		}
		if m.reboot == nil || !point.canReboot() {
			return errNoRebootCreds
		}
		return m.reboot(point)
	}
	return errUnknownAP
}

// handleReboot reboots the AP named in the form and returns to the status page.
//
// Mesh-only: registered by meshMux alone, the same split that keeps every other
// mutation off the LAN listener. Guarded by the same origin check the peer and
// tunnel actions use, because this one power-cycles a device and a cross-site
// page must not be able to trigger it by knowing a name off this repository.
func (m *apMonitor) handleReboot(w http.ResponseWriter, r *http.Request) {
	if !sameOrigin(w, r) {
		return
	}
	name := strings.TrimSpace(r.PostFormValue("ap"))
	err := m.rebootByName(name)
	switch {
	case errors.Is(err, errUnknownAP), errors.Is(err, errNoRebootCreds):
		http.NotFound(w, r)
		return
	case err != nil:
		log.Printf("ap-reboot ap=%q result=%q", name, err.Error())
		// Bad gateway rather than 500: the failure is the AP not answering the
		// login or the reboot, not this service, and the distinction is the
		// first thing worth knowing when the button did nothing.
		http.Error(w, "the access point did not accept the reboot", http.StatusBadGateway)
		return
	}
	log.Printf("ap-reboot ap=%q result=\"ok\"", name)
	http.Redirect(w, r, "/", http.StatusSeeOther)
}

// apCredentials is one AP's admin login.
type apCredentials struct {
	username string
	password string
}

// How long the whole login-then-reboot exchange gets. Generous because a busy
// AP takes a moment to answer the login, and short enough that a button press
// against an AP that is already off returns a failure rather than hanging the
// request.
const apRebootTimeout = 15 * time.Second

// apKind is which of the two firmware families an AP runs. They share a vendor
// and a base64 password scheme and nothing else that matters here: the modern
// one is a JSON API on /goform/modules, the legacy one a form login and a GET
// reboot on a GoAhead server. The two are told apart by the login page the root
// URL redirects to.
type apKind int

const (
	apModern apKind = iota
	apLegacy
)

// rebootAccessPoint logs into one AP and reboots it, picking the protocol from
// what firmware it turns out to be running.
//
// A fresh cookie jar and client per call: the login is repeated every time
// rather than a session cached, which costs one request and removes any
// question of an expired session turning a reboot into a silent no-op. Both
// families also authorise by source address once logged in, so the jar is
// belt-and-braces on the modern one and the mechanism on the legacy one.
func rebootAccessPoint(point accessPoint) error {
	jar, err := cookiejar.New(nil)
	if err != nil {
		return err
	}
	client := &http.Client{Timeout: apRebootTimeout, Jar: jar}
	creds := apCredentials{username: point.Username, password: point.Password}
	base := "http://" + point.Addr.String()

	kind, err := detectAPKind(client, base)
	if err != nil {
		return fmt.Errorf("detect firmware: %w", err)
	}
	switch kind {
	case apLegacy:
		return ipcomRebootLegacy(client, creds, base)
	default:
		return ipcomRebootModern(client, creds, base+"/goform/modules")
	}
}

// detectAPKind asks the root URL which login page it redirects to. The modern
// firmware lands on login.html, the legacy one on login.asp; the client follows
// the redirect, so the final path is the tell. Anything else is treated as
// modern, whose reboot flow reports a clear error if that guess is wrong rather
// than doing something surprising.
func detectAPKind(client *http.Client, base string) (apKind, error) {
	resp, err := client.Get(base + "/")
	if err != nil {
		return apModern, err
	}
	resp.Body.Close()
	if strings.HasSuffix(resp.Request.URL.Path, ".asp") {
		return apLegacy, nil
	}
	return apModern, nil
}

// ipcomRebootModern runs the JSON goform flow: log in, then post sysReboot.
//
// The password is base64, not hashed — that is the AP's scheme, matching the
// Encode() in its own login.js, not a choice made here.
func ipcomRebootModern(client *http.Client, creds apCredentials, url string) error {
	now := time.Now()
	login := map[string]any{
		"sysLogin": map[string]any{
			"username": creds.username,
			"password": base64.StdEncoding.EncodeToString([]byte(creds.password)),
			"logoff":   false,
			"timeZone": 20,
			"time": fmt.Sprintf("%d;%d;%d;%d;%d;%d",
				now.Year(), int(now.Month()), now.Day(), now.Hour(), now.Minute(), now.Second()),
		},
	}
	var loginReply struct {
		SysLogin struct {
			Login bool `json:"Login"`
		} `json:"sysLogin"`
	}
	if err := apPostJSON(client, url, login, &loginReply); err != nil {
		return fmt.Errorf("login: %w", err)
	}
	if !loginReply.SysLogin.Login {
		return fmt.Errorf("login rejected: wrong credentials")
	}

	// The reply is not read: the AP schedules the reboot and answers, then goes
	// down, so anything past the request completing is racing the reboot. A
	// transport error here is still worth reporting — it means the request did
	// not land — but a truncated or missing body is the expected shape of
	// success, not a failure.
	if err := apPostJSON(client, url, map[string]string{"sysReboot": ""}, nil); err != nil {
		return fmt.Errorf("reboot: %w", err)
	}
	return nil
}

// ipcomRebootLegacy runs the older GoAhead flow: a form login to /login/Auth,
// then a GET to /goform/SysToolReboot.
//
// Success on the login is that the redirect does not land back on login.asp —
// the page's own login.js decides the same way, by the response not being the
// login page again. The password is base64 here too, the same Encode().
func ipcomRebootLegacy(client *http.Client, creds apCredentials, base string) error {
	now := time.Now()
	form := neturl.Values{}
	form.Set("usertype", "admin")
	form.Set("username", creds.username)
	form.Set("password", base64.StdEncoding.EncodeToString([]byte(creds.password)))
	form.Set("time", fmt.Sprintf("%d;%d;%d;%d;%d;%d",
		now.Year(), int(now.Month()), now.Day(), now.Hour(), now.Minute(), now.Second()))

	resp, err := client.PostForm(base+"/login/Auth", form)
	if err != nil {
		return fmt.Errorf("login: %w", err)
	}
	resp.Body.Close()
	// The client followed the redirect: a good login ends on index.asp, a bad
	// one back on login.asp. Match on the failure so anything unexpected is not
	// silently taken for success.
	if strings.Contains(resp.Request.URL.Path, "login.asp") {
		return fmt.Errorf("login rejected: wrong credentials")
	}

	// A cache-buster like the page's Math.random(); the value is irrelevant. The
	// reply is not read, for the same reason as the modern reboot above.
	rebootResp, err := client.Get(base + "/goform/SysToolReboot?r=1")
	if err != nil {
		return fmt.Errorf("reboot: %w", err)
	}
	rebootResp.Body.Close()
	if rebootResp.StatusCode != http.StatusOK {
		return fmt.Errorf("reboot: status %s", rebootResp.Status)
	}
	return nil
}

// apPostJSON posts one goform request and, when out is non-nil, decodes the
// reply into it.
func apPostJSON(client *http.Client, url string, body, out any) error {
	buf, err := json.Marshal(body)
	if err != nil {
		return err
	}
	req, err := http.NewRequest(http.MethodPost, url, bytes.NewReader(buf))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Accept", "application/json")

	resp, err := client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("status %s", resp.Status)
	}
	if out == nil {
		return nil
	}
	return json.NewDecoder(resp.Body).Decode(out)
}

// icmpProber owns the socket the probes go out of.
//
// One socket, one AP at a time, sequentially. The uplink prober is built the
// other way — many targets in flight, replies dispatched by identifier —
// because it is sampling continuously for a history. This one runs a handful of
// probes a minute and is read as a lamp, so the simpler shape is worth more
// than the concurrency.
type icmpProber struct {
	conn net.PacketConn
	id   uint16
	seq  uint16
}

// newICMPProber opens the raw socket. Same socket type and same reason as the
// uplink prober's: the unprivileged datagram kind needs a group that
// DynamicUser does not know at build time.
func newICMPProber() (*icmpProber, error) {
	conn, err := net.ListenPacket("ip4:icmp", "0.0.0.0")
	if err != nil {
		return nil, fmt.Errorf("open icmp socket: %w", err)
	}
	// Complemented rather than shifted, so these identifiers do not land in the
	// range the uplink prober derives from the same pid. A collision would not
	// corrupt either side — both check the sequence, and this one checks the
	// source address as well — but two probers quietly discarding each other's
	// replies is a thing worth not having to debug.
	return &icmpProber{conn: conn, id: ^uint16(os.Getpid())}, nil
}

func (p *icmpProber) close() error { return p.conn.Close() }

// sample runs one AP's probes: the small ones for reachability, then one large
// one for the link.
func (p *icmpProber) sample(addr netip.Addr) apSample {
	sample := apSample{Sent: apSmallProbes}
	for range apSmallProbes {
		if _, ok := p.exchange(addr, 0, apSmallTimeout); ok {
			sample.Received++
		}
	}
	// Skipped when nothing came back at all. The AP is off; sending 65 kB at it
	// and waiting three seconds for the reply establishes nothing that the five
	// lost probes have not already established.
	if sample.Received > 0 {
		sample.Large, sample.LargeOK = p.exchange(addr, apLargeProbeBytes, apLargeTimeout)
	}
	return sample
}

// exchange sends one echo and waits for its reply.
//
// Replies are matched on identifier, sequence and source address together.
// Every raw ICMP socket on the host sees every inbound ICMP packet, so this
// socket also gets the uplink prober's replies and anything else on the box is
// pinging — all of which have to be read past rather than counted.
func (p *icmpProber) exchange(addr netip.Addr, payload int, timeout time.Duration) (time.Duration, bool) {
	p.seq++
	seq := p.seq

	packet := echoRequestSized(p.id, seq, payload)
	sentAt := time.Now()
	if _, err := p.conn.WriteTo(packet, &net.IPAddr{IP: addr.AsSlice()}); err != nil {
		// No route while a link is down is the ordinary case here, and it is
		// the same answer as a lost probe: nothing came back.
		return 0, false
	}

	deadline := sentAt.Add(timeout)
	// Large enough for a reassembled maximum-size datagram: a short read would
	// truncate the reply to the large probe and lose the one measurement it
	// exists to take.
	buffer := make([]byte, 65535)
	for {
		if err := p.conn.SetReadDeadline(deadline); err != nil {
			return 0, false
		}
		n, from, err := p.conn.ReadFrom(buffer)
		if err != nil {
			return 0, false
		}
		if !sameProbeSource(from, addr) {
			continue
		}
		replyID, replySeq, ok := parseEchoReply(buffer[:n])
		if !ok || replyID != p.id || replySeq != seq {
			continue
		}
		return time.Since(sentAt), true
	}
}

// sameProbeSource reports whether a reply came from the address it was sent to.
func sameProbeSource(from net.Addr, want netip.Addr) bool {
	ipAddr, ok := from.(*net.IPAddr)
	if !ok || ipAddr.IP == nil {
		return false
	}
	got, ok := netip.AddrFromSlice(ipAddr.IP)
	if !ok {
		return false
	}
	return got.Unmap() == want.Unmap()
}

// echoRequestSized builds an ICMP echo request with a payload of the given
// length. See echoRequest, which is this with the 56 bytes ping(8) uses.
func echoRequestSized(id, seq uint16, payloadLen int) []byte {
	packet := make([]byte, 8+payloadLen)
	packet[0] = 8 // echo request
	packet[1] = 0 // code
	binary.BigEndian.PutUint16(packet[4:], id)
	binary.BigEndian.PutUint16(packet[6:], seq)
	for i := range payloadLen {
		packet[8+i] = byte(i)
	}
	binary.BigEndian.PutUint16(packet[2:], internetChecksum(packet))
	return packet
}

// startAccessPoints wires the list up if one is configured.
//
// Opt-in on the file, the same idiom as ROUTER_CAPTURE_DIR and
// ROUTER_UPLINK_DB: unset means no socket, no goroutine and no section on the
// page. Every failure is logged and returns nil rather than being fatal —
// losing the status page because a socket could not be opened would turn a
// missing capability into an outage.
func startAccessPoints() *apMonitor {
	path := strings.TrimSpace(os.Getenv("ROUTER_AP_FILE"))
	if path == "" {
		return nil
	}
	raw, err := os.ReadFile(path)
	if err != nil {
		log.Printf("access point list disabled: read %s: %v", path, err)
		return nil
	}
	points, err := parseAccessPoints(string(raw))
	if err != nil {
		log.Printf("access point list disabled: %s: %v", path, err)
		return nil
	}
	prober, err := newICMPProber()
	if err != nil {
		log.Printf("access point list disabled: %v", err)
		return nil
	}

	monitor := newAPMonitor(points, prober.sample)
	// Always wired: whether any given AP can be rebooted is decided per AP by
	// whether its line carried a login, not by a separate switch. The list is
	// the switch now — an AP written as `name,address` gets a lamp and no button.
	monitor.reboot = rebootAccessPoint
	monitor.run()

	rebootable := 0
	for _, point := range points {
		if point.canReboot() {
			rebootable++
		}
	}
	log.Printf("watching %d access points from %s (%d with reboot logins)", len(points), path, rebootable)
	return monitor
}
