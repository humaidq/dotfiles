package main

import (
	"encoding/binary"
	"fmt"
	"log"
	"net"
	"net/netip"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
)

// Uplink quality probing.
//
// node_exporter answers "how much is the line carrying". It cannot answer "is
// the line any good", which is a different question and the one that matters
// when a video call breaks while the graphs look idle. This probes it
// directly: a one-per-second ICMP echo to a small set of fixed targets,
// aggregated per minute, kept for 90 days.
//
// What each target is for, and — as important — what each is not for:
//
//   - The PPP peer is the far end of the PPPoE session. It is the only target
//     that distinguishes "the line is up" from "the line is up and the
//     internet is reachable", so it is the liveness check. Its *latency* is
//     not trustworthy. Measured on this network, the peer answered with mdev
//     29.8 ms and a 167 ms maximum in the same seconds that 1.1.1.1 and
//     8.8.8.8 — which cross that identical line and then keep going — returned
//     mdev 0.48 ms and 0.38 ms. Jitter present only on packets addressed to
//     the access node itself, and absent on packets forwarded through it, is
//     the access node's control plane deprioritising ICMP to its own address.
//     So the peer contributes reachability and nothing else; the core and
//     transit anchors carry the quality signal.
//
//   - Core anchors are in-country. On this ISP the public resolvers answer
//     from anycast nodes inside the country at around 5 ms, so they measure
//     the ISP's own network and stop there.
//
//   - A transit anchor is a unicast host abroad. It is the only leg that sees
//     international peering, which is the part of this ISP that actually
//     degrades. It has to be unicast — another anycast address would silently
//     be answered by a nearer node and quietly become a second core anchor.
const (
	// One probe per second per target. Fast enough to see a loss episode
	// inside a minute and to keep the forwarding path warm (see warmupProbes),
	// slow enough that no reasonable target will rate-limit it.
	probeInterval = time.Second
	// How long a reply is still counted. Longer than the interval on purpose:
	// a 1.5 s reply on a congested line is a terrible result but it is not a
	// lost packet, and calling it loss would overstate the fault.
	probeTimeout = 2 * time.Second
	// How often the pending table is swept for probes that have timed out.
	sweepInterval = 250 * time.Millisecond
	// How long after a minute ends before its bucket is written. Covers the
	// probe sent in the last second of the minute and answered in the first of
	// the next.
	flushGrace = probeTimeout + 3*time.Second
	// How often buckets are checked for being old enough to write.
	flushInterval = 10 * time.Second
	// Probes discarded after the path to a target changes.
	//
	// The first packet to a target the access node has no state for takes the
	// slow path: measured here at 312 ms, with the very next probe at 1.47 ms.
	// That is an artifact of building forwarding state, not a property of the
	// uplink, and at one probe per second it happens exactly once and then
	// never again while probing continues. Recording it would put a 300 ms
	// spike in the history after every reconnect — including the 05:00 redial,
	// which would otherwise appear as a nightly latency event.
	warmupProbes = 3
	// How often the PPP interface is re-read for its addresses.
	pppPollInterval = 5 * time.Second
	// How often expired minutes are deleted.
	pruneInterval = time.Hour
	// How long after this process starts an outage is treated as its own doing
	// rather than the line's.
	//
	// A `nixos-rebuild switch` restarts this service, and restarts networkd,
	// which takes pppd down with it. The session is gone for a few seconds and
	// the anchors record loss the whole time — all of it true, none of it the
	// ISP's, and all of it landing in the event log as an outage and, if the
	// redial is slow, a degradation episode. An event log that fires on every
	// deploy is one nobody reads, which costs more than these events are worth.
	//
	// A minute, because that is all the redial takes and the episode machinery
	// supplies its own hysteresis on top: episodeOpenAfter already demands
	// three consecutive bad minutes, so with the first of them graced a line
	// has to stay bad for four minutes from start before an episode opens.
	// Only the PPP event fires on sight, and one minute covers the reconnect
	// that produces it several times over.
	//
	// The price is explicit: an outage that is genuinely the line's and happens
	// to coincide with a rebuild is recorded up to a minute late. The minute
	// rows are written throughout regardless, so the history and the loss
	// meters still show the gap — only the event is withheld.
	startupGrace = time.Minute
	// How long a full-reboot marker may suppress events before it is treated
	// as stale. Comfortably longer than the sequence takes — the one measured
	// run was under three minutes — and short enough that a marker orphaned by
	// a crash costs one quiet window rather than a silent event log.
	maintenanceWindow = 30 * time.Minute
)

// Anchor roles.
const (
	// The PPP peer: discovered, not configured, and reachability-only.
	rolePeer = "peer"
	// In-country. Carries the primary latency and loss signal.
	roleCore = "core"
	// Abroad and unicast. Carries the international transit signal.
	roleTransit = "transit"
)

// The name given to the automatically discovered PPP peer target.
const peerTargetName = "ppp-peer"

