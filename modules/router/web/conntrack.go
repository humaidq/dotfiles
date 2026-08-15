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
	"time"
)

// Peer is one address the inspected device currently holds flows with.
type Peer struct {
	Addr    netip.Addr
	Bytes   uint64
	Packets uint64
	// Bytes each way, from the device's point of view: Up is what the device
	// sent. Exact rather than inferred — conntrack keeps a counter per tuple
	// and prints both — which is why they are split here and not guessed from
	// port numbers.
	Up   uint64
	Down uint64
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
	// How long ago this peer last carried a packet, and whether that could be
	// worked out at all. Taken as the freshest of the peer's flows, because the
	// question the page asks is whether the peer is still live — one flow with
	// a packet a second ago says yes no matter how stale the rest are.
	//
	// This is what separates a conversation still in progress from the long
	// tail of TCP entries the kernel keeps for five days after the last byte.
	// Both look identical by byte count, which is the only other thing the
	// table offers.
	Idle     time.Duration
	HaveIdle bool
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

// flow is one conntrack line reduced to the fields this package uses.
//
// Two readers consume these — the per-device peer list and the LAN-wide
// prioritised list — and they parse identically on purpose: a line format this
// program only half understands is exactly the kind of thing that would give
// two pages quietly different answers about the same connection.
type flow struct {
	Proto string
	// The original tuple's endpoints. The reply tuple is deliberately not
	// kept: its destination is the router's WAN address after NAT, so it says
	// nothing about who is talking to whom.
	Src, Dst netip.Addr
	SPort    uint16
	DPort    uint16
	HavePort bool
	Bytes    uint64
	Packets  uint64
	Mark     uint64
	// Bytes in each tuple, original first. Which one is upload depends on who
	// opened the flow, which is why they are kept apart until a caller says
	// which end it is looking from. An unreplied flow leaves Reply at zero.
	Orig, Reply uint64
	// Seconds left on this entry's conntrack timeout. The kernel resets it to
	// the per-state maximum on every packet and counts it down otherwise, so
	// the gap between the two is how long the flow has been silent — the only
	// thing in the dump that dates a flow at all.
	Timeout     uint64
	HaveTimeout bool
	// The l4 state, for the protocols conntrack prints one for: "ESTABLISHED",
	// "TIME_WAIT" and so on. Empty for udp and icmp, which have no state field.
	State string
	// Whether the line carried [ASSURED]. Only consulted for udp, where it is
	// what decides which of the kernel's two udp timeouts is counting down.
	Assured bool
}

// The flag conntrack prints once traffic has been seen in both directions.
const assuredFlag = "[ASSURED]"

// parseFlowLine reads one `conntrack -L -o extended` line. The second result is
// false for a line carrying no usable flow — a header, a blank, or one whose
// counters are absent because accounting is off.
func parseFlowLine(line string) (flow, bool) {
	fields := strings.Fields(line)

	var f flow
	var addrs []netip.Addr
	var sports, dports []uint16
	var counts []uint64

	for _, token := range fields {
		key, value, found := strings.Cut(token, "=")
		if !found {
			if token == assuredFlag {
				f.Assured = true
			}
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
				f.Bytes += parsed
				counts = append(counts, parsed)
			}
		case "packets":
			if parsed, err := strconv.ParseUint(value, 10, 64); err == nil {
				f.Packets += parsed
			}
		case "mark":
			if parsed, err := strconv.ParseUint(value, 10, 64); err == nil {
				f.Mark = parsed
			}
		}
	}

	if len(addrs) < 2 || f.Bytes == 0 {
		return flow{}, false
	}
	f.Src, f.Dst = addrs[0], addrs[1]
	if len(sports) > 0 && len(dports) > 0 {
		f.SPort, f.DPort, f.HavePort = sports[0], dports[0], true
	}
	f.Orig, f.Reply = at(counts, 0), at(counts, 1)

	// conntrack prints "<l3> <l3num> <l4> <l4num> <timeout> [<state>]", so both
	// of these are positional — but positional relative to the protocol name
	// rather than to the start of the line, for the same reason protocolAt
	// scans for that name instead of indexing to it.
	name, idx := protocolAt(fields)
	f.Proto = name
	if idx >= 0 {
		if idx+2 < len(fields) {
			if parsed, err := strconv.ParseUint(fields[idx+2], 10, 64); err == nil {
				f.Timeout, f.HaveTimeout = parsed, true
			}
		}
		// Only the protocols with a state have a field here; for the rest the
		// next field is already the tuple, which the "=" rules out.
		if idx+3 < len(fields) && isStateField(fields[idx+3]) {
			f.State = fields[idx+3]
		}
	}
	return f, true
}

