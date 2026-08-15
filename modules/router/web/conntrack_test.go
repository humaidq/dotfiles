package main

import (
	"net/netip"
	"strings"
	"testing"
)

// Real `conntrack -L -o extended` output shape, with accounting enabled.
const conntrackFixture = `ipv4     2 tcp      6 431876 ESTABLISHED src=192.168.0.10 dst=203.0.113.10 sport=42957 dport=55199 packets=100 bytes=4000 src=203.0.113.10 dst=198.51.100.1 sport=55199 dport=42957 packets=90 bytes=26000 [ASSURED] mark=0 use=1
ipv4     2 tcp      6 431876 ESTABLISHED src=192.168.0.10 dst=203.0.113.10 sport=49710 dport=443 packets=10 bytes=500 src=203.0.113.10 dst=198.51.100.1 sport=443 dport=49710 packets=8 bytes=300 [ASSURED] mark=0 use=1
ipv4     2 tcp      6 110 TIME_WAIT src=192.168.0.10 dst=203.0.113.20 sport=1111 dport=443 packets=5 bytes=1000 src=203.0.113.20 dst=198.51.100.1 sport=443 dport=1111 packets=5 bytes=4000 [ASSURED] mark=0 use=1
ipv4     2 tcp      6 60 TIME_WAIT src=198.51.100.1 dst=203.0.113.99 sport=51342 dport=853 packets=3 bytes=900 src=203.0.113.99 dst=198.51.100.1 sport=853 dport=51342 packets=3 bytes=1200 [ASSURED] mark=0 use=1
ipv4     2 udp      17 30 src=192.168.0.10 dst=192.168.0.1 sport=5353 dport=53 packets=2 bytes=200 src=192.168.0.1 dst=192.168.0.10 sport=53 dport=5353 packets=2 bytes=400 mark=0 use=1
ipv4     2 tcp      6 100 ESTABLISHED src=192.168.0.99 dst=203.0.113.50 sport=2222 dport=443 packets=9 bytes=9000 src=203.0.113.50 dst=198.51.100.1 sport=443 dport=2222 packets=9 bytes=9000 [ASSURED] mark=0 use=1
`

func TestParseConntrackAggregatesPerPeer(t *testing.T) {
	peers, err := parseConntrack(strings.NewReader(conntrackFixture), netip.MustParseAddr("192.168.0.10"), nil)
	if err != nil {
		t.Fatalf("parseConntrack: %v", err)
	}
	if len(peers) != 2 {
		t.Fatalf("got %d peers, want 2: %+v", len(peers), peers)
	}
	// 203.0.113.10 = 4000+26000+500+300 = 30800, two flows summed.
	if peers[0].Addr != netip.MustParseAddr("203.0.113.10") {
		t.Fatalf("top peer = %s, want 203.0.113.10", peers[0].Addr)
	}
	if peers[0].Bytes != 30800 {
		t.Fatalf("top peer bytes = %d, want 30800", peers[0].Bytes)
	}
	if peers[0].Packets != 208 {
		t.Fatalf("top peer packets = %d, want 208", peers[0].Packets)
	}
	// 203.0.113.20 = 1000+4000 = 5000, sorted second.
	if peers[1].Addr != netip.MustParseAddr("203.0.113.20") || peers[1].Bytes != 5000 {
		t.Fatalf("second peer = %+v, want 203.0.113.20 with 5000 bytes", peers[1])
	}
}

func TestParseConntrackSkipsUnrelatedFlows(t *testing.T) {
	peers, err := parseConntrack(strings.NewReader(conntrackFixture), netip.MustParseAddr("192.168.0.10"), nil)
	if err != nil {
		t.Fatalf("parseConntrack: %v", err)
	}
	for _, peer := range peers {
		switch peer.Addr.String() {
		case "203.0.113.99":
			t.Fatal("router-originated flow was attributed to the device")
		case "192.168.0.1":
			t.Fatal("LAN-to-LAN flow was reported as a peer")
		case "203.0.113.50":
			t.Fatal("another device's flow was attributed to this device")
		}
	}
}

func TestParseConntrackEmptyForIdleDevice(t *testing.T) {
	peers, err := parseConntrack(strings.NewReader(conntrackFixture), netip.MustParseAddr("192.168.0.77"), nil)
	if err != nil {
		t.Fatalf("parseConntrack: %v", err)
	}
	if len(peers) != 0 {
		t.Fatalf("got %d peers for an idle device, want 0", len(peers))
	}
}