// Which CAKE tin a probe is sent into, and the suffix the paired target's name
// gets.
//
// Probes default to best effort because that is where essentially all real
// traffic sits, and a measurement taken in a small protected tin would report
// a healthy line through exactly the congested evening this exists to catch.
//
// The paired Voice probe is not a better measurement, it is a second one: the
// *gap* between the two is the reading.
//
//	both clean                  the line is fine
//	best effort bad, voice flat prioritisation is working — bulk is contended
//	both bad                    the bottleneck is off-box, upstream of the shaper
//
// That last row is the one nothing else here can produce. The shaper cannot
// drain a queue that formed on the far side of the line, so Voice degrading
// too is positive evidence the fault is the ISP's rather than the household's.
//
// The honest limit: this is an *upload* differential. The tin is chosen by the
// DSCP this router writes on egress, and the return packets come back however
// the ISP chose to send them — the WAN bleach rule in default.nix drops their
// codepoint on arrival, and the download shaper never sees these replies
// anyway because they terminate here rather than crossing lan0.
const (
	tinBestEffort = "be"
	tinVoice      = "voice"
	voiceSuffix   = "-voice"
	// DSCP EF in the top six bits of the TOS byte. CAKE's diffserv4 classifier
	// reads this straight off the packet on ppp0 egress; no firewall rule is
	// involved, because the qos-mark chain keys on iifname and ether saddr and
	// so never sees router-originated traffic.
	voiceTOS = 46 << 2
)

// One thing being probed.
type anchor struct {
	Name string
	Role string
	// Empty for the peer anchor, whose address is read from the PPP interface
	// and re-read on every reconnect.
	Address netip.Addr
	// Which tin this target's probes are marked into.
	Tin string
	// Whether a Voice-marked twin of this anchor should also be probed.
	PairVoice bool
}

// parseAnchors reads the ROUTER_UPLINK_ANCHORS specification: comma-separated
// name|address|role|pair quads, where pair is "voice" or empty.
//
// A malformed entry is fatal to the anchor list rather than skipped. These
// come from a NixOS option that has already type-checked them, so anything
// wrong here means the two representations have drifted, and a probe silently
// not running is exactly the failure this whole feature exists to notice.
func parseAnchors(spec string) ([]anchor, error) {
	var out []anchor
	for _, entry := range strings.Split(spec, ",") {
		entry = strings.TrimSpace(entry)
		if entry == "" {
			continue
		}

		fields := strings.Split(entry, "|")
		if len(fields) != 4 {
			return nil, fmt.Errorf("anchor %q: want name|address|role|pair", entry)
		}

		name := strings.TrimSpace(fields[0])
		if name == "" {
			return nil, fmt.Errorf("anchor %q: empty name", entry)
		}
		if name == peerTargetName {
			return nil, fmt.Errorf("anchor %q: %s is reserved for the discovered PPP peer", entry, peerTargetName)
		}
		// The paired target is named by suffixing this one, so an anchor
		// already carrying the suffix would collide with a twin.
		if strings.HasSuffix(name, voiceSuffix) {
			return nil, fmt.Errorf("anchor %q: %q is reserved for paired Voice targets", entry, voiceSuffix)
		}

		addr, err := netip.ParseAddr(strings.TrimSpace(fields[1]))
		if err != nil {
			return nil, fmt.Errorf("anchor %q: %w", entry, err)
		}
		if !addr.Is4() {
			return nil, fmt.Errorf("anchor %q: only IPv4 anchors are probed", entry)
		}

		role := strings.TrimSpace(fields[2])
		if role != roleCore && role != roleTransit {
			return nil, fmt.Errorf("anchor %q: role must be %s or %s", entry, roleCore, roleTransit)
		}

		pair := strings.TrimSpace(fields[3])
		if pair != "" && pair != tinVoice {
			return nil, fmt.Errorf("anchor %q: pair must be empty or %q", entry, tinVoice)
		}

		out = append(out, anchor{
			Name:      name,
			Role:      role,
			Address:   addr,
			Tin:       tinBestEffort,
			PairVoice: pair == tinVoice,
		})
	}
	return out, nil
}

// A probe that has been sent and not yet answered.
type pendingProbe struct {
	sentAt time.Time
	down   uint64
	up     uint64
}

// One minute of samples for one target, before it is written.
type minuteBucket struct {
	// Successful RTTs in milliseconds, in the order measured, because jitter
	// is defined on that order.
	rtts     []float64
	sent     int
	received int
	downPeak uint64
	upPeak   uint64
}

// The live state of one target.
type uplinkTarget struct {
	anchor anchor
	// ICMP identifier, unique per target within this process, which is how a
	// reply on the shared socket is attributed.
	id uint16

	mu      sync.Mutex
	addr    netip.Addr
	seq     uint16
	pending map[uint16]pendingProbe
	buckets map[int64]*minuteBucket
	warmup  int

	lastAt  time.Time
	lastOK  bool
	lastRTT time.Duration
	lostRun int

	// Episode state, for the event log. Only flushLoop touches these, except
	// episodeOpen, which the page and /metrics read — hence setEpisodeOpen
	// rather than a plain assignment.
	badRun      int
	goodRun     int
	episodeID   int64
	episodeOpen bool
	baseline    float64

	// Monotonic since process start, for /metrics.
	sentTotal     uint64
	receivedTotal uint64
}

// setAddress points a target at an address, discarding any in-flight probes to
// the previous one and arming the warmup discard.
func (t *uplinkTarget) setAddress(addr netip.Addr) bool {
	t.mu.Lock()
	defer t.mu.Unlock()

	if t.addr == addr {
		return false
	}
	t.addr = addr
	t.pending = map[uint16]pendingProbe{}
	t.warmup = warmupProbes
	return true
}

