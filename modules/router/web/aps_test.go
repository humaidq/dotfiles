package main

import (
	"encoding/base64"
	"encoding/json"
	"html/template"
	"io"
	"net/http"
	"net/http/httptest"
	"net/netip"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestParseAccessPointsReadsNameAndAddress(t *testing.T) {
	points, err := parseAccessPoints("# the list\n\nfirst,10.20.0.160\nground , 10.20.0.163 # by the stairs\n")
	if err != nil {
		t.Fatalf("parseAccessPoints: %v", err)
	}
	if len(points) != 2 {
		t.Fatalf("got %d access points, want 2", len(points))
	}
	if points[0].Name != "first" || points[0].Addr != netip.MustParseAddr("10.20.0.160") {
		t.Errorf("first entry = %+v", points[0])
	}
	// Order is the file's order: the page lists them the way they were written
	// down.
	if points[1].Name != "ground" || points[1].Addr != netip.MustParseAddr("10.20.0.163") {
		t.Errorf("second entry = %+v", points[1])
	}
}

// A malformed line disables the whole list rather than being skipped. An AP
// missing from the page reads as an AP that is fine, which is the failure this
// feature exists to prevent.
func TestParseAccessPointsRejectsMalformed(t *testing.T) {
	for name, raw := range map[string]string{
		"no comma":     "first 10.20.0.160\n",
		"no address":   "first,\n",
		"no name":      ",10.20.0.160\n",
		"not an ip":    "first,unifi-first.example\n",
		"ipv6":         "first,2001:db8::1\n",
		"duplicate":    "first,10.20.0.160\nfirst,10.20.0.161\n",
		"empty":        "",
		"only comment": "# nothing here\n",
	} {
		t.Run(name, func(t *testing.T) {
			if _, err := parseAccessPoints(raw); err == nil {
				t.Fatalf("parseAccessPoints(%q) succeeded, want an error", raw)
			}
		})
	}
}

func TestAPStateClassifies(t *testing.T) {
	const ceiling = 10 * time.Millisecond

	tests := []struct {
		name      string
		sample    apSample
		sawLarge  bool
		wantState string
		wantText  string
	}{
		{
			name:      "nothing answers",
			sample:    apSample{Sent: 5},
			wantState: stateDown,
			wantText:  "off",
		},
		{
			name:      "clean and fast is healthy",
			sample:    apSample{Sent: 5, Received: 5, Large: 2 * time.Millisecond, LargeOK: true},
			wantState: stateOK,
			wantText:  "healthy",
		},
		{
			name:      "one lost probe is degraded",
			sample:    apSample{Sent: 5, Received: 4, Large: 2 * time.Millisecond, LargeOK: true},
			wantState: stateDegraded,
			wantText:  "degraded",
		},
		{
			// 11.6 ms is what a 100 Mbit-linked AP actually measured; the
			// gigabit ones answered in about 2 ms.
			name:      "slow large probe is degraded",
			sample:    apSample{Sent: 5, Received: 5, Large: 11600 * time.Microsecond, LargeOK: true},
			wantState: stateDegraded,
			wantText:  "degraded",
		},
		{
			// An AP that has never answered a large probe is judged on the
			// small ones alone, so a device that refuses oversized pings does
			// not sit permanently amber.
			name:      "large probe never answered is not held against it",
			sample:    apSample{Sent: 5, Received: 5},
			sawLarge:  false,
			wantState: stateOK,
			wantText:  "healthy",
		},
		{
			// But one that used to answer them and has stopped is a path that
			// has started dropping fragments.
			name:      "large probe stopped answering is degraded",
			sample:    apSample{Sent: 5, Received: 5},
			sawLarge:  true,
			wantState: stateDegraded,
			wantText:  "degraded",
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			state, text := apState(test.sample, test.sawLarge, ceiling)
			if state != test.wantState || text != test.wantText {
				t.Errorf("apState(%+v, sawLarge=%v) = %q/%q, want %q/%q",
					test.sample, test.sawLarge, state, text, test.wantState, test.wantText)
			}
		})
	}
}

// The ceiling is the round trip a 65000-byte echo cannot beat over a 100 Mbit
// link. Asserted here so that a future edit to the constant has to argue with
// the arithmetic rather than just move a number.
func TestGigabitCeilingIsBelowTheHundredMegFloor(t *testing.T) {
	bits := float64(apLargeProbeBytes) * 8
	floor := time.Duration(2 * bits / 100e6 * float64(time.Second))
	if apGigabitCeiling >= floor {
		t.Errorf("apGigabitCeiling %v is not below the 100 Mbit round-trip floor %v; "+
			"a 100 Mbit link would be classed healthy", apGigabitCeiling, floor)
	}
}

