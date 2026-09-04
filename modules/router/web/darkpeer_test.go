package main

import (
	"context"
	"net/http"
	"net/http/httptest"
	"net/netip"
	"strings"
	"testing"
	"time"
)

// One SSH-shaped conversation and one ordinary web one, both from the same
// device. The bytes are small here; the tests grow them between samples,
// because what the monitor judges is the difference and never the total.
const darkPeerBaseline = `ipv4     2 tcp      6 431876 ESTABLISHED src=192.168.0.10 dst=203.0.113.10 sport=40000 dport=22 packets=10 bytes=1000 src=203.0.113.10 dst=198.51.100.1 sport=22 dport=40000 packets=10 bytes=1000 [ASSURED] mark=0 use=1
ipv4     2 tcp      6 431876 ESTABLISHED src=192.168.0.10 dst=203.0.113.20 sport=40001 dport=443 packets=10 bytes=1000 src=203.0.113.20 dst=198.51.100.1 sport=443 dport=40001 packets=10 bytes=1000 [ASSURED] mark=0 use=1
`

// The same two conversations after a minute in which the first moved 10 MB and
// the second moved nothing.
const darkPeerTunnelling = `ipv4     2 tcp      6 431876 ESTABLISHED src=192.168.0.10 dst=203.0.113.10 sport=40000 dport=22 packets=10 bytes=5001000 src=203.0.113.10 dst=198.51.100.1 sport=22 dport=40000 packets=10 bytes=5001000 [ASSURED] mark=0 use=1
ipv4     2 tcp      6 431876 ESTABLISHED src=192.168.0.10 dst=203.0.113.20 sport=40001 dport=443 packets=10 bytes=1000 src=203.0.113.20 dst=198.51.100.1 sport=443 dport=40001 packets=10 bytes=1000 [ASSURED] mark=0 use=1
`

// Both conversations busy, neither dominant: 10 MB against 8 MB is a 56%
// share, which is what a device doing two things at once looks like.
const darkPeerBusyEvenly = `ipv4     2 tcp      6 431876 ESTABLISHED src=192.168.0.10 dst=203.0.113.10 sport=40000 dport=22 packets=10 bytes=5001000 src=203.0.113.10 dst=198.51.100.1 sport=22 dport=40000 packets=10 bytes=5001000 [ASSURED] mark=0 use=1
ipv4     2 tcp      6 431876 ESTABLISHED src=192.168.0.10 dst=203.0.113.20 sport=40001 dport=443 packets=10 bytes=4001000 src=203.0.113.20 dst=198.51.100.1 sport=443 dport=40001 packets=10 bytes=4001000 [ASSURED] mark=0 use=1
`

// testDarkPeerMonitor returns a monitor already past its warm-up, reading
// whichever dump the returned setter was last given.
func testDarkPeerMonitor(t *testing.T) (*darkPeerMonitor, func(string)) {
	t.Helper()
	peers := testPeersServer(t)
	// Non-nil is what makes the monitor constructible at all, and an empty map
	// is the state that matters: nothing has been resolved to any of these
	// addresses, so every peer is nameless until a test says otherwise.
	peers.answers = &answerLog{
		unit:    "test",
		entries: map[netip.Addr]answerEntry{},
		now:     time.Now,
	}

	dump := darkPeerBaseline
	peers.conntrack = func(context.Context) ([]byte, error) { return []byte(dump), nil }

	monitor := newDarkPeerMonitor(peers)
	if monitor == nil {
		t.Fatal("newDarkPeerMonitor returned nil with an answer log set")
	}
	monitor.common = testCommonDomains(t, "# a comment\nexample.com\ncdn.example.net  # inline\n")
	now := time.Date(2026, 9, 4, 12, 0, 0, 0, time.UTC)
	monitor.now = func() time.Time { return now }
	monitor.start = now.Add(-time.Hour)
	return monitor, func(next string) { dump = next }
}

// sampleTwice primes the monitor on the baseline and then judges the given
// dump, which is the sequence every finding needs: one reading is a total, two
// are a rate.
func sampleTwice(t *testing.T, monitor *darkPeerMonitor, set func(string), second string) []darkPeerFinding {
	t.Helper()
	monitor.sample(context.Background())
	set(second)
	monitor.sample(context.Background())
	reading := monitor.snapshot()
	if !reading.Healthy {
		t.Fatal("collector reported itself unhealthy after two clean samples")
	}
	return reading.Findings
}

