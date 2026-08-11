package main

import (
	"context"
	"errors"
	"html/template"
	"net/http"
	"net/http/httptest"
	"net/netip"
	"strings"
	"testing"
)

var errFake = errors.New("conntrack unavailable")

func testPeersServer(t *testing.T) *peersServer {
	t.Helper()
	tmpl, err := template.New("peers.html").Parse(
		`{{.Device}}|{{range .Peers}}{{.Addr}},{{.ASN}},{{.Org}},{{.Country}},{{.SharePct}};{{end}}|{{.Error}}`)
	if err != nil {
		t.Fatalf("parse template: %v", err)
	}
	table, err := LoadASNTable(writeTSV(t,
		"203.0.113.0\t203.0.113.255\t64496\tNL\tExample Hosting\n"))
	if err != nil {
		t.Fatalf("LoadASNTable: %v", err)
	}
	server := newPeersServer(netip.MustParsePrefix("192.168.0.0/24"), table, tmpl)
	server.conntrack = func(context.Context) ([]byte, error) {
		return []byte(conntrackFixture), nil
	}
	server.runTool = func(string, ...string) (string, error) { return "ok", nil }
	return server
}

func TestPeersPageListsPeersWithASN(t *testing.T) {
	rec := httptest.NewRecorder()
	testPeersServer(t).mux().ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/peers/192.168.0.10", nil))

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200", rec.Code)
	}
	body := rec.Body.String()
	if !strings.Contains(body, "203.0.113.10,64496,Example Hosting,NL,") {
		t.Fatalf("peer row with ASN attribution missing from body: %q", body)
	}
	// 30800 of 35800 total bytes = 86.0%.
	if !strings.Contains(body, "86.0") {
		t.Fatalf("top-peer share missing from body: %q", body)
	}
}

func TestPeersPageRejectsAddressOutsideLAN(t *testing.T) {
	rec := httptest.NewRecorder()
	testPeersServer(t).mux().ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/peers/203.0.113.10", nil))
	if rec.Code != http.StatusNotFound {
		t.Fatalf("status = %d, want 404", rec.Code)
	}
}

func TestPeersPageRejectsUnparseableAddress(t *testing.T) {
	rec := httptest.NewRecorder()
	testPeersServer(t).mux().ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/peers/not-an-ip", nil))
	if rec.Code != http.StatusNotFound {
		t.Fatalf("status = %d, want 404", rec.Code)
	}
}

func TestPeersPageErrorsWhenConntrackFails(t *testing.T) {
	server := testPeersServer(t)
	server.conntrack = func(context.Context) ([]byte, error) { return nil, errFake }
	rec := httptest.NewRecorder()
	server.mux().ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/peers/192.168.0.10", nil))
	if rec.Code != http.StatusInternalServerError {
		t.Fatalf("status = %d, want 500 — an unreadable table must not look like an idle device", rec.Code)
	}
}