func TestParseConntrackRecordsServicePorts(t *testing.T) {
	peers, err := parseConntrack(strings.NewReader(conntrackFixture), netip.MustParseAddr("192.168.0.10"), nil)
	if err != nil {
		t.Fatalf("parseConntrack: %v", err)
	}
	// The device opened both flows to 203.0.113.10, so the service port is the
	// destination port in each: 55199 carried 30000 bytes and 443 carried 800.
	// Heaviest first, and the device's own ephemeral ports (42957, 49710) must
	// not appear at all.
	got := peers[0].Ports
	if len(got) != 2 {
		t.Fatalf("got %d ports, want 2: %+v", len(got), got)
	}
	if got[0].String() != "tcp/55199" || got[0].Bytes != 30000 {
		t.Fatalf("heaviest port = %s with %d bytes, want tcp/55199 with 30000", got[0], got[0].Bytes)
	}
	if got[1].String() != "tcp/443" || got[1].Bytes != 800 {
		t.Fatalf("second port = %s with %d bytes, want tcp/443 with 800", got[1], got[1].Bytes)
	}
	for _, use := range got {
		if use.Port == 42957 || use.Port == 49710 {
			t.Fatalf("the device's own ephemeral port was reported as a service: %s", use)
		}
	}
}

// A flow the peer opened towards the device: the service port is then the
// source port, not the destination.
const inboundFixture = `ipv4     2 udp      17 30 src=203.0.113.60 dst=192.168.0.10 sport=3478 dport=51000 packets=4 bytes=800 src=192.168.0.10 dst=203.0.113.60 sport=51000 dport=3478 packets=4 bytes=700 mark=2 use=1
`

func TestParseConntrackReadsInboundServicePortAndMark(t *testing.T) {
	peers, err := parseConntrack(strings.NewReader(inboundFixture), netip.MustParseAddr("192.168.0.10"), nil)
	if err != nil {
		t.Fatalf("parseConntrack: %v", err)
	}
	if len(peers) != 1 {
		t.Fatalf("got %d peers, want 1", len(peers))
	}
	if got := peers[0].Ports[0].String(); got != "udp/3478" {
		t.Fatalf("service port = %s, want udp/3478", got)
	}
	if !peers[0].HasMark(2) {
		t.Fatal("conntrack mark 2 was not recorded")
	}
	if peers[0].HasMark(1) {
		t.Fatal("a mark that never appeared was reported")
	}
	if peers[0].HasMark(0) {
		t.Fatal("mark 0 must never count as marked")
	}
}

func TestProtocolField(t *testing.T) {
	cases := []struct{ line, want string }{
		{"ipv4     2 tcp      6 431876 ESTABLISHED src=1.2.3.4 dst=5.6.7.8", "tcp"},
		{"ipv4     2 udp      17 30 src=1.2.3.4 dst=5.6.7.8", "udp"},
		{"ipv4     2 unknown  47 500 src=1.2.3.4 dst=5.6.7.8", "unknown"},
		{"src=1.2.3.4 dst=5.6.7.8 bytes=1", ""},
		{"", ""},
	}
	for _, tc := range cases {
		if got := protocolField(strings.Fields(tc.line)); got != tc.want {
			t.Fatalf("protocolField(%q) = %q, want %q", tc.line, got, tc.want)
		}
	}
}

func TestParseConntrackSplitsDirection(t *testing.T) {
	peers, err := parseConntrack(strings.NewReader(conntrackFixture), netip.MustParseAddr("192.168.0.10"), nil)
	if err != nil {
		t.Fatalf("parseConntrack: %v", err)
	}
	// Both flows to 203.0.113.10 were opened by the device, so the first
	// counter on each line is upload: 4000+500 up, 26000+300 down.
	if peers[0].Up != 4500 || peers[0].Down != 26300 {
		t.Fatalf("up/down = %d/%d, want 4500/26300", peers[0].Up, peers[0].Down)
	}
	if peers[0].Up+peers[0].Down != peers[0].Bytes {
		t.Fatalf("direction split %d+%d does not add up to the total %d",
			peers[0].Up, peers[0].Down, peers[0].Bytes)
	}
}

func TestParseConntrackDirectionForInboundFlow(t *testing.T) {
	// The peer opened this one, so the original-direction counter is download
	// and the reply is upload — the opposite assignment to the case above.
	peers, err := parseConntrack(strings.NewReader(inboundFixture), netip.MustParseAddr("192.168.0.10"), nil)
	if err != nil {
		t.Fatalf("parseConntrack: %v", err)
	}
	if peers[0].Down != 800 || peers[0].Up != 700 {
		t.Fatalf("up/down = %d/%d, want 700/800", peers[0].Up, peers[0].Down)
	}
}

// An unreplied flow prints one counter, not two.
const unrepliedFixture = `ipv4     2 udp      17 20 src=192.168.0.10 dst=203.0.113.70 sport=41000 dport=8888 packets=3 bytes=180 [UNREPLIED] src=203.0.113.70 dst=192.168.0.10 sport=8888 dport=41000 packets=0 bytes=0 mark=0 use=1
`

