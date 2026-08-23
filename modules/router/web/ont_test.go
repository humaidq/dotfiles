package main

import (
	"html/template"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// A healthy sample, taken verbatim from bongo's ONT: it reports its own
// receive-power thresholds, so the window comes from the device rather than
// from the fallback constants.
const ontHealthy = `# HELP router_ont_rx_power_dbm Received optical power at 1490 nm
# TYPE router_ont_rx_power_dbm gauge
router_ont_rx_power_dbm -13.597745895385742
router_ont_tx_power_dbm 2.4697210788726807
router_ont_transceiver_temperature_celsius 38.400001525878906
router_ont_supply_voltage_volts 3.313309907913208
router_ont_bias_current_amperes 0.012011718936264515
router_ont_rx_power_threshold_dbm{bound="lower"} -27.958799362182617
router_ont_rx_power_threshold_dbm{bound="upper"} -7.000571250915527
router_ont_pon_up 1
router_ont_collector_success 1
`

// bingo's ONT leaves the thresholds unprovisioned, so the collector omits
// them. Same readings otherwise.
const ontNoThresholds = `router_ont_rx_power_dbm -13.647125244140625
router_ont_tx_power_dbm 2.7367305755615234
router_ont_transceiver_temperature_celsius 37.599998474121094
router_ont_supply_voltage_volts 3.276129961013794
router_ont_bias_current_amperes 0.014042968861758709
router_ont_pon_up 1
router_ont_collector_success 1
`

// writeONT drops a textfile in a temp dir and returns a monitor for it with a
// clock pinned just after the write, so nothing is stale unless a test says so.
func writeONT(t *testing.T, body string) *ontMonitor {
	t.Helper()
	path := filepath.Join(t.TempDir(), "ont.prom")
	if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
		t.Fatalf("write sample: %v", err)
	}
	monitor := newONTMonitor(path)
	monitor.now = func() time.Time { return time.Now().Add(time.Second) }
	return monitor
}

func TestONTHealthyLine(t *testing.T) {
	report := writeONT(t, ontHealthy).report()
	if report == nil {
		t.Fatal("no report from a readable file")
	}
	if report.State != stateOK || report.StateText != "healthy" {
		t.Errorf("state = %q/%q, want ok/healthy", report.State, report.StateText)
	}
	if report.Note != "" {
		t.Errorf("a healthy line explained itself: %q", report.Note)
	}
	if len(report.Meters) != 5 {
		t.Fatalf("got %d meters, want 5", len(report.Meters))
	}
	for _, bar := range report.Meters {
		if bar.State != meterOK {
			t.Errorf("%s is %s on a healthy line", bar.Label, bar.State)
		}
		if bar.Range == "" {
			t.Errorf("%s has no normal range printed", bar.Label)
		}
	}
}

// Receive power is the reading that matters most, so its value, units and
// window are pinned rather than merely graded.
func TestONTReceivePowerUsesDeviceThresholds(t *testing.T) {
	report := writeONT(t, ontHealthy).report()
	rx := report.Meters[0]

	if rx.Value != "-13.6 dBm" {
		t.Errorf("value = %q, want -13.6 dBm", rx.Value)
	}
	// -27.96 + 3 and -7.00 - 3, from the thresholds in the sample.
	if want := "normal -25.0 to -10.0 dBm"; rx.Range != want {
		t.Errorf("range = %q, want %q", rx.Range, want)
	}
	// -13.6 sits 14.36 dB up a 20.96 dB window.
	if rx.Fill != 69 {
		t.Errorf("fill = %d, want 69", rx.Fill)
	}
}

// Without device thresholds the class B+ figures stand in, and the line still
// grades as healthy rather than unknown.
func TestONTFallsBackToClassBPlusWindow(t *testing.T) {
	report := writeONT(t, ontNoThresholds).report()
	if report.State != stateOK {
		t.Fatalf("state = %q, want ok", report.State)
	}
	if want := "normal -24.0 to -11.0 dBm"; report.Meters[0].Range != want {
		t.Errorf("range = %q, want %q", report.Meters[0].Range, want)
	}
}

// A pair that cannot be a window must not make every reading a fault.
func TestONTIgnoresInvertedThresholds(t *testing.T) {
	body := strings.NewReplacer(
		"-27.958799362182617", "-7.0",
		"-7.000571250915527", "-27.96",
	).Replace(ontHealthy)

	report := writeONT(t, body).report()
	if report.State != stateOK {
		t.Errorf("state = %q with inverted thresholds, want ok via the fallback", report.State)
	}
}

