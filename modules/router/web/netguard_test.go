package main

import (
	"net/netip"
	"testing"
)

func TestIsPublicAddr(t *testing.T) {
	cases := []struct {
		addr string
		want bool
	}{
		{"203.0.113.10", true},
		{"198.51.100.1", true},
		{"2001:db8::1", true},
		{"192.168.0.10", false},
		{"10.10.0.18", false},
		{"10.20.0.1", false},
		{"172.16.5.4", false},
		{"127.0.0.1", false},
		{"169.254.1.1", false},
		{"224.0.0.1", false},
		{"0.0.0.0", false},
		{"::1", false},
		{"fe80::1", false},
		{"fc00::1", false},
		{"100.64.0.1", false},
		{"100.127.255.254", false},
		{"255.255.255.255", false},
		{"100.63.255.255", true},
		{"100.128.0.1", true},
	}
	for _, tc := range cases {
		t.Run(tc.addr, func(t *testing.T) {
			if got := isPublicAddr(netip.MustParseAddr(tc.addr)); got != tc.want {
				t.Fatalf("isPublicAddr(%s) = %v, want %v", tc.addr, got, tc.want)
			}
		})
	}
}

func TestIsPublicAddrRejectsInvalid(t *testing.T) {
	if isPublicAddr(netip.Addr{}) {
		t.Fatal("zero Addr accepted")
	}
}