// isStateField reports whether a field is an l4 state name rather than the
// start of the tuple or a flag. Rejecting both forms rather than matching a
// list of state names keeps sctp's and dccp's states working without this
// package having to enumerate them.
func isStateField(field string) bool {
	return field != "" && !strings.Contains(field, "=") && !strings.HasPrefix(field, "[")
}

// view is one flow seen from one end of it: who the far end is, which port
// names the service, and which way the bytes went. False when the given
// address is not an end of this flow.
type view struct {
	Peer     netip.Addr
	Port     portKey
	HavePort bool
	Up, Down uint64
}

func (f flow) from(local netip.Addr) (view, bool) {
	var v view
	switch {
	case f.Src == local:
		// The local end opened this flow: the service is what it dialled, and
		// the original direction is upload.
		v.Peer, v.Port = f.Dst, portKey{Proto: f.Proto, Port: f.DPort}
		v.Up, v.Down = f.Orig, f.Reply
	case f.Dst == local:
		// Opened towards the local end, so both are the other way round.
		v.Peer, v.Port = f.Src, portKey{Proto: f.Proto, Port: f.SPort}
		v.Down, v.Up = f.Orig, f.Reply
	default:
		return view{}, false
	}
	// A flow with no ports (icmp, gre) or an unrecognised protocol still
	// counts its bytes; it just contributes no port. Inventing port 0 would
	// sort and render as though it were a real service.
	v.HavePort = f.HavePort && f.Proto != ""
	return v, true
}