func TestDarkPeerReportsDominantUnnamedPeer(t *testing.T) {
	monitor, set := testDarkPeerMonitor(t)
	findings := sampleTwice(t, monitor, set, darkPeerTunnelling)

	if len(findings) != 1 {
		t.Fatalf("got %d findings, want 1: %+v", len(findings), findings)
	}
	found := findings[0]
	if found.Client != netip.MustParseAddr("192.168.0.10") {
		t.Errorf("client = %s, want 192.168.0.10", found.Client)
	}
	if found.Peer != netip.MustParseAddr("203.0.113.10") {
		t.Errorf("peer = %s, want 203.0.113.10", found.Peer)
	}
	// 10,000,000 of 10,000,000: the second conversation moved nothing over the
	// interval, so it is not in the denominator at all.
	if found.Bytes != 10_000_000 || found.Share != 1 {
		t.Errorf("bytes/share = %d/%v, want 10000000/1", found.Bytes, found.Share)
	}
	if found.Ports != "tcp/22" {
		t.Errorf("ports = %q, want tcp/22", found.Ports)
	}
	// Attribution comes from the same tables the peers page uses, and the
	// fixture puts this range in NL by registration and AE by geo — the
	// finding must carry the geo answer, like every other reader here.
	if found.ASN != 64496 || found.Org != "Example Hosting" || found.Region != "AE" {
		t.Errorf("attribution = AS%d %q %q, want AS64496 \"Example Hosting\" \"AE\"",
			found.ASN, found.Org, found.Region)
	}
}

// The test the whole detector turns on. Same traffic, same share, same rate —
// the only difference is that the address resolves from a domain already
// judged to mean nothing, which is what every ordinary heavy download, video
// call and CDN pull has behind it.
func TestDarkPeerSuppressesOrdinaryName(t *testing.T) {
	monitor, set := testDarkPeerMonitor(t)
	monitor.peers.answers.entries[netip.MustParseAddr("203.0.113.10")] = answerEntry{
		name: "assets.cdn.example.com",
		at:   time.Now(),
	}

	if findings := sampleTwice(t, monitor, set, darkPeerTunnelling); len(findings) != 0 {
		t.Fatalf("got %d findings for a peer under a listed domain, want 0: %+v", len(findings), findings)
	}
}

// The correction that matters, and the case the network actually produced: a
// tunnel endpoint holding 96% of a device's traffic that blocky had resolved
// 31 times, from tcdn1.driftwoodmetrics.com. Having a name is not the same as
// being ordinary, and the tunnels built to move between endpoints are exactly
// the ones that need one.
func TestDarkPeerReportsUnlistedName(t *testing.T) {
	monitor, set := testDarkPeerMonitor(t)
	monitor.peers.answers.entries[netip.MustParseAddr("203.0.113.10")] = answerEntry{
		name: "tcdn1.driftwoodmetrics.com",
		at:   time.Now(),
	}

	findings := sampleTwice(t, monitor, set, darkPeerTunnelling)
	if len(findings) != 1 {
		t.Fatalf("got %d findings for a fronted tunnel, want 1: %+v", len(findings), findings)
	}
	// The name goes into the finding: it is the one string in the
	// notification that can be looked up.
	if findings[0].DNSName != "tcdn1.driftwoodmetrics.com" {
		t.Errorf("dns name = %q, want tcdn1.driftwoodmetrics.com", findings[0].DNSName)
	}
}

// A domain that merely ends in a listed one is not the listed one. Without a
// label-boundary match, registering notexample.com would inherit
// example.com's exemption and buy permanent silence.
func TestDarkPeerNameMatchIsLabelBounded(t *testing.T) {
	monitor, set := testDarkPeerMonitor(t)
	monitor.peers.answers.entries[netip.MustParseAddr("203.0.113.10")] = answerEntry{
		name: "notexample.com",
		at:   time.Now(),
	}

	if findings := sampleTwice(t, monitor, set, darkPeerTunnelling); len(findings) != 1 {
		t.Fatalf("got %d findings for a lookalike domain, want 1: %+v", len(findings), findings)
	}
}

