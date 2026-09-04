package main

import (
	"bytes"
	"context"
	"fmt"
	"log"
	"net/http"
	"net/netip"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

// A device whose traffic has gone dark: one peer holding nearly all of the
// bytes it moved in the last minute, with no ordinary name behind it.
//
// WHY BOTH HALVES. Either one alone is ordinary. A single peer holding 90% of
// a device's traffic is what a video call, a game, a system update and an
// in-ISP CDN cache all look like — the Meta and Google caches inside AS5384
// hold entire evenings of one device's bytes by design. An address nobody
// recognises is equally ordinary: a P2P call negotiates addresses through a
// signalling channel, and a CDN reuses one resolved an hour ago.
//
// Together they are not ordinary. Measured over the captures in ~/inbox/web
// (42 of them, taken from the peers page over August 2026), the pair fires on
// 8 and every one is a tunnel or an endpoint worth a look: two SSH tunnels to
// DigitalOcean on tcp/22, Cloudflare WARP on tcp/443, an X-VPN-shaped exit in
// AS24757 on tcp/20159, an opaque tcp/553. The heavy benign traffic in the
// same set — 45 MB to Akamai at an 86% share, 25 MB to an Etisalat GGC cache
// at 67% — is suppressed by the name test alone, which is the whole reason it
// is here.
//
// "NO ORDINARY NAME" AND NOT "NO NAME", which is a correction and not a
// refinement. The first version of this asked whether anything had resolved a
// name to the address at all, and that is a test a fronted tunnel passes: of
// the eight above, 138.113.249.19 turned out to be in blocky's log 31 times,
// as tcdn1.driftwoodmetrics.com. The tunnels with a hostname are the ones
// built to move between endpoints, so the blunt test let through exactly the
// class most worth catching. commondomains.go carries the fix and the
// evidence.
//
// WHAT A TUNNELLED DEVICE'S OWN DNS LOOKS LIKE, since the obvious third
// condition is "and it stopped resolving names". It does not. Every one of
// the eight kept resolving throughout: www.google.com on a loop for
// connectivity checking, STUN hosts, gvt2.com beacons, and in one case a burst
// of malformed labels. A device on a tunnel is noisier in DNS than one that is
// not, so a per-device query-rate floor would have suppressed findings rather
// than found them, and there is deliberately no such condition here.
//
// WHY DELTAS AND NOT TOTALS. conntrack's byte counters are cumulative over a
// flow's whole life, and the kernel keeps a closed TCP entry for days. Reading
// them as-is makes a device that sent one large file this morning and nothing
// since look identical to one tunnelling right now. Each sample therefore
// subtracts the previous one and judges the difference, which is a rate over
// the sample interval and cannot be inflated by history. It also means a
// tunnel that is merely *up* — idle, keepalives only — is deliberately not a
// finding. There is no shortage of idle VPN clients on this network and none
// of them is news.
//
// WHAT THIS IS NOT. It is not a blocklist, a verdict, or grounds for anything
// automatic. It publishes one gauge and the alert on it is quiet by design;
// what to do about a finding is the peers page's business and a person's.

const (
	// How often the connection table is sampled. Matches the host-flow
	// collector next door for the same reason: this walks the whole table,
	// which is thousands of entries on a busy link, and the share of a
	// conversation is a property of the conversation rather than of an
	// instant.
	darkPeerInterval = 60 * time.Second

	// How long after start-up findings are suppressed.
	//
	// The answer log starts empty and fills from a bounded backfill of the
	// journal, so for the first minutes of a process every peer on the network
	// looks nameless and every busy device looks like a tunnel. Without this,
	// a rebuild switch — which restarts this service — would post a burst of
	// alerts about the same devices every time, which is precisely the way an
	// alert stops being read.
	darkPeerWarmup = 15 * time.Minute

	// The share of a device's recent bytes one peer must hold. 0.85 rather
	// than something closer to 1.0 because a tunnelled device still resolves
	// and fetches a little on the side — the confirmed tunnels in the capture
	// set sit between 0.91 and 1.00, and the benign traffic that reaches this
	// far sits below 0.82.
	darkPeerShare = 0.85

	// How much the device must have moved with that peer over one interval
	// before it is worth a word. 3 MB/min is around 400 kbit/s: past what a
	// keepalive or a stuck download does, and far below what any of the
	// tunnels in the capture set were doing.
	darkPeerRate = 3 << 20

	// A ceiling on findings carried in one snapshot, so a pathological table
	// cannot turn into an unbounded metric page. Anything past it is logged
	// rather than silently dropped — see sample().
	darkPeerMaxFindings = 24
)

// darkPeerFinding is one device and the peer holding its traffic.
type darkPeerFinding struct {
	Client netip.Addr
	Name   string
	Peer   netip.Addr
	// What the peer last called itself, empty when nothing ever resolved to
	// it. Carried into the notification because it is the single most
	// actionable string in one: "tcdn1.driftwoodmetrics.com" is a domain to go
	// and look up, where a bare address is a morning's work.
	DNSName string
	// Bytes moved with this peer over the last interval, and that as a
	// fraction of everything the device moved over the same one. Both are
	// published, and the alert reads the bytes rather than the fraction: "97%"
	// is the same sentence for 40 KB and for 90 MB, and only one of those is
	// worth reading at night.
	Bytes  uint64
	Share  float64
	Ports  string
	ASN    uint32
	Org    string
	Region string
}

// peerKey identifies one device-to-peer conversation across samples. Both ends
// are needed: two devices talking to the same address are two conversations,
// and one device that moves to a new address is a new conversation.
type peerKey struct {
	client netip.Addr
	peer   netip.Addr
}

// darkPeerMonitor samples the connection table on a ticker and publishes what
// it found for Prometheus to scrape.
//
// Holds the peers server rather than duplicating its readers: the device list
// this needs — leases joined to the neighbour table so a device's IPv4 and
// IPv6 addresses count as one device — is exactly what the devices page
// builds, and a second implementation of it would be a second answer to the
// same question.
type darkPeerMonitor struct {
	peers *peersServer

	// The domains whose presence behind an address makes it unremarkable. Nil,
	// or loaded but empty, means the collector falls back to treating any name
	// as unremarkable — see judge() for why that is the safe direction.
	common *commonDomains

	// Peers never counted, and devices never judged. Both exist because there
	// are addresses on this network for which the signature is correct and the
	// conclusion is still wrong: the nebula lighthouse is a tunnel by
	// definition, and a device deliberately running a VPN is not news every
	// hour. Empty by default — nothing is exempt unless the unit says so.
	ignorePeers   []netip.Prefix
	exemptClients []netip.Prefix

	share float64
	rate  uint64

	// Injected so the tests can run a sequence of samples without sleeping and
	// without waiting out the warm-up.
	now   func() time.Time
	start time.Time

	mu          sync.Mutex
	previous    map[peerKey]uint64
	primed      bool
	leaseWarned bool
	findings    []darkPeerFinding
	devices     int
	sampled     time.Time
	healthy     bool
}

// newDarkPeerMonitor returns nil when the router cannot answer the question,
// which is the case whenever there is no answer log: without it every peer is
// nameless and every busy device is a finding. Nil disables the collector and
// its route, the same way a nil capture manager disables the capture buttons.
func newDarkPeerMonitor(peers *peersServer) *darkPeerMonitor {
	if peers == nil || peers.answers == nil {
		return nil
	}
	return &darkPeerMonitor{
		peers:    peers,
		share:    darkPeerShare,
		rate:     darkPeerRate,
		now:      time.Now,
		start:    time.Now(),
		previous: map[peerKey]uint64{},
	}
}

// parsePrefixList reads a comma-separated list of addresses and CIDRs.
//
// A bare address is taken as a host route rather than rejected, because that
// is how every one of these is written by hand — the lighthouse is an address,
// not a /32 — and requiring the mask would mean an entry that silently does
// nothing when someone forgets it.
func parsePrefixList(raw string) []netip.Prefix {
	var out []netip.Prefix
	for _, field := range strings.Split(raw, ",") {
		field = strings.TrimSpace(field)
		if field == "" {
			continue
		}
		if prefix, err := netip.ParsePrefix(field); err == nil {
			out = append(out, prefix.Masked())
			continue
		}
		if addr, err := netip.ParseAddr(field); err == nil {
			out = append(out, netip.PrefixFrom(addr.Unmap(), addr.BitLen()))
			continue
		}
		log.Printf("dark peer monitor: ignoring unparseable list entry %q", field)
	}
	return out
}

func inPrefixes(addr netip.Addr, prefixes []netip.Prefix) bool {
	addr = addr.Unmap()
	for _, prefix := range prefixes {
		if prefix.Contains(addr) {
			return true
		}
	}
	return false
}

// run samples until the context is cancelled.
func (m *darkPeerMonitor) run(ctx context.Context) {
	ticker := time.NewTicker(darkPeerInterval)
	defer ticker.Stop()
	for {
		m.sample(ctx)
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
		}
	}
}