func TestParseConntrackUnrepliedFlow(t *testing.T) {
	peers, err := parseConntrack(strings.NewReader(unrepliedFixture), netip.MustParseAddr("192.168.0.10"), nil)
	if err != nil {
		t.Fatalf("parseConntrack: %v", err)
	}
	if len(peers) != 1 {
		t.Fatalf("got %d peers, want 1", len(peers))
	}
	if peers[0].Up != 180 || peers[0].Down != 0 {
		t.Fatalf("up/down = %d/%d, want 180/0", peers[0].Up, peers[0].Down)
	}
}

// Two devices, one marked call each, plus marked DNS, an unmarked flow, a
// LAN-to-LAN flow and a flow belonging to the router itself.
const markedFixture = `ipv4     2 udp      17 30 src=192.168.0.10 dst=203.0.113.10 sport=51000 dport=3478 packets=4 bytes=800 src=203.0.113.10 dst=198.51.100.1 sport=3478 dport=51000 packets=4 bytes=1200 mark=2 use=1
ipv4     2 udp      17 30 src=192.168.0.10 dst=203.0.113.10 sport=51001 dport=50121 packets=40 bytes=8000 src=203.0.113.10 dst=198.51.100.1 sport=50121 dport=51001 packets=40 bytes=9000 mark=2 use=1
ipv4     2 udp      17 30 src=192.168.0.20 dst=203.0.113.20 sport=52000 dport=50200 packets=10 bytes=2000 src=203.0.113.20 dst=198.51.100.1 sport=50200 dport=52000 packets=10 bytes=3000 mark=2 use=1
ipv4     2 tcp      6 100 ESTABLISHED src=192.168.0.10 dst=203.0.113.30 sport=53000 dport=853 packets=3 bytes=300 src=203.0.113.30 dst=198.51.100.1 sport=853 dport=53000 packets=3 bytes=400 mark=2 use=1
ipv4     2 tcp      6 100 ESTABLISHED src=192.168.0.10 dst=203.0.113.40 sport=54000 dport=443 packets=9 bytes=90000 src=203.0.113.40 dst=198.51.100.1 sport=443 dport=54000 packets=9 bytes=90000 mark=0 use=1
ipv4     2 udp      17 30 src=192.168.0.10 dst=192.168.0.1 sport=55000 dport=53 packets=2 bytes=200 src=192.168.0.1 dst=192.168.0.10 sport=53 dport=55000 packets=2 bytes=400 mark=2 use=1
ipv4     2 tcp      6 60 TIME_WAIT src=198.51.100.1 dst=203.0.113.99 sport=51342 dport=853 packets=3 bytes=900 src=203.0.113.99 dst=198.51.100.1 sport=853 dport=51342 packets=3 bytes=1200 mark=2 use=1
`

func TestParseMarkedFlowsGroupsByConversation(t *testing.T) {
	lan := netip.MustParsePrefix("192.168.0.0/24")
	marked, err := parseMarkedFlows(strings.NewReader(markedFixture), lan, 2)
	if err != nil {
		t.Fatalf("parseMarkedFlows: %v", err)
	}
	// Three conversations: .10 with two peers (its two call flows to
	// 203.0.113.10 collapse into one) and .20 with one.
	if len(marked) != 3 {
		t.Fatalf("got %d conversations, want 3: %+v", len(marked), marked)
	}

	top := marked[0]
	if top.Device.String() != "192.168.0.10" || top.Peer.Addr.String() != "203.0.113.10" {
		t.Fatalf("heaviest = %s -> %s, want 192.168.0.10 -> 203.0.113.10", top.Device, top.Peer.Addr)
	}
	// 800+1200+8000+9000, the two flows summed rather than listed apart.
	if top.Peer.Bytes != 19000 {
		t.Fatalf("bytes = %d, want 19000 — the two flows of one call must be one row", top.Peer.Bytes)
	}
	if top.Peer.Up != 8800 || top.Peer.Down != 10200 {
		t.Fatalf("up/down = %d/%d, want 8800/10200", top.Peer.Up, top.Peer.Down)
	}
	if len(top.Peer.Ports) != 2 {
		t.Fatalf("ports = %+v, want both the media and the STUN port", top.Peer.Ports)
	}
}

