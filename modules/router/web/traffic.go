package main

import (
	"os"
	"strconv"
	"strings"
)

// What a peer's traffic looks like, as far as the connection table can say.
//
// The honest scope of this whole file: conntrack knows the protocol, the
// service port and the router's own conntrack mark. It does not see payload.
// So a label here names the port's conventional service and nothing stronger —
// "HTTPS" means tcp/443, not that the bytes are really HTTP over TLS. The one
// exception is the call marker, which comes from the qos-mark chain matching
// the STUN magic cookie in the payload, and is therefore evidence about
// content. Ports are always rendered alongside the label so the operator can
// disagree with it.
type traffic struct {
	Label string
	// Whether Label is the call marker rather than a port name. Carried as its
	// own field so the template can style it differently without matching on
	// the label text, and so a future label containing a slash or a space
	// cannot become a broken CSS class.
	Call  bool
	Ports []portChip
	// How many further ports were seen beyond the ones in Ports. Rendered as
	// "+N" rather than dropped silently, because a peer spraying twenty ports
	// is itself the finding.
	More int
}

// portChip is one rendered port, and whether it is one the router already
// treats as a tunnel transport.
type portChip struct {
	Text    string
	Suspect bool
}

// portsShown bounds the chips per row. Two covers the overwhelmingly common
// case (a service port, sometimes a second) and keeps the column from wrapping
// on a peer holding many flows.
const portsShown = 2

// serviceLabels names a protocol and port. Deliberately short: every entry is
// either something this LAN actually carries or something the blocklists are
// built around, and a name that is merely plausible is worse than no name,
// because the port beside it can be read directly.
var serviceLabels = map[portKey]string{
	{"tcp", 80}:    "HTTP",
	{"tcp", 443}:   "HTTPS",
	{"udp", 443}:   "QUIC",
	{"tcp", 53}:    "DNS",
	{"udp", 53}:    "DNS",
	{"tcp", 853}:   "DoT",
	{"udp", 853}:   "DoQ",
	{"udp", 8853}:  "DoQ",
	{"udp", 123}:   "NTP",
	{"tcp", 22}:    "SSH",
	{"udp", 3478}:  "STUN/TURN",
	{"tcp", 3478}:  "STUN/TURN",
	{"udp", 5349}:  "STUN/TURN",
	{"tcp", 5349}:  "STUN/TURN",
	{"tcp", 5228}:  "FCM push",
	{"tcp", 5223}:  "APNs push",
	{"udp", 500}:   "IPsec",
	{"udp", 4500}:  "IPsec",
	{"udp", 51820}: "WireGuard",
	{"tcp", 1194}:  "OpenVPN",
	{"udp", 1194}:  "OpenVPN",
	{"tcp", 6881}:  "BitTorrent",
	{"udp", 6881}:  "BitTorrent",
	{"tcp", 51413}: "BitTorrent",
	{"udp", 51413}: "BitTorrent",
	{"tcp", 25}:    "SMTP",
	{"tcp", 465}:   "SMTP",
	{"tcp", 587}:   "SMTP",
	{"tcp", 993}:   "IMAP",
}

// callLabel is what a peer gets when the router's high-priority mark fired on
// it. Not a port name: the mark comes from the STUN signature, which is what
// ICE negotiation looks like regardless of which ports were negotiated.
const callLabel = "call"

// notCall are labels that must survive the mark. The high-priority mark is set
// both by the STUN payload match and by the configured high-priority port list,
// which on these routers is 53 and 853 — so a DNS flow is marked without being
// remotely call-like, and reporting it as a call would discredit the column.
var notCall = map[string]bool{"DNS": true, "DoT": true, "DoQ": true}

// namer turns a peer's ports and marks into the traffic column. Its zero value
// works and simply never flags a port or reports a call, which is what the
// tests and any router without the environment set get.
type namer struct {
	// Ports the router drops LAN->WAN, from custom-port-blocklist.txt. Flagged
	// rather than named: the whole point of that file is that these carry a
	// proprietary protocol nobody has identified, so inventing a service name
	// would be a lie. Worth flagging even though the forward path is closed,
	// because a peer still holding flows on one is either reaching it another
	// way or trying repeatedly.
	suspect map[uint16]bool
	// The conntrack mark qos-mark sets on high-priority conversations, i.e.
	// sifr.router.qos.highPriorityMark. Zero disables the call marker.
	callMark uint64
}

// newNamerFromEnv reads the configuration web.nix passes in. Both values are
// optional: absent means that half of the column is simply quieter.
func newNamerFromEnv() namer {
	var n namer
	if raw := os.Getenv("ROUTER_SUSPECT_PORTS"); raw != "" {
		n.suspect = map[uint16]bool{}
		for _, field := range strings.Split(raw, ",") {
			port, err := strconv.ParseUint(strings.TrimSpace(field), 10, 16)
			if err != nil {
				continue
			}
			n.suspect[uint16(port)] = true
		}
	}
	if raw := os.Getenv("ROUTER_CALL_MARK"); raw != "" {
		if mark, err := strconv.ParseUint(strings.TrimSpace(raw), 10, 64); err == nil {
			n.callMark = mark
		}
	}
	return n
}

// describe builds the traffic column for one peer.
func (n namer) describe(peer Peer) traffic {
	var out traffic

	for i, use := range peer.Ports {
		if i >= portsShown {
			out.More = len(peer.Ports) - portsShown
			break
		}
		out.Ports = append(out.Ports, portChip{
			Text:    use.String(),
			Suspect: n.suspect[use.Port],
		})
	}

	// The label describes the heaviest port, since that is what the peer is
	// mostly doing. A peer whose bulk is HTTPS and whose tail is one STUN
	// packet is not a call.
	if len(peer.Ports) > 0 {
		out.Label = serviceLabels[peer.Ports[0].portKey]
	}
	if peer.HasMark(n.callMark) && !notCall[out.Label] {
		out.Label, out.Call = callLabel, true
	}
	return out
}