// sample takes one reading and replaces the snapshot.
//
// A failed read leaves the previous findings in place and only clears the
// health flag. The alternative — dropping the findings — would resolve a
// firing alert because conntrack was briefly unavailable, and then fire it
// again a minute later. For an alert about a device tunnelling, a stale
// finding is the safer of the two failures.
func (m *darkPeerMonitor) sample(ctx context.Context) {
	raw, err := m.peers.conntrack(ctx)
	if err != nil {
		log.Printf("dark peer monitor: read connection table: %v", err)
		m.mu.Lock()
		m.healthy = false
		m.mu.Unlock()
		return
	}

	// Not fatal, and not repeated. Devices with no lease still appear, because
	// the device list falls back to the neighbour table for exactly that case;
	// they are just nameless. Logged once rather than on every sample: this
	// runs on a minute timer forever, and a router with no lease file
	// configured would otherwise write the same line into the journal 1440
	// times a day.
	leases, err := readLeases(m.peers.leasesPath, m.peers.lanNet)
	if err != nil {
		m.mu.Lock()
		first := !m.leaseWarned
		m.leaseWarned = true
		m.mu.Unlock()
		if first {
			log.Printf("dark peer monitor: read leases from %q: %v (devices will be unnamed)",
				m.peers.leasesPath, err)
		}
	}
	rows := m.peers.deviceRows(ctx, leases)

	// Which device each address belongs to, and the address set each device is
	// matched against. Built once per sample: the alternative is one pass over
	// the table per device, which on this network is fifty passes a minute.
	owner := map[netip.Addr]int{}
	sets := make([]addrSet, len(rows))
	for i, row := range rows {
		sets[i] = newAddrSet(row.addrs...)
		for _, addr := range row.addrs {
			owner[addr.Unmap()] = i
		}
	}

	current := map[peerKey]uint64{}
	ports := map[peerKey]map[portKey]uint64{}
	if err := eachFlow(bytes.NewReader(raw), func(f flow) {
		index, ok := owner[f.Src.Unmap()]
		if !ok {
			if index, ok = owner[f.Dst.Unmap()]; !ok {
				return
			}
		}
		view, ok := f.from(sets[index])
		if !ok || !isPublicAddr(view.Peer) {
			return
		}
		if inPrefixes(view.Peer, m.ignorePeers) {
			return
		}
		key := peerKey{client: rows[index].Addr, peer: view.Peer}
		current[key] += f.Bytes
		if view.HavePort {
			if ports[key] == nil {
				ports[key] = map[portKey]uint64{}
			}
			ports[key][view.Port] += f.Bytes
		}
	}); err != nil {
		log.Printf("dark peer monitor: parse connection table: %v", err)
		m.mu.Lock()
		m.healthy = false
		m.mu.Unlock()
		return
	}

	m.mu.Lock()
	previous, primed := m.previous, m.primed
	m.previous, m.primed = current, true
	warm := m.now().Sub(m.start) >= darkPeerWarmup
	m.mu.Unlock()

	findings := []darkPeerFinding{}
	if primed && warm {
		findings = m.judge(rows, current, previous, ports)
	}

	m.mu.Lock()
	m.findings = findings
	m.devices = len(rows)
	m.sampled = m.now()
	m.healthy = true
	m.mu.Unlock()
}

