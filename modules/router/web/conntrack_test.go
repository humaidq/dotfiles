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
	peers, err := parseConntrack(strings.NewReader(conntrackFixture), netip.MustParseAddr("192.168.0.10"))
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
	peers, err := parseConntrack(strings.NewReader(conntrackFixture), netip.MustParseAddr("192.168.0.10"))
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
	peers, err := parseConntrack(strings.NewReader(conntrackFixture), netip.MustParseAddr("192.168.0.77"))
	if err != nil {
		t.Fatalf("parseConntrack: %v", err)
	}
	if len(peers) != 0 {
		t.Fatalf("got %d peers for an idle device, want 0", len(peers))
	}
}

func TestParseConntrackRecordsServicePorts(t *testing.T) {
	peers, err := parseConntrack(strings.NewReader(conntrackFixture), netip.MustParseAddr("192.168.0.10"))
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
	peers, err := parseConntrack(strings.NewReader(inboundFixture), netip.MustParseAddr("192.168.0.10"))
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