// parseConntrack aggregates flows into per-peer totals for one device.
//
// A flow counts when exactly one end is the device; the other end is the peer.
// Non-public peers are dropped, which removes router-originated and
// LAN-to-LAN traffic without needing a separate rule for either.
//
// timeouts may be nil, in which case no peer gets an idle time. That is the
// only impurity this parser has, and it is passed in rather than read here so
// the aggregation stays testable against a fixture alone.
func parseConntrack(r io.Reader, device netip.Addr, timeouts *timeoutTable) ([]Peer, error) {
	totals := map[netip.Addr]*Peer{}
	// Per-peer port totals, kept beside the peers rather than on them because
	// they are accumulated by key and only ordered at the end.
	ports := map[netip.Addr]map[portKey]uint64{}

	err := eachFlow(r, func(f flow) {
		v, ok := f.from(device)
		if !ok || !isPublicAddr(v.Peer) {
			return
		}

		entry := totals[v.Peer]
		if entry == nil {
			entry = &Peer{Addr: v.Peer, Marks: map[uint64]struct{}{}}
			totals[v.Peer] = entry
			ports[v.Peer] = map[portKey]uint64{}
		}
		entry.Bytes += f.Bytes
		entry.Packets += f.Packets
		entry.Up += v.Up
		entry.Down += v.Down
		if f.Mark != 0 {
			entry.Marks[f.Mark] = struct{}{}
		}
		// The freshest flow wins. A peer is as live as its liveliest
		// conversation, and taking the maximum — or an average — would let a
		// browser's pile of five-day-old TCP entries bury the one socket that
		// is still moving bytes.
		if idle, ok := timeouts.idle(f); ok && (!entry.HaveIdle || idle < entry.Idle) {
			entry.Idle, entry.HaveIdle = idle, true
		}
		if v.HavePort {
			ports[v.Peer][v.Port] += f.Bytes
		}
	})
	if err != nil {
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

// MarkedFlow is one LAN device's conversation with one peer, carrying a
// particular conntrack mark. The unit is the conversation rather than the flow
// because a single call is several flows — the ICE negotiation and the media
// that follows it — and listing them separately would report one call as four.
type MarkedFlow struct {
	Device netip.Addr
	Peer   Peer
}

// parseMarkedFlows collects every conversation on the LAN carrying the given
// conntrack mark, grouped by device and peer.
//
// The LAN-wide counterpart of parseConntrack: same line parsing, same
// attribution, but keyed on the mark instead of on one device. Used for the
// prioritised list on the devices page, which answers "what is the router
// treating as a call right now" without having to open each device in turn.
func parseMarkedFlows(r io.Reader, lanNet netip.Prefix, mark uint64) ([]MarkedFlow, error) {
	if mark == 0 {
		return nil, nil
	}

	type convKey struct{ device, peer netip.Addr }
	totals := map[convKey]*Peer{}
	ports := map[convKey]map[portKey]uint64{}
	order := []convKey{}

	err := eachFlow(r, func(f flow) {
		if f.Mark != mark {
			return
		}
		// Whichever end is on the LAN is the device. A flow with both ends on
		// the LAN, or neither, is not one device talking to the internet and
		// is skipped — the same reasoning as the public-address filter below.
		var device netip.Addr
		switch {
		case lanNet.Contains(f.Src) && !lanNet.Contains(f.Dst):
			device = f.Src
		case lanNet.Contains(f.Dst) && !lanNet.Contains(f.Src):
			device = f.Dst
		default:
			return
		}
		v, ok := f.from(device)
		if !ok || !isPublicAddr(v.Peer) {
			return
		}

		key := convKey{device: device, peer: v.Peer}
		entry := totals[key]
		if entry == nil {
			entry = &Peer{Addr: v.Peer, Marks: map[uint64]struct{}{}}
			totals[key] = entry
			ports[key] = map[portKey]uint64{}
			order = append(order, key)
		}
		entry.Bytes += f.Bytes
		entry.Packets += f.Packets
		entry.Up += v.Up
		entry.Down += v.Down
		entry.Marks[f.Mark] = struct{}{}
		if v.HavePort {
			ports[key][v.Port] += f.Bytes
		}
	})
	if err != nil {
		return nil, err
	}

	marked := make([]MarkedFlow, 0, len(order))
	for _, key := range order {
		entry := totals[key]
		entry.Ports = orderPorts(ports[key])
		marked = append(marked, MarkedFlow{Device: key.device, Peer: *entry})
	}
	sort.Slice(marked, func(i, j int) bool {
		if marked[i].Peer.Bytes != marked[j].Peer.Bytes {
			return marked[i].Peer.Bytes > marked[j].Peer.Bytes
		}
		if marked[i].Device != marked[j].Device {
			return marked[i].Device.Less(marked[j].Device)
		}
		return marked[i].Peer.Addr.Less(marked[j].Peer.Addr)
	})
	return marked, nil
}

// eachFlow calls fn for every usable line of a conntrack dump.
func eachFlow(r io.Reader, fn func(flow)) error {
	scanner := bufio.NewScanner(r)
	scanner.Buffer(make([]byte, 0, 64*1024), 1024*1024)
	for scanner.Scan() {
		if f, ok := parseFlowLine(scanner.Text()); ok {
			fn(f)
		}
	}
	return scanner.Err()
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

// at returns values[i], or zero when the line carried fewer counters than that
// — an unreplied flow prints only the original direction.
func at(values []uint64, i int) uint64 {
	if i < len(values) {
		return values[i]
	}
	return 0
}

// protocolAt returns the l4 protocol name from a conntrack line and the index
// of the field holding it, or ("", -1). The index is what lets the caller reach
// the timeout and state fields that follow it.
func protocolAt(fields []string) (string, int) {
	for i, field := range fields {
		if strings.Contains(field, "=") {
			// Reached the key=value part of the line without finding one.
			return "", -1
		}
		if knownProtocols[field] {
			return field, i
		}
	}
	return "", -1
}

// protocolField returns the l4 protocol name from a conntrack line, or "".
func protocolField(fields []string) string {
	name, _ := protocolAt(fields)
	return name
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
