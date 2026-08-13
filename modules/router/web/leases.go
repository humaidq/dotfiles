package main

import (
	"bufio"
	"net/netip"
	"os"
	"sort"
	"strings"
)

// lease is one current DHCP lease, reduced to what the peers pages show.
type lease struct {
	Addr netip.Addr
	Name string
	// The hardware address dnsmasq handed the lease to. Carried because it is
	// what identifies a device to the low-trust pool, and the value someone
	// copies into the sops secret to make membership permanent — reading it off
	// the device page beats going to the router for it.
	//
	// Taken from the lease rather than the neighbour table on purpose: the
	// neighbour reader is nil unless the low-trust feature is enabled, so
	// sourcing it there would make the MAC vanish on a router that has the
	// feature off, for no reason a reader of the page could guess.
	MAC string
}

// readLeases parses a dnsmasq lease file into the devices currently on the LAN.
//
// Format is one lease per line: expiry, MAC, address, hostname, client id.
// dnsmasq writes "*" for a device that offered no hostname, which is rendered
// as an empty Name rather than passed through — "*" reads as a wildcard rather
// than as "unknown" to anyone looking at the page.
//
// Entries outside lanNet are dropped: the index links each one to a peers page
// whose own guard would reject them anyway, so listing them would only offer
// links that 404.
func readLeases(path string, lanNet netip.Prefix) ([]lease, error) {
	handle, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer handle.Close()

	seen := map[netip.Addr]lease{}
	scanner := bufio.NewScanner(handle)
	for scanner.Scan() {
		fields := strings.Fields(scanner.Text())
		if len(fields) < 4 {
			continue
		}
		addr, err := netip.ParseAddr(fields[2])
		if err != nil {
			continue
		}
		addr = addr.Unmap()
		if !lanNet.Contains(addr) {
			continue
		}
		name := fields[3]
		if name == "*" {
			name = ""
		}
		// A device that has renewed under a new name appears twice; the later
		// line wins, which is the one dnsmasq appended most recently.
		seen[addr] = lease{Addr: addr, Name: name, MAC: strings.ToLower(fields[1])}
	}
	if err := scanner.Err(); err != nil {
		return nil, err
	}

	leases := make([]lease, 0, len(seen))
	for _, entry := range seen {
		leases = append(leases, entry)
	}
	sort.Slice(leases, func(i, j int) bool {
		return leases[i].Addr.Less(leases[j].Addr)
	})
	return leases, nil
}