func TestMonitorReportsUnknownBeforeFirstCycle(t *testing.T) {
	monitor := newAPMonitor([]accessPoint{
		{Name: "first", Addr: netip.MustParseAddr("10.20.0.160")},
	}, func(netip.Addr) apSample { return apSample{} })

	reports := monitor.reports()
	if len(reports) != 1 {
		t.Fatalf("got %d reports, want 1", len(reports))
	}
	if reports[0].State != stateUnknown {
		t.Errorf("state before the first cycle = %q, want %q", reports[0].State, stateUnknown)
	}
}

// sawLarge is remembered across cycles, not just within one.
func TestMonitorRemembersLargeProbeSuccess(t *testing.T) {
	answers := []apSample{
		{Sent: 5, Received: 5, Large: 2 * time.Millisecond, LargeOK: true},
		{Sent: 5, Received: 5},
	}
	call := 0
	monitor := newAPMonitor([]accessPoint{
		{Name: "first", Addr: netip.MustParseAddr("10.20.0.160")},
	}, func(netip.Addr) apSample {
		sample := answers[call]
		call++
		return sample
	})

	monitor.cycle()
	if got := monitor.reports()[0].State; got != stateOK {
		t.Fatalf("first cycle state = %q, want %q", got, stateOK)
	}

	monitor.cycle()
	if got := monitor.reports()[0].State; got != stateDegraded {
		t.Errorf("second cycle state = %q, want %q — the earlier large reply should "+
			"make its absence count", got, stateDegraded)
	}
}

func TestMonitorKeepsConfiguredOrder(t *testing.T) {
	monitor := newAPMonitor([]accessPoint{
		{Name: "roof", Addr: netip.MustParseAddr("10.20.0.161")},
		{Name: "first", Addr: netip.MustParseAddr("10.20.0.160")},
	}, func(netip.Addr) apSample { return apSample{Sent: 5, Received: 5} })

	monitor.cycle()
	reports := monitor.reports()
	if reports[0].Name != "roof" || reports[1].Name != "first" {
		t.Errorf("order = %q, %q; want the configured order", reports[0].Name, reports[1].Name)
	}
}

func TestEchoRequestSizedCarriesThePayload(t *testing.T) {
	packet := echoRequestSized(0x1234, 7, apLargeProbeBytes)
	if len(packet) != 8+apLargeProbeBytes {
		t.Fatalf("packet is %d bytes, want %d", len(packet), 8+apLargeProbeBytes)
	}
	id, seq, ok := parseEchoReply(append([]byte{0}, packet[1:]...))
	if !ok || id != 0x1234 || seq != 7 {
		t.Errorf("round trip = %#x/%d ok=%v, want 0x1234/7", id, seq, ok)
	}
	// The whole message, header included, sums to zero when the checksum is
	// right.
	if sum := internetChecksum(packet); sum != 0 {
		t.Errorf("checksum over the built packet = %#x, want 0", sum)
	}
}

// The section is absent entirely on a router with no list configured, rather
// than rendering an empty heading.
func TestStatusPageOmitsAccessPointsWhenUnset(t *testing.T) {
	tmpl := template.Must(template.ParseFiles("index.html", "nav.html"))
	recorder := httptest.NewRecorder()
	landingMux(pageData{}, tmpl, nil, nil, navSource{}).ServeHTTP(
		recorder, httptest.NewRequest(http.MethodGet, "/", nil))

	if body := recorder.Body.String(); strings.Contains(body, "Access Points") {
		t.Error("the access points section rendered with no list configured")
	}
}

func TestStatusPageRendersAccessPoints(t *testing.T) {
	tmpl := template.Must(template.ParseFiles("index.html", "nav.html"))
	monitor := newAPMonitor([]accessPoint{
		{Name: "first", Addr: netip.MustParseAddr("10.20.0.160")},
		{Name: "ground", Addr: netip.MustParseAddr("10.20.0.163")},
	}, func(addr netip.Addr) apSample {
		if addr == netip.MustParseAddr("10.20.0.163") {
			return apSample{Sent: 5}
		}
		return apSample{Sent: 5, Received: 5, Large: 2 * time.Millisecond, LargeOK: true}
	})
	monitor.cycle()

	recorder := httptest.NewRecorder()
	landingMux(pageData{}, tmpl, nil, monitor, navSource{}).ServeHTTP(
		recorder, httptest.NewRequest(http.MethodGet, "/", nil))

	body := recorder.Body.String()
	for _, want := range []string{"Access Points", "first", "ground", "healthy", "off", "lamp-ok", "lamp-down"} {
		if !strings.Contains(body, want) {
			t.Errorf("status page is missing %q", want)
		}
	}
}

