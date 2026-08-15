package main

import (
	"context"
	"net/netip"
	"os/exec"
	"strings"
	"sync"
	"time"
)

// The kernel's neighbour table, and what makes a device on this LAN one thing
// rather than several.
//
// A device is a MAC. Its IPv4 address comes from a DHCP lease and is stable for
// the lease time; its IPv6 addresses come from SLAAC, are configured by the
// device without telling anyone, and there are usually several of them at once
// — a stable-privacy address, one or more temporary ones, and a link-local.
// Nothing hands those out, so nothing has a record of them: the lease file is
// DHCPv4 only and there is no DHCPv6 server here at all.
//
// The neighbour table is the only place the two halves meet. It is also the
// only source that notices an address changing hands, which is why the
// low-trust lookup already used it before any of this.
//
// Deliberately NOT solved by configuring an IPv6 LAN prefix and testing
// containment the way the IPv4 side does. The prefix is delegated by the ISP
// and changes on every redial, so a configured value would be wrong within a
// day; and containment answers "is this address on my LAN", where the question
// here is the stricter "is this address THIS device".

// neighbour is one entry of the table: an address and the MAC holding it.
// Entries with no lladdr — FAILED, INCOMPLETE — are not neighbours for this
// purpose and never appear.
type neighbour struct {
	Addr netip.Addr
	MAC  string
}

// readNeighbours returns a reader for the table, scoped to the LAN interface.
//
// Scoped, unlike the IPv4-only call this replaces, because an unscoped table
// also holds the ISP's gateway on ppp0 and the mesh peers on sifr0. Those were
// harmless while the only question asked of the table was "what MAC holds this
// known-LAN address", and stop being harmless the moment the table is also used
// to decide which addresses are devices.
func readNeighbours(iface string) func(context.Context) ([]byte, error) {
	return func(ctx context.Context) ([]byte, error) {
		// Both families: the whole point is to see a device's v4 and v6
		// addresses at once, so the -4 that used to be here is gone.
		return exec.CommandContext(ctx, "ip", "neigh", "show", "dev", iface).Output()
	}
}

// parseNeighbours reads `ip neigh show` output.
//
// Each line is "<addr> dev <iface> lladdr <mac> <state...>", with the fields
// after the address optional and reordered between iproute2 versions — a
// router entry carries an extra "router" word, a proxy entry carries "proxy" —
// so both values are found by name rather than by position.
func parseNeighbours(raw []byte) []neighbour {
	var found []neighbour
	for _, line := range strings.Split(string(raw), "\n") {
		fields := strings.Fields(line)
		if len(fields) == 0 {
			continue
		}
		addr, err := netip.ParseAddr(fields[0])
		if err != nil {
			continue
		}
		mac := ""
		for i, field := range fields {
			if field == "lladdr" && i+1 < len(fields) {
				mac = strings.ToLower(fields[i+1])
				break
			}
		}
		if mac == "" {
			continue
		}
		found = append(found, neighbour{Addr: addr.Unmap(), MAC: mac})
	}
	return found
}

// macForDevice finds the MAC currently holding an address, or "".
//
// Returning "" for an address with no usable entry rather than an error lets
// the caller skip the lookups that depend on it instead of asking them about
// an empty MAC.
func macForDevice(raw []byte, device netip.Addr) string {
	device = device.Unmap()
	for _, entry := range parseNeighbours(raw) {
		if entry.Addr == device {
			return entry.MAC
		}
	}
	return ""
}

// addressesForMAC returns every address the table shows this MAC holding.
//
// This is what merges a device's two families onto one page. A phone with a
// DHCP lease and three SLAAC addresses comes back as four addresses, and its
// conversations over any of them belong to the same device.
//
// Link-local addresses are included, and that is not an oversight: a device
// resolving names talks to the router's link-local address from its own, and on
// a quiet device that DNS traffic may be the only evidence it is awake. Nothing
// downstream can mistake one for an internet peer — isPublicAddr rejects the
// whole fe80::/10 range on the peer side of every flow.
func addressesForMAC(raw []byte, mac string) []netip.Addr {
	if mac == "" {
		return nil
	}
	mac = strings.ToLower(mac)
	var found []netip.Addr
	for _, entry := range parseNeighbours(raw) {
		if entry.MAC == mac {
			found = append(found, entry.Addr)
		}
	}
	return found
}

// addrSet is the set of addresses one device currently holds. It is what the
// connection-table readers match a flow's ends against, in place of the single
// address they took before.
type addrSet map[netip.Addr]struct{}

func newAddrSet(addrs ...netip.Addr) addrSet {
	set := make(addrSet, len(addrs))
	for _, addr := range addrs {
		if addr.IsValid() {
			set[addr.Unmap()] = struct{}{}
		}
	}
	return set
}

func (s addrSet) has(addr netip.Addr) bool {
	if len(s) == 0 {
		return false
	}
	_, ok := s[addr.Unmap()]
	return ok
}

func (s addrSet) add(addrs ...netip.Addr) {
	for _, addr := range addrs {
		if addr.IsValid() {
			s[addr.Unmap()] = struct{}{}
		}
	}
}

// neighbourCache keeps the raw table for a few seconds.
//
// Two things in one request need it — the guard that decides whether a URL
// names a device on this LAN, and the render that merges that device's address
// families — and the devices index needs it once more for every row. Reading it
// three times would be three forks of ip(8) per page, and worse, three views of
// a table that changes underneath them, so a device could pass the guard and
// then not exist.
//
// The TTL is seconds rather than the shaping cache's half-minute. This table is
// the fast-moving one: a device waking up gets an entry immediately and a quiet
// one is evicted within minutes, and both of those are things the page is read
// to find out.
type neighbourCache struct {
	mu     sync.Mutex
	ttl    time.Duration
	raw    []byte
	loaded time.Time
	read   func(context.Context) ([]byte, error)
}

func newNeighbourCache(read func(context.Context) ([]byte, error)) *neighbourCache {
	return &neighbourCache{ttl: 5 * time.Second, read: read}
}

// get returns the table, or nil if it cannot be read. Nil is a usable answer
// everywhere it lands: no MAC, no extra addresses, no device outside the DHCP
// range — which is exactly the behaviour this page had before it read the table
// at all.
func (c *neighbourCache) get(ctx context.Context) []byte {
	if c == nil || c.read == nil {
		return nil
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.raw != nil && time.Since(c.loaded) < c.ttl {
		return c.raw
	}
	raw, err := c.read(ctx)
	if err != nil {
		return nil
	}
	c.raw, c.loaded = raw, time.Now()
	return c.raw
}
