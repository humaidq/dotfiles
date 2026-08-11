package main

import (
	"net/netip"
	"testing"
)

func peerWith(marks []uint64, ports ...PortUse) Peer {
	peer := Peer{Addr: netip.MustParseAddr("203.0.113.1"), Ports: ports, Marks: map[uint64]struct{}{}}
	for _, mark := range marks {
		peer.Marks[mark] = struct{}{}
	}
	return peer
}

func use(proto string, port uint16, bytes uint64) PortUse {
	return PortUse{portKey: portKey{Proto: proto, Port: port}, Bytes: bytes}
}

func TestNamerLabelsFromHeaviestPort(t *testing.T) {
	n := namer{}
	// The label describes what the peer is mostly doing, not whatever port
	// happens to sort first alphabetically.
	got := n.describe(peerWith(nil, use("tcp", 443, 9000), use("udp", 443, 10)))
	if got.Label != "HTTPS" {
		t.Fatalf("label = %q, want HTTPS", got.Label)
	}
	if len(got.Ports) != 2 || got.Ports[0].Text != "tcp/443" {
		t.Fatalf("ports = %+v, want tcp/443 first", got.Ports)
	}
}

func TestNamerLeavesUnknownPortsUnlabelled(t *testing.T) {
	got := namer{}.describe(peerWith(nil, use("tcp", 889, 589000)))
	if got.Label != "" {
		t.Fatalf("label = %q, want empty: an unrecognised port must not be named", got.Label)
	}
	if len(got.Ports) != 1 || got.Ports[0].Text != "tcp/889" {
		t.Fatalf("ports = %+v, want tcp/889", got.Ports)
	}
}

func TestNamerFlagsSuspectPorts(t *testing.T) {
	n := namer{suspect: map[uint16]bool{889: true, 1943: true}}
	got := n.describe(peerWith(nil, use("tcp", 889, 500), use("tcp", 443, 100)))
	if !got.Ports[0].Suspect {
		t.Fatal("a blocklisted port was not flagged")
	}
	if got.Ports[1].Suspect {
		t.Fatal("an ordinary port was flagged")
	}
}

func TestNamerReportsCallOnMark(t *testing.T) {
	n := namer{callMark: 2}
	// Negotiated media ports carry no service name of their own; the mark is
	// the only thing that identifies the conversation.
	got := n.describe(peerWith([]uint64{2}, use("udp", 50121, 8000)))
	if got.Label != callLabel {
		t.Fatalf("label = %q, want %q", got.Label, callLabel)
	}
	// The mark also outranks a port name, since STUN on 3478 really is a call.
	got = n.describe(peerWith([]uint64{2}, use("udp", 3478, 8000)))
	if got.Label != callLabel {
		t.Fatalf("label = %q on a marked STUN peer, want %q", got.Label, callLabel)
	}
}

func TestNamerDoesNotCallDNSACall(t *testing.T) {
	// 53 and 853 are on the high-priority port list, so they carry the same
	// mark as a call without being one. Mislabelling them would discredit the
	// whole column.
	n := namer{callMark: 2}
	for _, tc := range []struct {
		port uint16
		want string
	}{{53, "DNS"}, {853, "DoT"}} {
		got := n.describe(peerWith([]uint64{2}, use("tcp", tc.port, 900)))
		if got.Label != tc.want {
			t.Fatalf("port %d labelled %q, want %q", tc.port, got.Label, tc.want)
		}
	}
}

func TestNamerIgnoresUnconfiguredMark(t *testing.T) {
	// callMark 0 means the environment did not supply one. A peer carrying any
	// mark must not then be reported as a call.
	got := namer{}.describe(peerWith([]uint64{2}, use("udp", 50121, 8000)))
	if got.Label != "" {
		t.Fatalf("label = %q with no configured mark, want empty", got.Label)
	}
}

func TestNamerCountsPortsBeyondTheShownFew(t *testing.T) {
	got := namer{}.describe(peerWith(nil,
		use("udp", 50121, 900), use("udp", 50122, 800),
		use("udp", 50123, 700), use("udp", 50124, 600)))
	if len(got.Ports) != portsShown {
		t.Fatalf("rendered %d ports, want %d", len(got.Ports), portsShown)
	}
	if got.More != 2 {
		t.Fatalf("More = %d, want 2 — a truncated list must say so", got.More)
	}
}

func TestNamerEmptyPeer(t *testing.T) {
	got := namer{}.describe(Peer{Addr: netip.MustParseAddr("203.0.113.1")})
	if got.Label != "" || len(got.Ports) != 0 || got.More != 0 {
		t.Fatalf("a peer with no recorded ports produced %+v, want an empty column", got)
	}
}

func TestNamerMarksCallForStyling(t *testing.T) {
	// The template styles on this flag rather than on the label text, so it has
	// to be set exactly when the label is the call marker and never otherwise.
	n := namer{callMark: 2}
	if got := n.describe(peerWith([]uint64{2}, use("udp", 50121, 10))); !got.Call {
		t.Fatal("a call was not flagged for styling")
	}
	if got := n.describe(peerWith(nil, use("tcp", 443, 10))); got.Call {
		t.Fatal("ordinary traffic was flagged as a call")
	}
	if got := n.describe(peerWith([]uint64{2}, use("tcp", 53, 10))); got.Call {
		t.Fatal("marked DNS was flagged as a call")
	}
}