func TestONTGrades(t *testing.T) {
	for _, tc := range []struct {
		name      string
		rx        string
		wantState string
		wantText  string
	}{
		// Inside the -27.96 alarm but past the -24.96 warn edge: still
		// carrying traffic, with most of its margin gone.
		{"marginal", "-25.5", stateDegraded, "marginal: receive power"},
		// Past the alarm threshold the ONT itself reports.
		{"out of range", "-28.4", stateDegraded, "out of range: receive power"},
		// Swamped rather than starved: the other end of the same window.
		{"too much light", "-6.2", stateDegraded, "out of range: receive power"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			body := strings.Replace(ontHealthy, "-13.597745895385742", tc.rx, 1)
			report := writeONT(t, body).report()
			if report.State != tc.wantState || report.StateText != tc.wantText {
				t.Errorf("got %q/%q, want %q/%q",
					report.State, report.StateText, tc.wantState, tc.wantText)
			}
			if report.Note == "" {
				t.Error("a non-healthy band said nothing about why")
			}
		})
	}
}

// The PON being down outranks any individual reading: it is the one state that
// means the line is not carrying traffic at all.
func TestONTPONDown(t *testing.T) {
	report := writeONT(t, strings.Replace(ontHealthy, "router_ont_pon_up 1", "router_ont_pon_up 0", 1)).report()
	if report.State != stateDown || report.StateText != "fibre down" {
		t.Errorf("got %q/%q, want down/fibre down", report.State, report.StateText)
	}
}

// A failed scrape is not a failed line, and must not be reported as one.
func TestONTCollectorFailureIsNotALineFault(t *testing.T) {
	report := writeONT(t, strings.Replace(ontHealthy, "router_ont_collector_success 1", "router_ont_collector_success 0", 1)).report()
	if report.State != stateUnknown || report.StateText != "unavailable" {
		t.Errorf("got %q/%q, want unknown/unavailable", report.State, report.StateText)
	}
	if !strings.Contains(report.Note, "line itself may be fine") {
		t.Errorf("note does not distinguish scrape from line: %q", report.Note)
	}
}

// A stale file is the dangerous case: the numbers still look like readings.
func TestONTStaleReadingsAreNotPresentedAsCurrent(t *testing.T) {
	monitor := writeONT(t, ontHealthy)
	monitor.now = func() time.Time { return time.Now().Add(ontStaleAfter + time.Minute) }

	report := monitor.report()
	if report.State != stateUnknown || report.StateText != "stale" {
		t.Errorf("got %q/%q, want unknown/stale", report.State, report.StateText)
	}
	for _, bar := range report.Meters {
		if bar.State != meterUnknown {
			t.Errorf("%s still graded %s on a stale read", bar.Label, bar.State)
		}
	}
}

// Absent sample, absent bar — but the section still renders the rest.
func TestONTMissingSampleIsUnknownNotZero(t *testing.T) {
	body := strings.Replace(ontHealthy, "router_ont_bias_current_amperes 0.012011718936264515\n", "", 1)
	report := writeONT(t, body).report()

	bias := report.Meters[4]
	if bias.State != meterUnknown || bias.Value != "—" {
		t.Errorf("absent bias rendered as %q/%q, want unknown/—", bias.State, bias.Value)
	}
	// One unknown reading does not condemn the line.
	if report.State != stateOK {
		t.Errorf("state = %q with one absent reading, want ok", report.State)
	}
}

func TestONTNoMonitorAndNoFile(t *testing.T) {
	if newONTMonitor("").report() != nil {
		t.Error("an unset path produced a report")
	}
	if newONTMonitor("   ").report() != nil {
		t.Error("a blank path produced a report")
	}
	missing := newONTMonitor(filepath.Join(t.TempDir(), "absent.prom"))
	if missing.report() != nil {
		t.Error("a missing file produced a report rather than no section")
	}
}

// Garbage in the file must not panic or produce phantom readings.
func TestONTIgnoresUnparseableLines(t *testing.T) {
	body := ontHealthy + "router_ont_rx_power_dbm NaN\nnot a metric line\nrouter_ont_future_metric{a=\"b\"} 7\n"
	report := writeONT(t, body).report()
	if report == nil {
		t.Fatal("no report")
	}
	// The NaN line must not have overwritten the good reading above it.
	if report.Meters[0].Value != "-13.6 dBm" {
		t.Errorf("rx = %q after a NaN line, want -13.6 dBm", report.Meters[0].Value)
	}
}

// The whole point of the request: it is on the unauthenticated LAN page.
func TestStatusPageRendersONTUnauthenticated(t *testing.T) {
	tmpl := template.Must(template.ParseFiles("index.html", "nav.html"))
	recorder := httptest.NewRecorder()
	landingMux(pageData{}, tmpl, nil, nil, writeONT(t, ontHealthy), navSource{}).ServeHTTP(
		recorder, httptest.NewRequest(http.MethodGet, "/", nil))

	body := recorder.Body.String()
	for _, want := range []string{
		"Fibre line: healthy",
		"Receive power",
		"-13.6 dBm",
		"normal -25.0 to -10.0 dBm",
		"Laser bias",
		"meter-ok",
	} {
		if !strings.Contains(body, want) {
			t.Errorf("status page is missing %q", want)
		}
	}
	// Subscriber identity stays off a page anyone on the wifi can load.
	for _, forbidden := range []string{"ALCL", "adminadmin", "192.168.1.254"} {
		if strings.Contains(body, forbidden) {
			t.Errorf("status page leaked %q", forbidden)
		}
	}
}