// With no list loaded, the collector must fall back to the blunt test rather
// than treat every named CDN on the network as a finding.
func TestDarkPeerFallsBackWithoutList(t *testing.T) {
	monitor, set := testDarkPeerMonitor(t)
	monitor.common = nil
	monitor.peers.answers.entries[netip.MustParseAddr("203.0.113.10")] = answerEntry{
		name: "tcdn1.driftwoodmetrics.com",
		at:   time.Now(),
	}

	if findings := sampleTwice(t, monitor, set, darkPeerTunnelling); len(findings) != 0 {
		t.Fatalf("got %d findings with no domain list loaded, want 0: %+v", len(findings), findings)
	}
}

func TestDarkPeerSuppressesSharedTraffic(t *testing.T) {
	monitor, set := testDarkPeerMonitor(t)
	if findings := sampleTwice(t, monitor, set, darkPeerBusyEvenly); len(findings) != 0 {
		t.Fatalf("got %d findings at a 56%% share, want 0: %+v", len(findings), findings)
	}
}

// A tunnel that is merely up is not a finding. The baseline dump sampled twice
// is a device whose flows exist and moved nothing, which is what an idle VPN
// client looks like — there are several of those on this network and none of
// them is worth a notification.
func TestDarkPeerIgnoresIdleFlows(t *testing.T) {
	monitor, set := testDarkPeerMonitor(t)
	if findings := sampleTwice(t, monitor, set, darkPeerBaseline); len(findings) != 0 {
		t.Fatalf("got %d findings with no bytes moved, want 0: %+v", len(findings), findings)
	}
}

// The first sample of a process is a set of lifetime totals, and reading it as
// a rate would report every long-lived flow on the network as a tunnel the
// moment router-web restarts.
func TestDarkPeerNeedsTwoSamples(t *testing.T) {
	monitor, set := testDarkPeerMonitor(t)
	set(darkPeerTunnelling)
	monitor.sample(context.Background())

	if findings := monitor.snapshot().Findings; len(findings) != 0 {
		t.Fatalf("got %d findings from a single sample, want 0: %+v", len(findings), findings)
	}
}

// Findings are suppressed until the answer log has had time to fill. Without
// this every rebuild switch would post the same burst of alerts about the same
// devices, since a freshly started answer log names nothing.
func TestDarkPeerSuppressedDuringWarmup(t *testing.T) {
	monitor, set := testDarkPeerMonitor(t)
	monitor.start = monitor.now().Add(-time.Minute)

	if findings := sampleTwice(t, monitor, set, darkPeerTunnelling); len(findings) != 0 {
		t.Fatalf("got %d findings inside the warm-up window, want 0: %+v", len(findings), findings)
	}
}

func TestDarkPeerHonoursIgnoredPeer(t *testing.T) {
	monitor, set := testDarkPeerMonitor(t)
	monitor.ignorePeers = parsePrefixList("203.0.113.0/24")

	if findings := sampleTwice(t, monitor, set, darkPeerTunnelling); len(findings) != 0 {
		t.Fatalf("got %d findings for an ignored peer range, want 0: %+v", len(findings), findings)
	}
}

func TestDarkPeerHonoursExemptClient(t *testing.T) {
	monitor, set := testDarkPeerMonitor(t)
	monitor.exemptClients = parsePrefixList("192.168.0.10")

	if findings := sampleTwice(t, monitor, set, darkPeerTunnelling); len(findings) != 0 {
		t.Fatalf("got %d findings for an exempt device, want 0: %+v", len(findings), findings)
	}
}

func TestParsePrefixListAcceptsBareAddresses(t *testing.T) {
	list := parsePrefixList(" 139.84.173.48, 10.10.0.0/24 ,, nonsense ")
	if len(list) != 2 {
		t.Fatalf("got %d prefixes, want 2: %v", len(list), list)
	}
	if !inPrefixes(netip.MustParseAddr("139.84.173.48"), list) {
		t.Error("bare address did not become a host route")
	}
	if inPrefixes(netip.MustParseAddr("139.84.173.49"), list) {
		t.Error("bare address matched a neighbouring address")
	}
	if !inPrefixes(netip.MustParseAddr("10.10.0.7"), list) {
		t.Error("CIDR entry did not match an address inside it")
	}
}