// The four-field form carries a login; the two-field form does not. Both are
// valid, and a three-field line is not: it is ambiguous about which half of the
// login was left off.
func TestParseAccessPointsCredentials(t *testing.T) {
	points, err := parseAccessPoints(
		"lamp-only,10.20.0.160\nwith-login,10.20.0.161,admin,s3cret\n")
	if err != nil {
		t.Fatalf("parseAccessPoints: %v", err)
	}
	if points[0].canReboot() {
		t.Error("a two-field AP should carry no login")
	}
	if !points[1].canReboot() || points[1].Username != "admin" || points[1].Password != "s3cret" {
		t.Errorf("four-field AP = %+v, want admin/s3cret", points[1])
	}
	for name, raw := range map[string]string{
		"three fields":   "with-login,10.20.0.161,admin\n",
		"empty username": "with-login,10.20.0.161,,s3cret\n",
		"empty password": "with-login,10.20.0.161,admin,\n",
		"bad address":    "with-login,nope,admin,s3cret\n",
	} {
		t.Run("rejects "+name, func(t *testing.T) {
			if _, err := parseAccessPoints(raw); err == nil {
				t.Fatalf("parseAccessPoints(%q) succeeded, want an error", raw)
			}
		})
	}
}

// A nil monitor answers the feature question rather than panicking, so the mux
// and the template can ask it before a monitor exists. A monitor whose APs
// carry no login is off even with a reboot function wired.
func TestCanRebootNilAndDisabled(t *testing.T) {
	var nilMonitor *apMonitor
	if nilMonitor.canReboot() {
		t.Error("a nil monitor reports it can reboot")
	}
	// Reboot function wired, but the one AP has no login.
	lampOnly := newAPMonitor([]accessPoint{
		{Name: "first", Addr: netip.MustParseAddr("10.20.0.160")},
	}, func(netip.Addr) apSample { return apSample{} })
	lampOnly.reboot = func(accessPoint) error { return nil }
	if lampOnly.canReboot() {
		t.Error("a monitor whose APs have no login reports it can reboot")
	}
	// An AP with a login but no reboot function wired is also off.
	noFunc := newAPMonitor([]accessPoint{
		{Name: "first", Addr: netip.MustParseAddr("10.20.0.160"), Username: "admin", Password: "x"},
	}, func(netip.Addr) apSample { return apSample{} })
	if noFunc.canReboot() {
		t.Error("a monitor with no reboot function reports it can reboot")
	}
}

func TestRebootByNameResolvesAP(t *testing.T) {
	var got accessPoint
	monitor := newAPMonitor([]accessPoint{
		{Name: "first", Addr: netip.MustParseAddr("10.20.0.160"), Username: "admin", Password: "pw1"},
		{Name: "ground", Addr: netip.MustParseAddr("10.20.0.163"), Username: "admin", Password: "pw2"},
		{Name: "lamp-only", Addr: netip.MustParseAddr("10.20.0.164")},
	}, func(netip.Addr) apSample { return apSample{} })
	monitor.reboot = func(p accessPoint) error {
		got = p
		return nil
	}

	if err := monitor.rebootByName("ground"); err != nil {
		t.Fatalf("rebootByName: %v", err)
	}
	// The name is resolved against the configured list, not trusted off the
	// wire: "ground" reaches ground's address and its own login.
	if got.Addr != netip.MustParseAddr("10.20.0.163") || got.Password != "pw2" {
		t.Errorf("rebooted %+v, want ground with its own login", got)
	}

	if err := monitor.rebootByName("nowhere"); err != errUnknownAP {
		t.Errorf("rebootByName(unknown) = %v, want errUnknownAP", err)
	}
	// An AP that exists but was listed without a login is not rebootable.
	if err := monitor.rebootByName("lamp-only"); err != errNoRebootCreds {
		t.Errorf("rebootByName(lamp-only) = %v, want errNoRebootCreds", err)
	}
}