func (t *uplinkTarget) address() netip.Addr {
	t.mu.Lock()
	defer t.mu.Unlock()
	return t.addr
}

// setEpisodeOpen records whether this target is inside a degradation episode.
// Written by the flush loop and read by whichever goroutine is serving the
// page or a scrape, so it takes the lock the rest of the shared state does.
func (t *uplinkTarget) setEpisodeOpen(open bool) {
	t.mu.Lock()
	defer t.mu.Unlock()
	t.episodeOpen = open
}

// record files one result into its minute bucket.
//
// The bucket is keyed on when the probe was *sent*, not when it was answered
// or timed out, so a probe sent at 11:59:59 and lost at 12:00:01 counts
// against the minute whose line quality it was measuring.
func (t *uplinkTarget) record(sentAt time.Time, ok bool, rtt time.Duration, down, up uint64) {
	t.mu.Lock()
	defer t.mu.Unlock()

	if t.warmup > 0 {
		t.warmup--
		return
	}

	t.lastAt = sentAt
	t.lastOK = ok
	if ok {
		t.lastRTT = rtt
		t.lostRun = 0
		t.receivedTotal++
	} else {
		t.lostRun++
	}
	t.sentTotal++

	minute := sentAt.Truncate(time.Minute).Unix()
	bucket := t.buckets[minute]
	if bucket == nil {
		bucket = &minuteBucket{}
		t.buckets[minute] = bucket
	}

	bucket.sent++
	if ok {
		bucket.received++
		bucket.rtts = append(bucket.rtts, float64(rtt)/float64(time.Millisecond))
	}
	if down > bucket.downPeak {
		bucket.downPeak = down
	}
	if up > bucket.upPeak {
		bucket.upPeak = up
	}
}

// takeReady removes and returns every bucket old enough to be complete.
func (t *uplinkTarget) takeReady(now time.Time) []minuteRow {
	t.mu.Lock()
	defer t.mu.Unlock()

	cutoff := now.Add(-flushGrace).Truncate(time.Minute).Unix()

	var out []minuteRow
	for minute, bucket := range t.buckets {
		if minute >= cutoff {
			continue
		}
		delete(t.buckets, minute)
		if bucket.sent == 0 {
			continue
		}

		row := minuteRow{
			TS:       time.Unix(minute, 0),
			Target:   t.anchor.Name,
			Role:     t.anchor.Role,
			Address:  t.addr.String(),
			Sent:     bucket.sent,
			Received: bucket.received,
			Jitter:   meanAbsoluteDifference(bucket.rtts),
			DownPeak: bucket.downPeak,
			UpPeak:   bucket.upPeak,
		}
		if len(bucket.rtts) > 0 {
			// percentile sorts in place, so jitter above is computed first and
			// the min/max are read from the sorted slice afterwards.
			row.RTTP50 = percentile(bucket.rtts, 0.50)
			row.RTTP95 = percentile(bucket.rtts, 0.95)
			row.RTTMin = bucket.rtts[0]
			row.RTTMax = bucket.rtts[len(bucket.rtts)-1]
		}
		out = append(out, row)
	}
	return out
}

// snapshot is what the status page and /metrics read: the live view, which is
// fresher than the store by up to a minute.
type targetSnapshot struct {
	Name          string
	Role          string
	Tin           string
	Address       string
	LastAt        time.Time
	LastOK        bool
	LastRTT       time.Duration
	LostRun       int
	SentTotal     uint64
	ReceivedTotal uint64
	Degraded      bool
}

func (t *uplinkTarget) snapshot() targetSnapshot {
	t.mu.Lock()
	defer t.mu.Unlock()

	return targetSnapshot{
		Name:          t.anchor.Name,
		Role:          t.anchor.Role,
		Tin:           t.anchor.Tin,
		Address:       t.addr.String(),
		LastAt:        t.lastAt,
		LastOK:        t.lastOK,
		LastRTT:       t.lastRTT,
		LostRun:       t.lostRun,
		SentTotal:     t.sentTotal,
		ReceivedTotal: t.receivedTotal,
		Degraded:      t.episodeOpen,
	}
}

// The prober itself: one ICMP socket, one goroutine per target, and the
// aggregation and bookkeeping loops.
type uplinkProber struct {
	store *uplinkStore
	// The best-effort socket, and the only one read from: a raw ICMP socket
	// receives every ICMP packet on the host regardless of which socket sent
	// the request, so a second reader would only ever see replies the first
	// had already claimed.
	conn net.PacketConn
	// Send-only, with IP_TOS set to EF. Nil when no anchor asked for a pair.
	voiceConn net.PacketConn
	pppIface  string
	// Marker written by the full-reboot sequence; while it is present and
	// fresh, events this router causes on purpose are not recorded. Empty on a
	// router without the feature, which makes inMaintenance always false.
	maintenancePath string
	retention       time.Duration
	load            *loadSampler

	targets []*uplinkTarget
	byID    map[uint16]*uplinkTarget
	peer    *uplinkTarget

	// When this process started probing, for the startup grace. Zero means no
	// grace, which is what tests that build a prober by hand want.
	startedAt time.Time

	mu       sync.Mutex
	pppLocal netip.Addr
	pppPeer  netip.Addr
	pppEvent int64
	pppDown  bool
}