func TestDarkPeerMetricsRenderFindings(t *testing.T) {
	monitor, set := testDarkPeerMonitor(t)
	sampleTwice(t, monitor, set, darkPeerTunnelling)

	rec := httptest.NewRecorder()
	monitor.handleMetrics(rec, httptest.NewRequest(http.MethodGet, "/metrics/peers", nil))
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200", rec.Code)
	}
	body := rec.Body.String()

	labels := `{client="192.168.0.10",name="device-a",peer="203.0.113.10",dns="",service="tcp/22",asn="64496",org="Example Hosting",country="AE"}`
	if !strings.Contains(body, "router_host_dark_peer"+labels+" 1") {
		t.Fatalf("finding series missing from metrics:\n%s", body)
	}
	// The byte gauge carries the same labels rather than a bare client/peer
	// pair: it is the series the alert rule selects, and it can only name the
	// peer and the service in its message if they are labels of that series.
	if !strings.Contains(body, "router_host_dark_peer_bytes"+labels+" 10000000") {
		t.Errorf("byte gauge missing from metrics:\n%s", body)
	}
	if !strings.Contains(body, "router_host_dark_peer_collector_success 1") {
		t.Errorf("health gauge missing from metrics:\n%s", body)
	}
}

// Nothing to report must render as no series at all rather than a zero per
// device: the alert rule reads presence, and a page of zeroes would be the
// same claim at fifty times the cardinality.
func TestDarkPeerMetricsOmitSeriesWhenQuiet(t *testing.T) {
	monitor, set := testDarkPeerMonitor(t)
	sampleTwice(t, monitor, set, darkPeerBaseline)

	rec := httptest.NewRecorder()
	monitor.handleMetrics(rec, httptest.NewRequest(http.MethodGet, "/metrics/peers", nil))
	body := rec.Body.String()

	if strings.Contains(body, "router_host_dark_peer{") {
		t.Fatalf("quiet network still produced a finding series:\n%s", body)
	}
	if !strings.Contains(body, "router_host_dark_peer_devices 2") {
		t.Errorf("device count missing from metrics:\n%s", body)
	}
}

// A device chooses its own DHCP hostname, so a quote in one would otherwise
// produce a metrics page the scraper rejects in full — taking every other
// finding on the page down with it.
func TestDarkPeerMetricsEscapeDeviceNames(t *testing.T) {
	monitor, set := testDarkPeerMonitor(t)
	monitor.peers.leasesPath = writeLeases(t,
		"1 aa:bb:cc:dd:ee:01 192.168.0.10 say\"hello\" 01:aa\n"+
			"2 aa:bb:cc:dd:ee:02 192.168.0.20 * 01:bb\n")
	sampleTwice(t, monitor, set, darkPeerTunnelling)

	rec := httptest.NewRecorder()
	monitor.handleMetrics(rec, httptest.NewRequest(http.MethodGet, "/metrics/peers", nil))
	if !strings.Contains(rec.Body.String(), `name="say\"hello\""`) {
		t.Fatalf("device name was not escaped:\n%s", rec.Body.String())
	}
}

// A failed dump keeps the last findings rather than clearing them. Resolving a
// firing alert because conntrack was briefly unavailable, then firing it again
// a minute later, is worse than being a minute stale.
func TestDarkPeerKeepsFindingsWhenDumpFails(t *testing.T) {
	monitor, set := testDarkPeerMonitor(t)
	sampleTwice(t, monitor, set, darkPeerTunnelling)

	monitor.peers.conntrack = func(context.Context) ([]byte, error) { return nil, errFake }
	monitor.sample(context.Background())

	reading := monitor.snapshot()
	if len(reading.Findings) != 1 {
		t.Fatalf("got %d findings after a failed dump, want the previous 1", len(reading.Findings))
	}
	if reading.Healthy {
		t.Error("collector reported itself healthy after a failed dump")
	}
}