func TestHandleReboot(t *testing.T) {
	newMonitor := func(reboot func(accessPoint) error) *apMonitor {
		m := newAPMonitor([]accessPoint{
			{Name: "first", Addr: netip.MustParseAddr("10.20.0.160"), Username: "admin", Password: "pw"},
		}, func(netip.Addr) apSample { return apSample{} })
		m.reboot = reboot
		return m
	}
	post := func() *http.Request {
		req := httptest.NewRequest(http.MethodPost, "/ap/reboot", strings.NewReader("ap=first"))
		req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
		return req
	}

	t.Run("success redirects to the status page", func(t *testing.T) {
		called := false
		monitor := newMonitor(func(accessPoint) error {
			called = true
			return nil
		})
		rec := httptest.NewRecorder()
		monitor.handleReboot(rec, post())
		if rec.Code != http.StatusSeeOther {
			t.Fatalf("status = %d, want %d", rec.Code, http.StatusSeeOther)
		}
		if !called {
			t.Error("the reboot was not issued")
		}
		if loc := rec.Header().Get("Location"); loc != "/" {
			t.Errorf("redirect to %q, want /", loc)
		}
	})

	t.Run("unknown AP is 404", func(t *testing.T) {
		monitor := newMonitor(func(accessPoint) error { return nil })
		req := httptest.NewRequest(http.MethodPost, "/ap/reboot", strings.NewReader("ap=nowhere"))
		req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
		rec := httptest.NewRecorder()
		monitor.handleReboot(rec, req)
		if rec.Code != http.StatusNotFound {
			t.Errorf("status = %d, want 404", rec.Code)
		}
	})

	// The AP not answering is a bad gateway, not a 500: the failure is upstream
	// of this service, which is the first thing worth knowing when nothing
	// happened.
	t.Run("reboot failure is 502", func(t *testing.T) {
		monitor := newMonitor(func(accessPoint) error { return io.ErrUnexpectedEOF })
		rec := httptest.NewRecorder()
		monitor.handleReboot(rec, post())
		if rec.Code != http.StatusBadGateway {
			t.Errorf("status = %d, want 502", rec.Code)
		}
	})

	// The same origin guard the other mutations use: a reboot power-cycles a
	// device and must not be reachable from a cross-site page.
	t.Run("cross-site is refused", func(t *testing.T) {
		called := false
		monitor := newMonitor(func(accessPoint) error {
			called = true
			return nil
		})
		req := post()
		req.Header.Set("Sec-Fetch-Site", "cross-site")
		rec := httptest.NewRecorder()
		monitor.handleReboot(rec, req)
		if rec.Code != http.StatusForbidden {
			t.Errorf("status = %d, want 403", rec.Code)
		}
		if called {
			t.Error("a cross-site request reached the reboot")
		}
	})
}

// The reboot button and its route go together and appear on BOTH listeners —
// the AP reboot is the one mutation the LAN page carries — but only for an AP
// that was listed with a login. With no login there is no button and the route
// is a 404 on either listener.
func TestRebootButtonAndRouteGatedTogether(t *testing.T) {
	tmpl := template.Must(template.ParseFiles("index.html", "nav.html"))
	indexTmpl := template.Must(template.ParseFiles("index.html", "nav.html"))
	withCreds := []accessPoint{
		{Name: "first", Addr: netip.MustParseAddr("10.20.0.160"), Username: "admin", Password: "pw"},
	}
	lampOnly := []accessPoint{{Name: "first", Addr: netip.MustParseAddr("10.20.0.160")}}
	probe := func(netip.Addr) apSample { return apSample{Sent: 5, Received: 5} }

	withReboot := newAPMonitor(withCreds, probe)
	withReboot.reboot = func(accessPoint) error { return nil }
	withReboot.cycle()

	// A monitor with a reboot function wired but an AP that carries no login:
	// the button must still not render, and the route must still 404.
	noReboot := newAPMonitor(lampOnly, probe)
	noReboot.reboot = func(accessPoint) error { return nil }
	noReboot.cycle()

	listeners := func(m *apMonitor) map[string]http.Handler {
		return map[string]http.Handler{
			"lan":  landingMux(pageData{}, tmpl, nil, m, navSource{}),
			"mesh": meshMux(pageData{}, indexTmpl, nil, m, testPeersServer(t), navSource{}),
		}
	}

	t.Run("a login shows the button on both listeners", func(t *testing.T) {
		for name, handler := range listeners(withReboot) {
			rec := httptest.NewRecorder()
			handler.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/", nil))
			if !strings.Contains(rec.Body.String(), `action="/ap/reboot"`) {
				t.Errorf("%s page with a login did not render the reboot button", name)
			}
		}
	})

	t.Run("a login makes the route work on both listeners", func(t *testing.T) {
		for name, handler := range listeners(withReboot) {
			rec := httptest.NewRecorder()
			req := httptest.NewRequest(http.MethodPost, "/ap/reboot", strings.NewReader("ap=first"))
			req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
			handler.ServeHTTP(rec, req)
			if rec.Code != http.StatusSeeOther {
				t.Errorf("%s POST /ap/reboot = %d, want 303", name, rec.Code)
			}
		}
	})

	t.Run("no login means no button and a 404 route on both listeners", func(t *testing.T) {
		for name, handler := range listeners(noReboot) {
			rec := httptest.NewRecorder()
			handler.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/", nil))
			if strings.Contains(rec.Body.String(), "/ap/reboot") {
				t.Errorf("%s page with no login rendered a reboot button", name)
			}

			rec = httptest.NewRecorder()
			req := httptest.NewRequest(http.MethodPost, "/ap/reboot", strings.NewReader("ap=first"))
			req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
			handler.ServeHTTP(rec, req)
			if rec.Code != http.StatusNotFound {
				t.Errorf("%s POST /ap/reboot with no login = %d, want 404", name, rec.Code)
			}
		}
	})
}

