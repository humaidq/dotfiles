package main

import (
	"bufio"
	"net/netip"
	"os"
	"sort"
	"strings"
)

// Where a peer address actually is, as opposed to where the network that holds
// it is registered.
//
// The two are different answers and the page needs the first one. ip2asn's
// country column — the only one available before this — is the registration,
// so every anycast CDN prefix in it reads US no matter which of the operator's
// sites answers you. Fastly's 2a04:4e42:80::158 is the case that prompted this:
// registered US, physically the Dubai POP, and a page reporting US for it is
// telling an operator on this network that a local CDN node is in America.
//
// The table is built from MaxMind's GeoLite2 Country CSV by geoip-convert.py,
// which is also where the choice between MaxMind's two country columns is made
// and explained. It is NOT checked into the repository the way
// ip2asn-combined.tsv is: GeoLite2 is not redistributable, so each router
// fetches it with a licence key from sops and converts it in place.

// GeoTable holds v4 and v6 ranges separately, each sorted by start address, so
// a lookup is a binary search rather than a scan of ~600k rows. Same shape as
// ASNTable, and deliberately so — the converter emits the same three-column
// layout precisely so this reader could stay this small.
type GeoTable struct {
	v4 []geoRange
	v6 []geoRange
}

type geoRange struct {
	start netip.Addr
	end   netip.Addr
	// The ISO 3166-1 alpha-2 code, held as bytes rather than a string. At
	// 600k rows a string header is 16 bytes against the two the code actually
	// needs, and the table is resident for the life of the process on a box
	// that is also running a resolver, a shaper and a packet capture.
	code [2]byte
}

// LoadGeoTable reads a converted GeoLite2 country table.
//
// Malformed rows are skipped rather than failing the load, for the reason
// LoadASNTable gives: this is third-party data reshaped by a script, and one
// bad line should not cost the whole table.
func LoadGeoTable(path string) (*GeoTable, error) {
	handle, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer handle.Close()

	table := &GeoTable{}
	scanner := bufio.NewScanner(handle)
	scanner.Buffer(make([]byte, 0, 64*1024), 1024*1024)
	for scanner.Scan() {
		fields := strings.Split(scanner.Text(), "\t")
		if len(fields) < 3 {
			continue
		}
		start, err := netip.ParseAddr(fields[0])
		if err != nil {
			continue
		}
		end, err := netip.ParseAddr(fields[1])
		if err != nil {
			continue
		}
		code := strings.TrimSpace(fields[2])
		if len(code) != 2 {
			continue
		}
		entry := geoRange{start: start, end: end}
		entry.code[0], entry.code[1] = code[0], code[1]
		if start.Is4() {
			table.v4 = append(table.v4, entry)
		} else {
			table.v6 = append(table.v6, entry)
		}
	}
	if err := scanner.Err(); err != nil {
		return nil, err
	}

	// The converter emits sorted output, but sorting here too costs one pass
	// over an already-ordered slice and removes the binary search's dependence
	// on a promise made in another language in another file.
	for _, ranges := range [][]geoRange{table.v4, table.v6} {
		sort.Slice(ranges, func(i, j int) bool {
			return ranges[i].start.Less(ranges[j].start)
		})
	}
	return table, nil
}

// Lookup returns the ISO country code for an address, or "" if the table does
// not place it.
//
// A nil table answers "" rather than panicking, which is what a router with no
// downloaded database yet does — the column simply stays empty, exactly as it
// did before this file existed.
func (t *GeoTable) Lookup(addr netip.Addr) (string, bool) {
	if t == nil {
		return "", false
	}
	addr = addr.Unmap()
	ranges := t.v6
	if addr.Is4() {
		ranges = t.v4
	}
	// First range whose start is greater than addr; the candidate is the one
	// before it.
	index := sort.Search(len(ranges), func(i int) bool {
		return addr.Less(ranges[i].start)
	})
	if index == 0 {
		return "", false
	}
	candidate := ranges[index-1]
	if addr.Less(candidate.start) || candidate.end.Less(addr) {
		return "", false
	}
	return string(candidate.code[:]), true
}