// inStartupGrace reports whether t falls inside the window after start during
// which an outage is assumed to be this service's own restart.
func (p *uplinkProber) inStartupGrace(t time.Time) bool {
	return !p.startedAt.IsZero() && t.Before(p.startedAt.Add(startupGrace))
}

// inMaintenance reports whether a deliberate whole-estate reboot is running.
//
// The same argument as the startup grace, for an outage this router causes on
// purpose rather than suffers. The first thing a full reboot does is restart
// the fibre terminal, which takes the PPP session down for a minute or so
// while this process is still up and watching — so without this the button
// records a session drop every time it is pressed, and "drops in the last 24
// hours" stops meaning "times the line failed".
//
// The events are suppressed, not the measurements. Minute rows are still
// written throughout, so the loss and the gap appear in the history and on the
// graphs exactly as they happened; it is only the "something is wrong" claim
// that is withheld, because nothing is.
//
// Bounded by the file's own age rather than trusting it to be removed. The
// sequence deletes it when it finishes and when it aborts, but it also reboots
// the machine in the middle of itself, and a marker left behind by a crash
// must not silence this router's event log forever.
func (p *uplinkProber) inMaintenance(t time.Time) bool {
	if p.maintenancePath == "" {
		return false
	}
	info, err := os.Stat(p.maintenancePath)
	if err != nil {
		return false
	}
	return t.Before(info.ModTime().Add(maintenanceWindow))
}

// newUplinkProber opens the raw socket and builds the target set. The PPP peer
// target is always present and is not configurable: it is the liveness check,
// and a router that could be configured without one would have no way to tell
// "the line is down" from "the internet is unreachable".
func newUplinkProber(store *uplinkStore, pppIface, maintenancePath string, anchors []anchor, retention time.Duration) (*uplinkProber, error) {
	// A raw ICMP socket rather than the unprivileged datagram kind: the
	// datagram sockets need net.ipv4.ping_group_range to include this
	// service's group, and under DynamicUser the group is allocated at start
	// and is not known at build time. CAP_NET_RAW is already in the unit's
	// ambient set for tcpdump.
	conn, err := net.ListenPacket("ip4:icmp", "0.0.0.0")
	if err != nil {
		return nil, fmt.Errorf("open icmp socket: %w", err)
	}

	prober := &uplinkProber{
		store:           store,
		conn:            conn,
		pppIface:        pppIface,
		maintenancePath: strings.TrimSpace(maintenancePath),
		retention:       retention,
		load:            newLoadSampler(pppIface),
		byID:            map[uint16]*uplinkTarget{},
		startedAt:       time.Now(),
	}

	all := expandAnchors(anchors)

	if prober.needsVoice(all) {
		voiceConn, err := net.ListenPacket("ip4:icmp", "0.0.0.0")
		if err != nil {
			conn.Close()
			return nil, fmt.Errorf("open voice icmp socket: %w", err)
		}
		if err := setTOS(voiceConn, voiceTOS); err != nil {
			conn.Close()
			voiceConn.Close()
			// Fatal rather than degrading to an unmarked probe: a Voice target
			// silently sending best-effort packets would render as two
			// identical rows whose agreement is the whole reading, and a
			// differential that cannot differ is worse than no differential.
			return nil, fmt.Errorf("mark voice socket: %w", err)
		}
		prober.voiceConn = voiceConn
	}

	for index, a := range all {
		target := &uplinkTarget{
			anchor:  a,
			id:      uint16(os.Getpid()&0x7fff)<<1 ^ uint16(index+1),
			addr:    a.Address,
			pending: map[uint16]pendingProbe{},
			buckets: map[int64]*minuteBucket{},
			warmup:  warmupProbes,
		}
		if _, clash := prober.byID[target.id]; clash {
			prober.closeSockets()
			return nil, fmt.Errorf("anchor %q: duplicate ICMP id", a.Name)
		}
		prober.byID[target.id] = target
		prober.targets = append(prober.targets, target)
		if a.Role == rolePeer {
			prober.peer = target
		}
	}

	prober.resumeOpenEvents()

	return prober, nil
}