// detectAPKind reads which login page the root URL redirects to. login.asp is
// the legacy firmware; anything else is treated as modern.
func TestDetectAPKind(t *testing.T) {
	for name, tc := range map[string]struct {
		loginPath string
		want      apKind
	}{
		"modern": {"/login.html", apModern},
		"legacy": {"/login.asp", apLegacy},
	} {
		t.Run(name, func(t *testing.T) {
			mux := http.NewServeMux()
			mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
				if r.URL.Path == "/" {
					http.Redirect(w, r, tc.loginPath, http.StatusFound)
					return
				}
				w.WriteHeader(http.StatusOK)
			})
			server := httptest.NewServer(mux)
			defer server.Close()

			kind, err := detectAPKind(server.Client(), server.URL)
			if err != nil {
				t.Fatalf("detectAPKind: %v", err)
			}
			if kind != tc.want {
				t.Errorf("detectAPKind = %v, want %v", kind, tc.want)
			}
		})
	}
}

// The modern flow logs in and only then reboots, and the password crosses the
// wire base64-encoded, which is the AP's own scheme.
func TestIPCOMRebootModern(t *testing.T) {
	var steps []string
	var sentPassword string
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/goform/modules" {
			t.Errorf("request to %q, want /goform/modules", r.URL.Path)
		}
		var body map[string]json.RawMessage
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
			t.Fatalf("decode request: %v", err)
		}
		switch {
		case body["sysLogin"] != nil:
			steps = append(steps, "login")
			var login struct {
				Username string `json:"username"`
				Password string `json:"password"`
			}
			_ = json.Unmarshal(body["sysLogin"], &login)
			sentPassword = login.Password
			_, _ = w.Write([]byte(`{"sysLogin":{"userType":"admin","Login":true}}`))
		case body["sysReboot"] != nil:
			steps = append(steps, "reboot")
			_, _ = w.Write([]byte(`{}`))
		default:
			t.Errorf("unexpected request body %v", body)
		}
	}))
	defer server.Close()

	creds := apCredentials{username: "admin", password: "test-pw-not-real"}
	if err := ipcomRebootModern(server.Client(), creds, server.URL+"/goform/modules"); err != nil {
		t.Fatalf("ipcomRebootModern: %v", err)
	}
	if strings.Join(steps, ",") != "login,reboot" {
		t.Errorf("steps = %v, want login then reboot", steps)
	}
	if want := base64.StdEncoding.EncodeToString([]byte("test-pw-not-real")); sentPassword != want {
		t.Errorf("password on the wire = %q, want the base64 %q", sentPassword, want)
	}
}

