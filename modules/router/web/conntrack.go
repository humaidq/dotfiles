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
	// Service ports carried with this peer, heaviest first. "Service" means
	// the far end's port: the destination port on a flow the device opened,
	// the source port on one opened towards it. The device's own ephemeral
	// port is not recorded, since it says nothing about what is being spoken.
	Ports []PortUse
	// The distinct conntrack marks seen on flows with this peer. The parser
	// records them without interpreting them — which mark means what is the
	// qos-mark chain's business, and is configured, so it is the caller that
	// knows. See HasMark.
	Marks map[uint64]struct{}
}

// HasMark reports whether any flow with this peer carried the given conntrack
// mark. Used for the router's high-priority mark, which qos-mark sets partly
// from the STUN magic cookie in the payload — the one signal available here
// that is evidence about content rather than about port numbers.
func (p Peer) HasMark(mark uint64) bool {
	if mark == 0 {
		return false
	}
	_, ok := p.Marks[mark]
	return ok
}

// PortUse is one protocol and service port seen with a peer, and how much of
// the peer's traffic went over it.
type PortUse struct {
	portKey
	Bytes uint64
}

// portKey is the identity half of a PortUse, split out so it can be a map key
// without the byte count — which changes — being part of what identifies it.
type portKey struct {
	Proto string
	Port  uint16
}

// String renders the form used on the page and in logs, e.g. "tcp/443".
func (p portKey) String() string {
	return p.Proto + "/" + strconv.FormatUint(uint64(p.Port), 10)
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
	// Per-peer port totals, kept beside the peers rather than on them because
	// they are accumulated by key and only ordered at the end.
	ports := map[netip.Addr]map[portKey]uint64{}

	scanner := bufio.NewScanner(r)
	scanner.Buffer(make([]byte, 0, 64*1024), 1024*1024)
	for scanner.Scan() {
		fields := strings.Fields(scanner.Text())
		var addrs []netip.Addr
		var sports, dports []uint16
		var bytes, packets, mark uint64
		for _, token := range fields {
			key, value, found := strings.Cut(token, "=")
			if !found {
				continue
			}
			switch key {
			case "src", "dst":
				if addr, err := netip.ParseAddr(value); err == nil {
					addrs = append(addrs, addr.Unmap())
				}
			case "sport", "dport":
				parsed, err := strconv.ParseUint(value, 10, 16)
				if err != nil {
					continue
				}
				if key == "sport" {
					sports = append(sports, uint16(parsed))
				} else {
					dports = append(dports, uint16(parsed))
				}
			case "bytes":
				if parsed, err := strconv.ParseUint(value, 10, 64); err == nil {
					bytes += parsed
				}
			case "packets":
				if parsed, err := strconv.ParseUint(value, 10, 64); err == nil {
					packets += parsed
				}
			case "mark":
				if parsed, err := strconv.ParseUint(value, 10, 64); err == nil {
					mark = parsed
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
		// The far end's port, which is the one that names a service. Taken
		// from the same original tuple as the addresses above and by the same
		// logic: on a flow the device opened it is the destination port, on
		// one opened towards the device it is the source port.
		var service uint16
		var haveService bool
		switch {
		case src == device:
			peer = dst
			if len(dports) > 0 {
				service, haveService = dports[0], true
			}
		case dst == device:
			peer = src
			if len(sports) > 0 {
				service, haveService = sports[0], true
			}
		default:
			continue
		}
		if !isPublicAddr(peer) {
			continue
		}

		entry := totals[peer]
		if entry == nil {
			entry = &Peer{Addr: peer, Marks: map[uint64]struct{}{}}
			totals[peer] = entry
			ports[peer] = map[portKey]uint64{}
		}
		entry.Bytes += bytes
		entry.Packets += packets

		if mark != 0 {
			entry.Marks[mark] = struct{}{}
		}

		// Protocol name, which conntrack prints as a bare token rather than a
		// key=value pair: "ipv4 2 tcp 6 ...". Anything else on the line is
		// skipped by the loop above, so it has to be taken positionally.
		// A line too short to hold one, or one whose ports are absent (icmp,
		// gre), contributes bytes to the peer and no port — deliberately, since
		// inventing port 0 would sort as a real service.
		if proto := protocolField(fields); proto != "" && haveService {
			ports[peer][portKey{Proto: proto, Port: service}] += bytes
		}
	}
	if err := scanner.Err(); err != nil {
		return nil, err
	}

	peers := make([]Peer, 0, len(totals))
	for _, entry := range totals {
		entry.Ports = orderPorts(ports[entry.Addr])
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

// knownProtocols are the l4 protocol names conntrack prints. Matched against a
// list rather than taken from a fixed field index because the field before the
// protocol name is a number in every format conntrack emits, and a positional
// read would silently start reporting timeouts as protocols if that ever
// changed. Anything unrecognised yields no port for the flow, which is the
// honest answer.
var knownProtocols = map[string]bool{
	"tcp": true, "udp": true, "udplite": true, "sctp": true, "dccp": true,
	"icmp": true, "icmpv6": true, "gre": true, "unknown": true,
}

// protocolField returns the l4 protocol name from a conntrack line, or "".
func protocolField(fields []string) string {
	for _, field := range fields {
		if strings.Contains(field, "=") {
			// Reached the key=value part of the line without finding one.
			return ""
		}
		if knownProtocols[field] {
			return field
		}
	}
	return ""
}

// orderPorts flattens the per-peer port totals, heaviest first, with the port
// number breaking ties so the output is stable between renders of an idle
// device.
func orderPorts(totals map[portKey]uint64) []PortUse {
	if len(totals) == 0 {
		return nil
	}
	ordered := make([]PortUse, 0, len(totals))
	for key, bytes := range totals {
		ordered = append(ordered, PortUse{portKey: key, Bytes: bytes})
	}
	sort.Slice(ordered, func(i, j int) bool {
		if ordered[i].Bytes != ordered[j].Bytes {
			return ordered[i].Bytes > ordered[j].Bytes
		}
		if ordered[i].Port != ordered[j].Port {
			return ordered[i].Port < ordered[j].Port
		}
		return ordered[i].Proto < ordered[j].Proto
	})
	return ordered
}