// resumeOpenEvents adopts anything that was still open when this process last
// stopped, so a restart continues an event rather than abandoning it.
//
// Without this a restart mid-episode loses the row id, leaves the row open
// forever, and three bad minutes later opens a second one for the same anchor:
// the event log grows one permanently "ongoing" episode per deploy, all
// describing the same degradation, and none of them can ever close because
// nothing holds their ids any more. openEvent existed for exactly this from
// the start; nothing outside the tests ever called it.
//
// The hysteresis is deliberately not restored alongside the id. goodRun stays
// at zero, so a resumed episode needs its full episodeCloseAfter of good
// minutes before it closes, which is correct: this process has not yet seen a
// single good minute, whatever the last one saw.
func (p *uplinkProber) resumeOpenEvents() {
	configured := map[string]bool{}
	for _, target := range p.targets {
		configured[target.anchor.Name] = true
	}

	// An anchor removed from the configuration while one of its episodes was
	// open would otherwise leave that row open forever: nothing probes the
	// target any more, so nothing can ever record the good minutes that would
	// close it. That is the same permanently-ongoing row this function exists
	// to prevent, arriving by a different route.
	//
	// Closed at now rather than at some earlier guess. The honest statement is
	// that the episode ran until measurement stopped; when it actually ended,
	// if it ended, is not something this router observed.
	if open, err := p.store.openTargets(eventDegraded); err != nil {
		log.Printf("uplink: %v", err)
	} else {
		for _, target := range open {
			if configured[target] {
				continue
			}
			if err := p.store.closeOpenEvents(eventDegraded, target, time.Now()); err != nil {
				log.Printf("uplink: %v", err)
				continue
			}
			log.Printf("uplink: closing open episode for %s, no longer a configured anchor", target)
		}
	}

	for _, target := range p.targets {
		if target.anchor.Role == rolePeer {
			continue
		}
		event, found, err := p.store.openEvent(eventDegraded, target.anchor.Name)
		if err != nil {
			log.Printf("uplink: resume episode for %s: %v", target.anchor.Name, err)
			continue
		}
		if !found {
			continue
		}
		target.episodeID = event.ID
		target.setEpisodeOpen(true)
		log.Printf("uplink: resuming episode for %s, open since %s",
			target.anchor.Name, event.TS.Format(time.RFC3339))
	}

	// The same for a session that was down across the restart, so the recovery
	// closes the original row instead of leaving it open and silently starting
	// a second one on the next drop.
	if p.pppIface == "" {
		return
	}
	if event, found, err := p.store.openEvent(eventPPPDown, p.pppIface); err != nil {
		log.Printf("uplink: resume ppp_down: %v", err)
	} else if found {
		p.pppEvent = event.ID
		p.pppDown = true
		log.Printf("uplink: resuming ppp_down for %s, open since %s",
			p.pppIface, event.TS.Format(time.RFC3339))
	}
}

// expandAnchors turns the configured list into the actual target list: the
// always-present PPP peer, each anchor, and a Voice-marked twin for each
// anchor that asked for one.
//
// The peer is always best effort. It is a liveness check, and marking a
// liveness check for priority would only make it answer sooner while saying
// nothing more about the line.
//
// A twin immediately follows its own anchor rather than being appended at the
// end, so the page renders each pair adjacently — the two rows are only
// meaningful read against each other.
func expandAnchors(anchors []anchor) []anchor {
	all := []anchor{{Name: peerTargetName, Role: rolePeer, Tin: tinBestEffort}}
	for _, a := range anchors {
		if a.Tin == "" {
			a.Tin = tinBestEffort
		}
		all = append(all, a)
		if !a.PairVoice {
			continue
		}

		twin := a
		twin.Name = a.Name + voiceSuffix
		twin.Tin = tinVoice
		twin.PairVoice = false
		all = append(all, twin)
	}
	return all
}

func (p *uplinkProber) needsVoice(anchors []anchor) bool {
	for _, a := range anchors {
		if a.Tin == tinVoice {
			return true
		}
	}
	return false
}

func (p *uplinkProber) closeSockets() {
	if p.conn != nil {
		p.conn.Close()
	}
	if p.voiceConn != nil {
		p.voiceConn.Close()
	}
}

// socketFor picks the socket whose DSCP puts a probe in the target's tin.
func (p *uplinkProber) socketFor(target *uplinkTarget) net.PacketConn {
	if target.anchor.Tin == tinVoice && p.voiceConn != nil {
		return p.voiceConn
	}
	return p.conn
}

// setTOS writes the DSCP every packet from a socket will carry.
//
// Set once on the socket rather than per packet, because the alternative is a
// control message on every send and the value never changes for the life of
// the process.
func setTOS(conn net.PacketConn, tos int) error {
	syscallConn, ok := conn.(syscall.Conn)
	if !ok {
		return fmt.Errorf("connection of type %T exposes no file descriptor", conn)
	}
	raw, err := syscallConn.SyscallConn()
	if err != nil {
		return err
	}

	var setErr error
	if err := raw.Control(func(fd uintptr) {
		setErr = syscall.SetsockoptInt(int(fd), syscall.IPPROTO_IP, syscall.IP_TOS, tos)
	}); err != nil {
		return err
	}
	return setErr
}

// run starts every loop and blocks until the socket is closed.
func (p *uplinkProber) run() {
	go p.load.run()
	go p.readReplies()
	go p.sweepLoop()
	go p.flushLoop()
	go p.watchPPP()
	go p.pruneLoop()

	for _, target := range p.targets {
		go p.probeLoop(target)
	}
}

// probeLoop sends one echo per interval to one target.
func (p *uplinkProber) probeLoop(target *uplinkTarget) {
	ticker := time.NewTicker(probeInterval)
	defer ticker.Stop()

	for range ticker.C {
		addr := target.address()
		if !addr.IsValid() {
			// The peer target before the first successful discovery, or after
			// the session dropped. Not an error and not loss: there is nothing
			// to measure the line against yet.
			continue
		}
		if err := p.sendProbe(target, addr); err != nil {
			// A send failure is a local condition — no route while the session
			// is down is the common one — and is recorded as loss so that the
			// history shows the gap rather than a suspiciously clean minute.
			down, up := p.load.rates()
			target.record(time.Now(), false, 0, down, up)
		}
	}
}

func (p *uplinkProber) sendProbe(target *uplinkTarget, addr netip.Addr) error {
	target.mu.Lock()
	target.seq++
	seq := target.seq
	down, up := p.load.rates()
	target.pending[seq] = pendingProbe{sentAt: time.Now(), down: down, up: up}
	target.mu.Unlock()

	packet := echoRequest(target.id, seq)
	_, err := p.socketFor(target).WriteTo(packet, &net.IPAddr{IP: addr.AsSlice()})
	if err != nil {
		target.mu.Lock()
		delete(target.pending, seq)
		target.mu.Unlock()
		return err
	}
	return nil
}