func TestParseMarkedFlowsExcludesWhatIsNotOneDeviceOutbound(t *testing.T) {
	lan := netip.MustParsePrefix("192.168.0.0/24")
	marked, err := parseMarkedFlows(strings.NewReader(markedFixture), lan, 2)
	if err != nil {
		t.Fatalf("parseMarkedFlows: %v", err)
	}
	for _, conv := range marked {
		switch {
		case conv.Peer.Addr.String() == "203.0.113.40":
			t.Fatal("an unmarked flow was listed as prioritised")
		case conv.Peer.Addr.String() == "192.168.0.1":
			t.Fatal("a LAN-to-LAN flow was listed")
		case conv.Device.String() == "198.51.100.1":
			t.Fatal("the router's own flow was attributed to a device")
		}
	}
	// Marked DNS stays: it really is in the priority queue. The label, not the
	// membership, is what stops it reading as a call.
	var sawDNS bool
	for _, conv := range marked {
		if conv.Peer.Addr.String() == "203.0.113.30" {
			sawDNS = true
		}
	}
	if !sawDNS {
		t.Fatal("marked DoT was dropped; the list is meant to be everything prioritised")
	}
}

func TestParseMarkedFlowsWithoutAMarkCollectsNothing(t *testing.T) {
	lan := netip.MustParsePrefix("192.168.0.0/24")
	marked, err := parseMarkedFlows(strings.NewReader(markedFixture), lan, 0)
	if err != nil {
		t.Fatalf("parseMarkedFlows: %v", err)
	}
	if len(marked) != 0 {
		t.Fatalf("got %d conversations for an unconfigured mark, want 0", len(marked))
	}
}

func TestParseFlowLineReadsTheCountdownAndState(t *testing.T) {
	line := `ipv4     2 tcp      6 431876 ESTABLISHED src=192.168.0.10 dst=203.0.113.10 sport=42957 dport=443 packets=100 bytes=4000 src=203.0.113.10 dst=198.51.100.1 sport=443 dport=42957 packets=90 bytes=26000 [ASSURED] mark=0 use=1`
	f, ok := parseFlowLine(line)
	if !ok {
		t.Fatal("line did not parse")
	}
	if !f.HaveTimeout || f.Timeout != 431876 {
		t.Fatalf("timeout = %d (have=%v), want 431876", f.Timeout, f.HaveTimeout)
	}
	if f.State != "ESTABLISHED" {
		t.Fatalf("state = %q, want ESTABLISHED", f.State)
	}
	if !f.Assured {
		t.Fatal("[ASSURED] was not picked up")
	}
}

func TestParseFlowLineLeavesStateEmptyForStatelessProtocols(t *testing.T) {
	// udp has no state column, so the field after the countdown is already the
	// tuple. Reading it as a state would send timeoutSysctl looking for
	// nf_conntrack_udp_timeout_src=192.168.0.10.
	line := `ipv4     2 udp      17 30 src=192.168.0.10 dst=203.0.113.60 sport=5353 dport=53 packets=2 bytes=200 src=203.0.113.60 dst=192.168.0.10 sport=53 dport=5353 packets=2 bytes=400 mark=0 use=1`
	f, ok := parseFlowLine(line)
	if !ok {
		t.Fatal("line did not parse")
	}
	if f.State != "" {
		t.Fatalf("state = %q, want empty", f.State)
	}
	if !f.HaveTimeout || f.Timeout != 30 {
		t.Fatalf("timeout = %d (have=%v), want 30", f.Timeout, f.HaveTimeout)
	}
	if f.Assured {
		t.Fatal("a line without [ASSURED] was reported as assured")
	}
}

func TestParseFlowLineIgnoresFlagsWhenLookingForAState(t *testing.T) {
	// [UNREPLIED] sits between the two tuples, not where a state would be, but
	// a parser that only rejected fields containing "=" would still have to
	// cope if that ever changed.
	if isStateField("[UNREPLIED]") {
		t.Fatal("a bracketed flag was taken for a state")
	}
	if isStateField("src=1.2.3.4") {
		t.Fatal("a tuple field was taken for a state")
	}
	if !isStateField("TIME_WAIT") {
		t.Fatal("a real state was rejected")
	}
}

func TestProtocolAtReportsWhereItFoundTheName(t *testing.T) {
	fields := strings.Fields(`ipv4     2 tcp      6 431876 ESTABLISHED src=1.2.3.4`)
	name, idx := protocolAt(fields)
	if name != "tcp" || idx != 2 {
		t.Fatalf("protocolAt = (%q, %d), want (tcp, 2)", name, idx)
	}
	// The countdown and state are positional from there.
	if fields[idx+2] != "431876" || fields[idx+3] != "ESTABLISHED" {
		t.Fatalf("fields after the protocol: %q", fields[idx+1:idx+4])
	}

	if _, idx := protocolAt(strings.Fields("src=1.2.3.4 dst=5.6.7.8")); idx != -1 {
		t.Fatalf("a line with no protocol reported index %d, want -1", idx)
	}
}