// A router with no ONT configured serves exactly the page it served before.
func TestStatusPageOmitsONTWhenUnset(t *testing.T) {
	tmpl := template.Must(template.ParseFiles("index.html", "nav.html"))
	recorder := httptest.NewRecorder()
	landingMux(pageData{}, tmpl, nil, nil, nil, navSource{}).ServeHTTP(
		recorder, httptest.NewRequest(http.MethodGet, "/", nil))

	if body := recorder.Body.String(); strings.Contains(body, "Fibre line") {
		t.Error("the fibre section rendered with no ONT configured")
	}
}

// The optical history that backs the graph on the uplink page.

func TestRecordStoresOneRowPerCollectorWrite(t *testing.T) {
	store := newTestStore(t)
	monitor := writeONT(t, ontHealthy)
	monitor.store = store

	// Sampling far more often than the collector writes is the design: the
	// row is keyed on the file's mtime, so re-reads collapse.
	for range 5 {
		monitor.record()
	}

	samples, err := store.opticalSince(time.Now().Add(-time.Hour))
	if err != nil {
		t.Fatalf("opticalSince: %v", err)
	}
	if len(samples) != 1 {
		t.Fatalf("got %d rows from five reads of one file, want 1", len(samples))
	}
	got := samples[0]
	if got.Rx != -13.597745895385742 {
		t.Errorf("rx = %v", got.Rx)
	}
	if got.Bias != 0.012011718936264515 {
		t.Errorf("bias = %v", got.Bias)
	}
	if !got.PONUp {
		t.Error("pon recorded as down on a healthy sample")
	}
}

// A failed scrape must not land in the history: a graph is exactly where an
// invented reading would be believed.
func TestRecordSkipsFailedAndPartialReadings(t *testing.T) {
	store := newTestStore(t)

	failed := writeONT(t, strings.Replace(ontHealthy, "router_ont_collector_success 1", "router_ont_collector_success 0", 1))
	failed.store = store
	failed.record()

	partial := writeONT(t, strings.Replace(ontHealthy, "router_ont_tx_power_dbm 2.4697210788726807\n", "", 1))
	partial.store = store
	partial.record()

	samples, err := store.opticalSince(time.Now().Add(-time.Hour))
	if err != nil {
		t.Fatalf("opticalSince: %v", err)
	}
	if len(samples) != 0 {
		t.Errorf("stored %d rows from a failed scrape and a partial reading, want 0", len(samples))
	}
}

func TestHistoryIsEmptyWithoutAStore(t *testing.T) {
	if got := writeONT(t, ontHealthy).history(time.Now().Add(-time.Hour)); got != nil {
		t.Errorf("history without a store returned %d rows", len(got))
	}
	var nilMonitor *ontMonitor
	if got := nilMonitor.history(time.Now().Add(-time.Hour)); got != nil {
		t.Error("history on a nil monitor returned rows")
	}
}

// The shaded band must be the normal range, both edges of it. This is the
// thing the old single tick got wrong: it marked one number and left the
// reader to guess which side of it was good.
func TestFibreBandMarksTheNormalRange(t *testing.T) {
	rx := writeONT(t, ontHealthy).report().Meters[0]

	// Window -27.96..-7.00 spans 20.96 dB; the warn edges -24.96 and -10.00
	// sit 14% and 86% along it.
	if rx.GoodStart != 14 {
		t.Errorf("band starts at %d%%, want 14%%", rx.GoodStart)
	}
	if rx.GoodWidth != 72 {
		t.Errorf("band is %d%% wide, want 72%%", rx.GoodWidth)
	}
	// The reading sits inside it, which is what "healthy" has to mean.
	if rx.Fill < rx.GoodStart || rx.Fill > rx.GoodStart+rx.GoodWidth {
		t.Errorf("fill %d%% is outside the normal band on a healthy line", rx.Fill)
	}
}

// The vertical scale is printed on the trace, or the shape means nothing.
func TestFibreGraphStatesItsScale(t *testing.T) {
	base := time.Now().Add(-6 * time.Hour)
	var samples []opticalSample
	for i := range 12 {
		samples = append(samples, opticalSample{
			TS: base.Add(time.Duration(i) * time.Minute),
			Rx: -13.5 - float64(i)*0.05, PONUp: true,
		})
	}
	svg := string(opticalSparkline(samples, 720, 48))

	for _, want := range []string{"spark-axis", ">-13.5<", ">-14.1<"} {
		if !strings.Contains(svg, want) {
			t.Errorf("trace is missing %q:\n%s", want, svg)
		}
	}
}
