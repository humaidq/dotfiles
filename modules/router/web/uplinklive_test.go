package main

import (
	"net"
	"testing"
	"time"
)

// An end-to-end check of the raw-socket path: a real socket, a real checksum,
// a real reply, and the IPv4 header Linux prepends on receive. Everything else
// about the prober is exercised against synthetic packets, so this is the only
// test that would catch a checksum or header-stripping mistake — the failure
// mode of which is silence, not an error.
//
// Skipped without CAP_NET_RAW, which means it does not run in an ordinary
// `go test` or under `nix flake check`. It does run on a router, where the
// service already holds that capability:
//
//	go test -c && sudo setcap cap_net_raw+ep ./router-web.test && ./router-web.test -test.run Live -test.v
func TestLiveEchoAgainstLoopback(t *testing.T) {
	conn, err := net.ListenPacket("ip4:icmp", "0.0.0.0")
	if err != nil {
		t.Skipf("needs CAP_NET_RAW: %v", err)
	}
	defer conn.Close()

	const (
		id  = 0x4242
		seq = 99
	)
	if _, err := conn.WriteTo(echoRequest(id, seq), &net.IPAddr{IP: net.IPv4(127, 0, 0, 1)}); err != nil {
		t.Fatalf("write: %v", err)
	}

	if err := conn.SetReadDeadline(time.Now().Add(3 * time.Second)); err != nil {
		t.Fatalf("set deadline: %v", err)
	}

	buffer := make([]byte, 1500)
	for {
		n, _, err := conn.ReadFrom(buffer)
		if err != nil {
			t.Fatalf("no reply to a packet the kernel should have echoed: %v", err)
		}

		// The socket sees every ICMP packet on the host, including other
		// processes' pings, which is exactly what the id filter is for.
		gotID, gotSeq, ok := parseEchoReply(buffer[:n])
		if !ok || gotID != id {
			continue
		}
		if gotSeq != seq {
			t.Fatalf("seq = %d, want %d", gotSeq, seq)
		}
		return
	}
}