// judge turns two samples into findings.
//
// Deltas are floored at zero rather than treated as counter resets. A flow
// that closed between samples takes its bytes out of the table entirely, so
// the key disappears and contributes nothing; a key whose count went backwards
// is conntrack having reaped one flow and started another on the same tuple,
// where the honest reading of the difference is "unknown", not "negative".
func (m *darkPeerMonitor) judge(rows []deviceRow, current, previous map[peerKey]uint64, ports map[peerKey]map[portKey]uint64) []darkPeerFinding {
	type deviceDelta struct {
		total uint64
		peers int
		top   netip.Addr
		best  uint64
	}
	byClient := map[netip.Addr]*deviceDelta{}

	for key, now := range current {
		delta := now
		if before, seen := previous[key]; seen {
			if now <= before {
				continue
			}
			delta = now - before
		}
		if delta == 0 {
			continue
		}
		entry := byClient[key.client]
		if entry == nil {
			entry = &deviceDelta{}
			byClient[key.client] = entry
		}
		entry.total += delta
		entry.peers++
		if delta > entry.best {
			entry.top, entry.best = key.peer, delta
		}
	}

	names := map[netip.Addr]string{}
	for _, row := range rows {
		names[row.Addr] = row.Name
	}

	var findings []darkPeerFinding
	for client, entry := range byClient {
		if entry.total < m.rate || !entry.top.IsValid() {
			continue
		}
		if inPrefixes(client, m.exemptClients) {
			continue
		}
		share := float64(entry.best) / float64(entry.total)
		if share < m.share {
			continue
		}
		// The test the whole thing turns on, and it is not "does this address
		// have a name". A fronted tunnel has one — see the header of
		// commondomains.go for the case that proved it — so the question is
		// whether the name is one that tells you nothing: an in-ISP cache, a
		// CDN, a vendor's own infrastructure. Those are listed. A heavy flow
		// to an address whose only name is a domain nobody has ever called
		// ordinary is the finding, whether or not DNS was involved.
		dnsName, named := m.peers.answers.Lookup(entry.top)
		if named && m.common.covers(dnsName) {
			continue
		}
		// The list failed to load, so fall back to the blunter test this
		// replaced: any name suppresses. Being blind to fronted tunnels until
		// someone fixes the deploy is the better of the two failures — the
		// alternative reports every CDN on the network at once, which is how
		// an alert stops being read at all.
		if named && !m.common.ready() {
			continue
		}

		finding := darkPeerFinding{
			Client:  client,
			Name:    names[client],
			Peer:    entry.top,
			DNSName: dnsName,
			Bytes:   entry.best,
			Share:   share,
			Ports:   topPorts(ports[peerKey{client: client, peer: entry.top}]),
		}
		if info, ok := m.peers.tables.asnTable().Lookup(entry.top); ok {
			finding.ASN, finding.Org = info.Number, info.Org
		}
		if code, ok := m.peers.tables.geoTable().Lookup(entry.top); ok {
			finding.Region = code
		}
		findings = append(findings, finding)
	}

	// Heaviest first, so a truncated page keeps the findings worth having.
	sort.Slice(findings, func(i, j int) bool {
		if findings[i].Bytes != findings[j].Bytes {
			return findings[i].Bytes > findings[j].Bytes
		}
		return findings[i].Client.Less(findings[j].Client)
	})
	if len(findings) > darkPeerMaxFindings {
		log.Printf("dark peer monitor: %d findings this sample, publishing the %d heaviest",
			len(findings), darkPeerMaxFindings)
		findings = findings[:darkPeerMaxFindings]
	}
	return findings
}

