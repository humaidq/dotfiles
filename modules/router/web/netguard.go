package main

import "net/netip"

// Carrier-grade NAT (RFC 6598). netip's IsPrivate covers RFC1918 and RFC4193
// only, so this range has to be named explicitly. It is not globally routable,
// which means it can never legitimately be an internet peer.
var cgnatRange = netip.MustParsePrefix("100.64.0.0/10")

// isPublicAddr reports whether addr is a globally routable unicast address.
//
// The mesh needs no rule of its own: 10.10.0.0/24 is inside 10.0.0.0/8 and is
// already refused as private. Without this guard a crafted POST could throttle
// the router itself or another device on the LAN.
func isPublicAddr(addr netip.Addr) bool {
	if !addr.IsValid() {
		return false
	}
	// A zone identifier scopes an address to a local link, so it can never
	// belong to an internet peer. It is also unbounded attacker-controlled
	// text that survives into String(), which is a log-forgery vector.
	if addr.Zone() != "" {
		return false
	}
	addr = addr.Unmap()
	switch {
	case addr.IsPrivate(),
		addr.IsLoopback(),
		addr.IsLinkLocalUnicast(),
		addr.IsLinkLocalMulticast(),
		addr.IsMulticast(),
		addr.IsUnspecified(),
		addr.IsInterfaceLocalMulticast():
		return false
	}
	if cgnatRange.Contains(addr) {
		return false
	}
	if addr.Is4() && addr == netip.AddrFrom4([4]byte{255, 255, 255, 255}) {
		return false
	}
	return true
}
