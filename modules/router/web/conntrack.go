package main

import (
	"bufio"
	"context"
	"io"
	"net/netip"
	"os/exec"
	"sort"
	"strconv"
	"strings"
)

// Peer is one address the inspected device currently holds flows with.
type Peer struct {
	Addr    netip.Addr
	Bytes   uint64
	Packets uint64
}

// readConntrack dumps the live connection table. Requires CAP_NET_ADMIN and
// net.netfilter.nf_conntrack_acct=1 for the byte counters to be present.
func readConntrack(ctx context.Context) ([]byte, error) {
	return exec.CommandContext(ctx, "conntrack", "-L", "-o", "extended").Output()
}

// parseConntrack aggregates flows into per-peer totals for one device.
//
// Each line repeats src/dst/packets/bytes once per direction. A flow counts
// when exactly one end is the device; the other end is the peer. Non-public
// peers are dropped, which removes router-originated and LAN-to-LAN traffic
// without needing a separate rule for either.
func parseConntrack(r io.Reader, device netip.Addr) ([]Peer, error) {
	totals := map[netip.Addr]*Peer{}

	scanner := bufio.NewScanner(r)
	scanner.Buffer(make([]byte, 0, 64*1024), 1024*1024)
	for scanner.Scan() {
		var addrs []netip.Addr
		var bytes, packets uint64
		for _, token := range strings.Fields(scanner.Text()) {
			key, value, found := strings.Cut(token, "=")
			if !found {
				continue
			}
			switch key {
			case "src", "dst":
				if addr, err := netip.ParseAddr(value); err == nil {
					addrs = append(addrs, addr.Unmap())
				}
			case "bytes":
				if parsed, err := strconv.ParseUint(value, 10, 64); err == nil {
					bytes += parsed
				}
			case "packets":
				if parsed, err := strconv.ParseUint(value, 10, 64); err == nil {
					packets += parsed
				}
			}
		}
		if len(addrs) < 2 || bytes == 0 {
			continue
		}

		// addrs[0] and addrs[1] are the original tuple's src and dst. Later
		// pairs are the reply tuple, whose destination is the router's WAN
		// address after NAT and therefore not useful for attribution.
		src, dst := addrs[0], addrs[1]
		var peer netip.Addr
		switch {
		case src == device:
			peer = dst
		case dst == device:
			peer = src
		default:
			continue
		}
		if !isPublicAddr(peer) {
			continue
		}

		entry := totals[peer]
		if entry == nil {
			entry = &Peer{Addr: peer}
			totals[peer] = entry
		}
		entry.Bytes += bytes
		entry.Packets += packets
	}
	if err := scanner.Err(); err != nil {
		return nil, err
	}

	peers := make([]Peer, 0, len(totals))
	for _, entry := range totals {
		peers = append(peers, *entry)
	}
	sort.Slice(peers, func(i, j int) bool {
		if peers[i].Bytes != peers[j].Bytes {
			return peers[i].Bytes > peers[j].Bytes
		}
		return peers[i].Addr.Less(peers[j].Addr)
	})
	return peers, nil
}
