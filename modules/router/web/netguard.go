package main

import "net/netip"

// isPublicAddr reports whether addr is a globally routable unicast address.
//
// The mesh needs no rule of its own: 10.10.0.0/24 is inside 10.0.0.0/8 and is
// already refused as private. Without this guard a crafted POST could throttle
// the router itself or another device on the LAN.
func isPublicAddr(addr netip.Addr) bool {
	if !addr.IsValid() {
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
	return true
}