// readReplies dispatches echo replies to the target that sent them.
func (p *uplinkProber) readReplies() {
	buffer := make([]byte, 1500)
	for {
		n, _, err := p.conn.ReadFrom(buffer)
		if err != nil {
			log.Printf("uplink: icmp read: %v", err)
			return
		}

		id, seq, ok := parseEchoReply(buffer[:n])
		if !ok {
			continue
		}
		target := p.byID[id]
		if target == nil {
			// Another process on this host is pinging. Not ours.
			continue
		}

		now := time.Now()
		target.mu.Lock()
		probe, found := target.pending[seq]
		if found {
			delete(target.pending, seq)
		}
		target.mu.Unlock()
		if !found {
			// A reply that arrived after its timeout. The loss is already
			// recorded; counting it now would make received exceed sent.
			continue
		}

		target.record(probe.sentAt, true, now.Sub(probe.sentAt), probe.down, probe.up)
	}
}

// sweepLoop turns unanswered probes into loss once they are past the timeout.
func (p *uplinkProber) sweepLoop() {
	ticker := time.NewTicker(sweepInterval)
	defer ticker.Stop()

	for now := range ticker.C {
		for _, target := range p.targets {
			var expired []pendingProbe

			target.mu.Lock()
			for seq, probe := range target.pending {
				if now.Sub(probe.sentAt) > probeTimeout {
					expired = append(expired, probe)
					delete(target.pending, seq)
				}
			}
			target.mu.Unlock()

			for _, probe := range expired {
				target.record(probe.sentAt, false, 0, probe.down, probe.up)
			}
		}
	}
}

// flushLoop writes completed minutes and updates the episode state machine.
func (p *uplinkProber) flushLoop() {
	ticker := time.NewTicker(flushInterval)
	defer ticker.Stop()

	for now := range ticker.C {
		for _, target := range p.targets {
			for _, row := range target.takeReady(now) {
				if err := p.store.writeMinute(row); err != nil {
					log.Printf("uplink: %v", err)
					continue
				}
				p.updateEpisode(target, row)
			}
		}
	}
}

// How an episode is opened and closed.
const (
	// Loss above this in a minute makes it a bad minute.
	episodeLossThreshold = 0.02
	// So does a median this many times above the target's own baseline. A
	// multiple rather than an absolute, because 20 ms is fine for the transit
	// anchor and terrible for a core one.
	episodeLatencyMultiple = 4
	// Consecutive bad minutes before an episode opens, and consecutive good
	// ones before it closes. Three of each keeps a single bad minute out of
	// the event log while still catching anything that lasts.
	episodeOpenAfter  = 3
	episodeCloseAfter = 3
)

// updateEpisode records sustained degradation as an event.
//
// Only the anchors participate. The peer target's latency is control-plane
// noise (see the file comment) and its loss follows the access node's CPU, so
// running this on it would fill the event log with the ISP's router being busy.
func (p *uplinkProber) updateEpisode(target *uplinkTarget, row minuteRow) {
	if target.anchor.Role == rolePeer {
		return
	}
	if p.inStartupGrace(row.TS) || p.inMaintenance(row.TS) {
		// pppd went down with this service, or the whole estate is being
		// rebooted on purpose, and the loss in this minute is the reconnect.
		// Returning before the counters, not after, so the window cannot bank
		// bad minutes and open an episode the moment it closes.
		return
	}

	if target.baseline == 0 || row.TS.Minute() == 0 {
		// Recomputed hourly, and on the first minute after start, from the
		// last week. Cheap enough to do more often, but a baseline that moves
		// within an episode would let a slow degradation redefine "normal" as
		// it went and never trip.
		if value, ok, err := p.store.baseline(target.anchor.Name, row.TS.Add(-7*24*time.Hour)); err != nil {
			log.Printf("uplink: baseline %s: %v", target.anchor.Name, err)
		} else if ok {
			target.baseline = value
		}
	}

	reason := ""
	switch {
	case row.Loss() > episodeLossThreshold:
		reason = fmt.Sprintf("%.1f%% loss", row.Loss()*100)
	case target.baseline > 0 && row.Received > 0 && row.RTTP50 > target.baseline*episodeLatencyMultiple:
		reason = fmt.Sprintf("median %.0f ms against a %.0f ms baseline", row.RTTP50, target.baseline)
	}

	if reason != "" {
		target.goodRun = 0
		target.badRun++
		if target.badRun >= episodeOpenAfter && !target.episodeOpen {
			id, err := p.store.appendEvent(uplinkEvent{
				TS:     row.TS.Add(-time.Duration(episodeOpenAfter-1) * time.Minute),
				Kind:   eventDegraded,
				Target: target.anchor.Name,
				Detail: reason,
			})
			if err != nil {
				log.Printf("uplink: %v", err)
				return
			}
			target.episodeID = id
			target.setEpisodeOpen(true)
			log.Printf("uplink: %s degraded: %s", target.anchor.Name, reason)
		}
		return
	}

	target.badRun = 0
	target.goodRun++
	if target.goodRun >= episodeCloseAfter && target.episodeOpen {
		if err := p.store.closeEvent(target.episodeID, row.TS); err != nil {
			log.Printf("uplink: %v", err)
			return
		}
		target.setEpisodeOpen(false)
		log.Printf("uplink: %s recovered", target.anchor.Name)
	}
}

