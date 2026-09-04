package main

import (
	"bufio"
	"io"
	"log"
	"net/netip"
	"os"
	"strings"
	"sync"
)

// reservation is one entry of dnsmasq's dhcp-hostsfile: a name an operator
// pinned to a device, and the address pinned with it.
//
// This file exists because the lease file is not the whole of what the router
// knows about a device, and it is wrong about exactly the devices someone took
// the trouble to name. A reservation written with an `infinite` lease time
// tells the client never to renew; once the timed lease it held before the
// reservation was added expires, dnsmasq drops the line and nothing ever writes
// it back. The device keeps its address and goes on passing traffic, while its
// page renders an em-dash for a name and — worse — an em-dash for the MAC,
// which is the one value that page's MAC exists to hand over.
type reservation struct {
	MAC  string
	Addr netip.Addr
	Name string
}

// reservations is the reservation file indexed for lookup. The zero value is
// usable and answers every lookup with "unknown", which is what a router with
// no reservation file configured, or one this service cannot read, gets.
type reservations struct {
	byMAC  map[string]reservation
	byAddr map[netip.Addr]reservation
}

// name returns the reserved hostname for a device.
//
// The MAC is authoritative when there is one, and deliberately does not fall
// through to the address on a miss: a reservation states MAC -> address, so
// reading it backwards would put a name on whichever device happens to hold the
// address now. dnsmasq keeps reserved addresses for their own client, but "kept
// for" is not "never handed out", and a wrong name on this page is worse than
// none — it is the name someone would act on.
//
// The address lookup is for the case where nothing knows a MAC at all: the
// kernel has evicted the neighbour entry and there is no lease either.
func (r reservations) name(mac string, addr netip.Addr) string {
	if mac != "" {
		return r.byMAC[strings.ToLower(mac)].Name
	}
	return r.byAddr[addr].Name
}

// reservationFile reads the dhcp-hostsfile on demand. A nil receiver is usable
// and reads nothing, which is what main.go leaves when no path is configured.
type reservationFile struct {
	path string
	// A read failure here is logged once rather than per render. The failure
	// that actually happens is a permission one — the file is a sops secret and
	// this service runs under DynamicUser — and it does not fix itself, so
	// logging it every time someone loads the page would bury the journal in a
	// line that says nothing new.
	warnOnce sync.Once
}

func newReservationFile(path string) *reservationFile {
	path = strings.TrimSpace(path)
	if path == "" {
		return nil
	}
	return &reservationFile{path: path}
}

func (f *reservationFile) load() reservations {
	if f == nil {
		return reservations{}
	}
	handle, err := os.Open(f.path)
	if err != nil {
		f.warnOnce.Do(func() {
			log.Printf("peers: read DHCP reservations from %q: %v", f.path, err)
		})
		return reservations{}
	}
	defer handle.Close()
	return parseReservations(handle)
}

// parseReservations reads dnsmasq's dhcp-hostsfile format: comma-separated
// fields, in any order, of which only three are of interest here —
//
//	[<hwaddr>...][,id:<client_id>|*][,set:<tag>][,tag:<tag>][,<ipaddr>][,<hostname>][,<lease_time>][,ignore]
//
// Everything else is skipped rather than rejected, and a line that yields no
// name is dropped rather than treated as an error. This reader is not the
// authority on the file — dnsmasq is, and it fails loudly on its own — so the
// only thing a field it does not recognise should cost is that one field.
func parseReservations(r io.Reader) reservations {
	out := reservations{byMAC: map[string]reservation{}, byAddr: map[netip.Addr]reservation{}}
	scanner := bufio.NewScanner(r)
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		var macs []string
		entry := reservation{}
		for _, field := range strings.Split(line, ",") {
			field = strings.TrimSpace(field)
			switch {
			case field == "" || field == "*" || field == "ignore":
			case strings.HasPrefix(field, "id:"),
				strings.HasPrefix(field, "set:"),
				strings.HasPrefix(field, "tag:"):
			case isMACAddr(field):
				// More than one is legal and means "any of these", so each is
				// indexed at the same name.
				macs = append(macs, strings.ToLower(field))
			case isLeaseTime(field):
			default:
				// IPv6 is written in brackets here, unlike everywhere else in
				// dnsmasq's config.
				if addr, err := netip.ParseAddr(strings.Trim(field, "[]")); err == nil {
					entry.Addr = addr.Unmap()
					continue
				}
				// First one wins: dnsmasq takes a single hostname, so a second
				// bare word is something this reader does not understand and
				// must not overwrite a good name with.
				if entry.Name == "" {
					entry.Name = field
				}
			}
		}
		if entry.Name == "" {
			continue
		}
		for _, mac := range macs {
			out.byMAC[mac] = reservation{MAC: mac, Addr: entry.Addr, Name: entry.Name}
		}
		if entry.Addr.IsValid() {
			if len(macs) > 0 {
				entry.MAC = macs[0]
			}
			out.byAddr[entry.Addr] = entry
		}
	}
	if err := scanner.Err(); err != nil {
		// Deliberately partial: what was parsed before the read failed is still
		// correct, and returning nothing instead would take the names off every
		// device at once over a short read of one line.
		log.Printf("peers: read DHCP reservations: %v", err)
	}
	return out
}

// isMACAddr accepts the six-group hex form and nothing else.
//
// dnsmasq also accepts wildcards (`11:22:33:*:*:*`), which name a class of
// device rather than one device. Those are rejected here on purpose: this
// reader's whole output is a name to print beside one address, and a name that
// matched a whole vendor prefix would be a claim the file never made.
func isMACAddr(s string) bool {
	groups := strings.Split(s, ":")
	if len(groups) != 6 {
		return false
	}
	for _, group := range groups {
		if len(group) == 0 || len(group) > 2 {
			return false
		}
		for _, char := range group {
			switch {
			case char >= '0' && char <= '9',
				char >= 'a' && char <= 'f',
				char >= 'A' && char <= 'F':
			default:
				return false
			}
		}
	}
	return true
}

// isLeaseTime accepts what dnsmasq accepts in the lease-time field, so that a
// bare `infinite` or `45m` is not mistaken for the hostname.
func isLeaseTime(s string) bool {
	if s == "infinite" || s == "deprecated" {
		return true
	}
	digits := strings.TrimRight(s, "smhdw")
	if digits == "" || len(s)-len(digits) > 1 {
		return false
	}
	for _, char := range digits {
		if char < '0' || char > '9' {
			return false
		}
	}
	return true
}