// topPorts renders the two heaviest service ports of a conversation, which is
// most of what separates one kind of opaque flow from another: tcp/22 is an
// SSH tunnel, tcp/443 is something wearing TLS, and a pair of five-digit UDP
// ports is neither.
func topPorts(totals map[portKey]uint64) string {
	ordered := orderPorts(totals)
	if len(ordered) > 2 {
		ordered = ordered[:2]
	}
	names := make([]string, 0, len(ordered))
	for _, use := range ordered {
		names = append(names, use.String())
	}
	return strings.Join(names, ",")
}

// darkPeerSnapshot is one complete reading, copied out from under the lock.
type darkPeerSnapshot struct {
	Findings []darkPeerFinding
	Devices  int
	Sampled  time.Time
	Healthy  bool
}

// snapshot returns the last reading.
func (m *darkPeerMonitor) snapshot() darkPeerSnapshot {
	if m == nil {
		return darkPeerSnapshot{}
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	return darkPeerSnapshot{
		Findings: append([]darkPeerFinding(nil), m.findings...),
		Devices:  m.devices,
		Sampled:  m.sampled,
		Healthy:  m.healthy,
	}
}

// handleMetrics publishes the snapshot.
//
// Registered on the mesh listener only, alongside the peers pages and for the
// same reason: this says which device is talking to which address, which is a
// claim about a person's evening, and the LAN listener deliberately carries no
// route that can see a device. Alloy scrapes it over the mesh address.
//
// The finding series are emitted only while they hold. An absent series is how
// Prometheus should read "nothing to say" — the alternative, a 0 for every
// device on the network every minute, is the same information at fifty times
// the cardinality, and makes the alert rule carry a filter that the exporter
// should have applied.
func (m *darkPeerMonitor) handleMetrics(w http.ResponseWriter, _ *http.Request) {
	reading := m.snapshot()

	var out strings.Builder
	out.WriteString("# HELP router_host_dark_peer One peer holds nearly all of a device's recent traffic and no name was ever resolved to it.\n")
	out.WriteString("# TYPE router_host_dark_peer gauge\n")
	out.WriteString("# HELP router_host_dark_peer_bytes Bytes the device moved with that peer over the last sample interval.\n")
	out.WriteString("# TYPE router_host_dark_peer_bytes gauge\n")
	out.WriteString("# HELP router_host_dark_peer_share Fraction of the device's bytes over that interval held by the peer.\n")
	out.WriteString("# TYPE router_host_dark_peer_share gauge\n")

	for _, finding := range reading.Findings {
		labels := fmt.Sprintf(
			"{client=%q,name=%q,peer=%q,dns=%q,service=%q,asn=%q,org=%q,country=%q}",
			finding.Client.String(),
			cleanLabelValue(finding.Name),
			finding.Peer.String(),
			cleanLabelValue(finding.DNSName),
			finding.Ports,
			strconv.FormatUint(uint64(finding.ASN), 10),
			cleanLabelValue(finding.Org),
			finding.Region,
		)
		// The same label set on all three, rather than a bare client/peer pair
		// on the two numbers. The alert rule reads the byte gauge — a
		// notification saying how much moved where is worth more than one
		// saying a boolean went true — and it can only put the peer, the
		// service and the AS into its message if they are labels of the series
		// it selected. Cardinality is unchanged: these series exist together or
		// not at all.
		fmt.Fprintf(&out, "router_host_dark_peer%s 1\n", labels)
		fmt.Fprintf(&out, "router_host_dark_peer_bytes%s %d\n", labels, finding.Bytes)
		fmt.Fprintf(&out, "router_host_dark_peer_share%s %g\n", labels, finding.Share)
	}

	out.WriteString("# HELP router_host_dark_peer_devices Devices the last sample examined.\n")
	out.WriteString("# TYPE router_host_dark_peer_devices gauge\n")
	fmt.Fprintf(&out, "router_host_dark_peer_devices %d\n", reading.Devices)
	out.WriteString("# HELP router_host_dark_peer_collector_success Whether the last sample completed.\n")
	out.WriteString("# TYPE router_host_dark_peer_collector_success gauge\n")
	fmt.Fprintf(&out, "router_host_dark_peer_collector_success %d\n", boolToInt(reading.Healthy))

	// When the last sample completed, so a collector that is stuck rather than
	// failing can be seen. The health gauge cannot show that on its own: a
	// goroutine that has wedged keeps the last snapshot, and the last snapshot
	// says the last sample went fine. Absent until the first one lands, which
	// is honest — there is no time to report yet — rather than 0, which would
	// read as 1970 and alert on every start.
	if !reading.Sampled.IsZero() {
		out.WriteString("# HELP router_host_dark_peer_last_sample_timestamp_seconds When the collector last completed a sample.\n")
		out.WriteString("# TYPE router_host_dark_peer_last_sample_timestamp_seconds gauge\n")
		fmt.Fprintf(&out, "router_host_dark_peer_last_sample_timestamp_seconds %d\n", reading.Sampled.Unix())
	}

	w.Header().Set("Content-Type", "text/plain; version=0.0.4; charset=utf-8")
	fmt.Fprint(w, out.String())
}

// cleanLabelValue strips what a Prometheus label cannot carry.
//
// Device names and ASN organisation strings are the two values here that come
// from outside this program — one is whatever hostname a device announced over
// DHCP, the other comes from a downloaded table — so neither is trusted. The
// quoting itself is left to %q at the call site, which already renders a
// backslash, a quote and a newline in exactly the three forms the text format
// defines. What %q does NOT produce a legal escape for is any other control
// byte: it writes \x00, which the scraper rejects, and rejecting is not local —
// one bad byte in one hostname discards the whole page and every finding on
// it. Those bytes are dropped here instead.
func cleanLabelValue(value string) string {
	return strings.Map(func(r rune) rune {
		if r == '\n' || r == '\t' {
			return ' '
		}
		if r < 0x20 || r == 0x7f {
			return -1
		}
		return r
	}, value)
}