func (p *uplinkProber) pruneLoop() {
	ticker := time.NewTicker(pruneInterval)
	defer ticker.Stop()

	for now := range ticker.C {
		if err := p.store.prune(now.Add(-p.retention)); err != nil {
			log.Printf("uplink: %v", err)
		}
	}
}

// watchPPP keeps the peer target pointed at the current peer address and
// records session changes.
//
// Polled rather than derived once at start because the peer address is not
// guaranteed stable across reconnects — it is whatever the access node hands
// out during IPCP, and this line reconnects at least daily from the 05:00
// redial timer. A peer address cached at boot would, after the first
// reconnect that moved it, leave the liveness check probing an address that
// belongs to somebody else's session.
func (p *uplinkProber) watchPPP() {
	ticker := time.NewTicker(pppPollInterval)
	defer ticker.Stop()

	p.pollPPP(time.Now())
	for now := range ticker.C {
		p.pollPPP(now)
	}
}

func (p *uplinkProber) pollPPP(now time.Time) {
	local, peer, ok := readPPPAddresses(p.pppIface)

	p.mu.Lock()
	defer p.mu.Unlock()

	if !ok {
		// No address on the interface: the session is down. The peer target is
		// pointed at nothing, which stops its probe loop rather than filling
		// the history with loss against a stale address.
		if p.peer != nil {
			p.peer.setAddress(netip.Addr{})
		}
		// Inside the startup grace the session is presumed to be mid-redial
		// after the rebuild that restarted this process. The latch is left
		// clear on purpose: if the session is still down when the window
		// closes, the next poll records it then, timed from the moment it was
		// confirmed rather than from the restart.
		if !p.pppDown && !p.inStartupGrace(now) && !p.inMaintenance(now) {
			id, err := p.store.appendEvent(uplinkEvent{
				TS: now, Kind: eventPPPDown, Target: p.pppIface,
				Detail: "no address on the interface",
			})
			if err != nil {
				log.Printf("uplink: %v", err)
				return
			}
			p.pppEvent = id
			p.pppDown = true
			log.Printf("uplink: %s has no address, session down", p.pppIface)
		}
		p.pppLocal, p.pppPeer = netip.Addr{}, netip.Addr{}
		return
	}

	if p.pppDown {
		if err := p.store.closeEvent(p.pppEvent, now); err != nil {
			log.Printf("uplink: %v", err)
		}
		p.pppDown = false
		log.Printf("uplink: %s back up, local %s peer %s", p.pppIface, local, peer)
	}

	// A changed local address means a new session even when the peer happens
	// to be handed back unchanged, so both are compared.
	if p.pppLocal.IsValid() && (p.pppLocal != local || p.pppPeer != peer) {
		detail := fmt.Sprintf("session moved from %s via %s to %s via %s", p.pppLocal, p.pppPeer, local, peer)
		// The previous session ends where this one begins. Without this every
		// peer_changed row ever written stayed open and the log read as a
		// column of "ongoing" — one per daily redial, all claiming to still be
		// current. An open row here means "this is the session in use now",
		// so exactly one can be open, and a closed one's duration is how long
		// that session lasted.
		if err := p.store.closeOpenEvents(eventPeerChanged, p.pppIface, now); err != nil {
			log.Printf("uplink: %v", err)
		}
		if _, err := p.store.appendEvent(uplinkEvent{
			TS: now, Kind: eventPeerChanged, Target: p.pppIface, Detail: detail,
		}); err != nil {
			log.Printf("uplink: %v", err)
		}
		log.Printf("uplink: %s", detail)
	}
	p.pppLocal, p.pppPeer = local, peer

	if p.peer != nil && p.peer.setAddress(peer) {
		log.Printf("uplink: probing PPP peer %s", peer)
	}
}

// snapshots returns the live view of every target, in configuration order.
func (p *uplinkProber) snapshots() []targetSnapshot {
	out := make([]targetSnapshot, 0, len(p.targets))
	for _, target := range p.targets {
		out = append(out, target.snapshot())
	}
	return out
}

// linkUp reports whether the PPP session currently has an address.
func (p *uplinkProber) linkUp() bool {
	p.mu.Lock()
	defer p.mu.Unlock()
	return !p.pppDown && p.pppLocal.IsValid()
}

// readPPPAddresses shells out for the interface's addresses.
//
// iproute2 rather than the netlink in the standard library because Go's net
// package exposes an interface's own address but not its point-to-point peer:
// the peer arrives in a separate netlink attribute that net.Interface.Addrs
// discards. `ip` is already in this unit's PATH.
func readPPPAddresses(iface string) (local netip.Addr, peer netip.Addr, ok bool) {
	output, err := exec.Command("ip", "-4", "addr", "show", "dev", iface).Output()
	if err != nil {
		return netip.Addr{}, netip.Addr{}, false
	}
	return parsePPPAddresses(string(output))
}

