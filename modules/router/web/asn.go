package main

import (
	"bufio"
	"net/netip"
	"os"
	"sort"
	"strconv"
	"strings"
)

// ASNInfo is the attribution shown next to a peer.
type ASNInfo struct {
	Number  uint32
	Org     string
	Country string
}

type asnRange struct {
	start netip.Addr
	end   netip.Addr
	info  ASNInfo
}

// ASNTable holds v4 and v6 ranges separately, each sorted by start address so
// a lookup is a binary search rather than a scan of ~688k rows.
type ASNTable struct {
	v4 []asnRange
	v6 []asnRange
}

// LoadASNTable reads an ip2asn-combined.tsv. Malformed rows are skipped rather
// than failing the load: the file is third-party data and one bad line should
// not cost the whole table.
func LoadASNTable(path string) (*ASNTable, error) {
	handle, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer handle.Close()

	table := &ASNTable{}
	scanner := bufio.NewScanner(handle)
	scanner.Buffer(make([]byte, 0, 64*1024), 1024*1024)
	for scanner.Scan() {
		fields := strings.Split(scanner.Text(), "\t")
		if len(fields) < 5 {
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
		number, err := strconv.ParseUint(fields[2], 10, 32)
		if err != nil {
			continue
		}
		entry := asnRange{
			start: start,
			end:   end,
			info: ASNInfo{
				Number:  uint32(number),
				Org:     fields[4],
				Country: fields[3],
			},
		}
		if start.Is4() {
			table.v4 = append(table.v4, entry)
		} else {
			table.v6 = append(table.v6, entry)
		}
	}
	if err := scanner.Err(); err != nil {
		return nil, err
	}

	sortRanges(table.v4)
	sortRanges(table.v6)
	return table, nil
}

func sortRanges(ranges []asnRange) {
	sort.Slice(ranges, func(i, j int) bool {
		return ranges[i].start.Less(ranges[j].start)
	})
}

// Lookup returns the ASN covering addr. A nil table always misses, which is
// what makes a missing data file degrade to "ASN unknown" rather than crash.
func (t *ASNTable) Lookup(addr netip.Addr) (ASNInfo, bool) {
	if t == nil {
		return ASNInfo{}, false
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
		return ASNInfo{}, false
	}
	candidate := ranges[index-1]
	if addr.Less(candidate.start) || candidate.end.Less(addr) {
		return ASNInfo{}, false
	}
	return candidate.info, true
}