// A rejected modern login stops before the reboot: wrong credentials must not
// still power-cycle the AP.
func TestIPCOMRebootModernStopsOnRejectedLogin(t *testing.T) {
	rebooted := false
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var body map[string]json.RawMessage
		_ = json.NewDecoder(r.Body).Decode(&body)
		if body["sysReboot"] != nil {
			rebooted = true
		}
		_, _ = w.Write([]byte(`{"sysLogin":{"userType":"","Login":false}}`))
	}))
	defer server.Close()

	err := ipcomRebootModern(server.Client(), apCredentials{username: "admin", password: "wrong"},
		server.URL+"/goform/modules")
	if err == nil {
		t.Fatal("ipcomRebootModern succeeded with a rejected login")
	}
	if rebooted {
		t.Error("the reboot was issued after the login was rejected")
	}
}

// The legacy flow posts a form login to /login/Auth, then GETs the reboot. The
// password is base64 here too, and the reboot only fires once the login has
// landed somewhere other than login.asp.
func TestIPCOMRebootLegacy(t *testing.T) {
	var steps []string
	var sentPassword string
	mux := http.NewServeMux()
	mux.HandleFunc("/login/Auth", func(w http.ResponseWriter, r *http.Request) {
		steps = append(steps, "login")
		_ = r.ParseForm()
		sentPassword = r.PostFormValue("password")
		http.Redirect(w, r, "/index.asp", http.StatusFound)
	})
	mux.HandleFunc("/index.asp", func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusOK)
	})
	mux.HandleFunc("/goform/SysToolReboot", func(w http.ResponseWriter, _ *http.Request) {
		steps = append(steps, "reboot")
		w.WriteHeader(http.StatusOK)
	})
	server := httptest.NewServer(mux)
	defer server.Close()

	creds := apCredentials{username: "admin", password: "test-pw-not-real"}
	if err := ipcomRebootLegacy(server.Client(), creds, server.URL); err != nil {
		t.Fatalf("ipcomRebootLegacy: %v", err)
	}
	if strings.Join(steps, ",") != "login,reboot" {
		t.Errorf("steps = %v, want login then reboot", steps)
	}
	if want := base64.StdEncoding.EncodeToString([]byte("test-pw-not-real")); sentPassword != want {
		t.Errorf("password on the wire = %q, want the base64 %q", sentPassword, want)
	}
}

// A rejected legacy login redirects back to login.asp, and the reboot must not
// fire.
func TestIPCOMRebootLegacyStopsOnRejectedLogin(t *testing.T) {
	rebooted := false
	mux := http.NewServeMux()
	mux.HandleFunc("/login/Auth", func(w http.ResponseWriter, r *http.Request) {
		http.Redirect(w, r, "/login.asp", http.StatusFound)
	})
	mux.HandleFunc("/login.asp", func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusOK)
	})
	mux.HandleFunc("/goform/SysToolReboot", func(w http.ResponseWriter, _ *http.Request) {
		rebooted = true
		w.WriteHeader(http.StatusOK)
	})
	server := httptest.NewServer(mux)
	defer server.Close()

	err := ipcomRebootLegacy(server.Client(), apCredentials{username: "admin", password: "wrong"}, server.URL)
	if err == nil {
		t.Fatal("ipcomRebootLegacy succeeded with a rejected login")
	}
	if rebooted {
		t.Error("the reboot was issued after the login was rejected")
	}
}

// The list is on the LAN listener as well as the mesh one. It describes the
// router's own infrastructure rather than any device on the network, which is
// the line registerStatusRoutes draws.
func TestAccessPointsServedOnBothListeners(t *testing.T) {
	tmpl := template.Must(template.ParseFiles("index.html", "nav.html"))
	indexTmpl := template.Must(template.ParseFiles(
		filepath.Join(".", "index.html"), filepath.Join(".", "nav.html")))
	monitor := newAPMonitor([]accessPoint{
		{Name: "first", Addr: netip.MustParseAddr("10.20.0.160")},
	}, func(netip.Addr) apSample { return apSample{Sent: 5, Received: 5} })
	monitor.cycle()

	for name, handler := range map[string]http.Handler{
		"lan":  landingMux(pageData{}, tmpl, nil, monitor, navSource{}),
		"mesh": meshMux(pageData{}, indexTmpl, nil, monitor, testPeersServer(t), navSource{}),
	} {
		t.Run(name, func(t *testing.T) {
			recorder := httptest.NewRecorder()
			handler.ServeHTTP(recorder, httptest.NewRequest(http.MethodGet, "/", nil))
			if !strings.Contains(recorder.Body.String(), "Access Points") {
				t.Errorf("%s listener did not serve the access point list", name)
			}
		})
	}
}