// parsePPPAddresses pulls the local and peer addresses out of `ip -4 addr
// show` output. A point-to-point interface renders as:
//
//	inet 217.164.183.46 peer 217.164.182.1/32 scope global ppp0
//
// Both are required: an interface with an address but no peer is not a usable
// PPP session for this purpose, and reporting the local address as the peer is
// how a probe ends up measuring the loopback path at 48 microseconds.
func parsePPPAddresses(output string) (local netip.Addr, peer netip.Addr, ok bool) {
	for _, line := range strings.Split(output, "\n") {
		fields := strings.Fields(line)
		for i, field := range fields {
			if field != "inet" || i+3 >= len(fields) {
				continue
			}
			if fields[i+2] != "peer" {
				continue
			}

			local, err := netip.ParseAddr(stripPrefixLength(fields[i+1]))
			if err != nil {
				continue
			}
			peer, err := netip.ParseAddr(stripPrefixLength(fields[i+3]))
			if err != nil {
				continue
			}
			return local, peer, true
		}
	}
	return netip.Addr{}, netip.Addr{}, false
}

func stripPrefixLength(value string) string {
	if slash := strings.IndexByte(value, '/'); slash >= 0 {
		return value[:slash]
	}
	return value
}

// loadSampler tracks the WAN throughput the probes are competing with.
//
// Sampled at the same rate as the probes and attached to each one, which is
// what makes a latency-under-load reading possible at all: the interesting
// number is not the p95 of a day, it is the p95 during the minutes the line
// was full. Bufferbloat is invisible in a latency graph that does not know
// what the line was carrying.
type loadSampler struct {
	iface string
	// Indirected for the tests, which have no interface to read and need to
	// drive the counter-reset path deliberately.
	read func(iface, counter string) (uint64, error)

	mu       sync.Mutex
	down     uint64
	up       uint64
	prevRx   uint64
	prevTx   uint64
	prevAt   time.Time
	haveprev bool
}

func newLoadSampler(iface string) *loadSampler {
	return &loadSampler{iface: iface, read: readCounter}
}

func (l *loadSampler) run() {
	ticker := time.NewTicker(time.Second)
	defer ticker.Stop()

	for now := range ticker.C {
		l.sample(now)
	}
}

func (l *loadSampler) sample(now time.Time) {
	rx, rxErr := l.read(l.iface, "rx_bytes")
	tx, txErr := l.read(l.iface, "tx_bytes")

	l.mu.Lock()
	defer l.mu.Unlock()

	if rxErr != nil || txErr != nil {
		// The interface is gone, which happens between pppd sessions. Rates go
		// to zero and the next sample after it returns starts a fresh baseline.
		l.down, l.up, l.haveprev = 0, 0, false
		return
	}

	// A counter that went backwards is a new interface with the same name, not
	// negative traffic. pppd recreates ppp0 on every reconnect.
	if !l.haveprev || rx < l.prevRx || tx < l.prevTx {
		l.prevRx, l.prevTx, l.prevAt, l.haveprev = rx, tx, now, true
		l.down, l.up = 0, 0
		return
	}

	elapsed := now.Sub(l.prevAt).Seconds()
	if elapsed > 0 {
		l.down = uint64(float64(rx-l.prevRx) * 8 / elapsed)
		l.up = uint64(float64(tx-l.prevTx) * 8 / elapsed)
	}
	l.prevRx, l.prevTx, l.prevAt = rx, tx, now
}

// rates returns the most recent download and upload rates in bits/second.
func (l *loadSampler) rates() (down uint64, up uint64) {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.down, l.up
}

func readCounter(iface, name string) (uint64, error) {
	text, err := readFileTrimmed("/sys/class/net/" + iface + "/statistics/" + name)
	if err != nil {
		return 0, err
	}
	return strconv.ParseUint(text, 10, 64)
}

// echoRequest builds an ICMP echo request.
//
// Hand-built rather than pulling in golang.org/x/net/icmp: the message is
// eight bytes of header and a payload, and the checksum is the one in RFC 1071
// that this repo already implements nowhere else. The payload is a fixed
// pattern of the same 56 bytes ping(8) uses, so a capture of these probes
// looks like what an operator expects to see.
func echoRequest(id, seq uint16) []byte {
	return echoRequestSized(id, seq, 56)
}

// parseEchoReply returns the identifier and sequence of an echo reply.
//
// Linux hands a raw ICMP socket the IP header along with the payload, so the
// header is stripped when it is there. Detected rather than assumed: the first
// byte of an echo reply is 0x00 and the first byte of an IPv4 header is 0x4X,
// which cannot be confused.
func parseEchoReply(packet []byte) (id, seq uint16, ok bool) {
	if len(packet) >= 20 && packet[0]>>4 == 4 {
		headerLen := int(packet[0]&0x0f) * 4
		if headerLen < 20 || headerLen > len(packet) {
			return 0, 0, false
		}
		packet = packet[headerLen:]
	}
	if len(packet) < 8 {
		return 0, 0, false
	}
	if packet[0] != 0 { // echo reply
		return 0, 0, false
	}
	return binary.BigEndian.Uint16(packet[4:]), binary.BigEndian.Uint16(packet[6:]), true
}

// internetChecksum is the ones-complement sum of RFC 1071.
func internetChecksum(data []byte) uint16 {
	var sum uint32
	for i := 0; i+1 < len(data); i += 2 {
		sum += uint32(data[i])<<8 | uint32(data[i+1])
	}
	if len(data)%2 == 1 {
		sum += uint32(data[len(data)-1]) << 8
	}
	for sum>>16 != 0 {
		sum = sum&0xffff + sum>>16
	}
	return ^uint16(sum)
}
