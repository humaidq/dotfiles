package main

import (
	"bufio"
	"fmt"
	"log"
	"math"
	"os"
	"strconv"
	"strings"
	"time"
)

// The fibre terminal's optical diagnostics, for the status page.
//
// This reads the Prometheus textfile that ont-textfile publishes; it never
// talks to the ONT itself. That split is deliberate and worth keeping: the
// credential for the ONT is a root shell on the operator's equipment, and
// router-web is the process listening on a network. The collector runs as root
// on a timer, holds the credential, and leaves a world-readable file behind;
// this reads the file. Nothing here can reach the ONT even if it wanted to.
//
// What is shown is the physical line and nothing else. The same device also
// knows the GPON serial, the SLID and the provisioned telephone number, none of
// which appear here — this page is unauthenticated, and optical power is a
// property of the fibre while those are properties of the subscriber.

const (
	// The collector's timer is 5 minutes. Past this the reading is shown as
	// unknown rather than as current, because a stale figure presented as live
	// is worse than no figure: it is the reading someone would act on.
	ontStaleAfter = 16 * time.Minute

	// Fallback receive-power alarm thresholds, in dBm, for an ONT that does not
	// report its own. ITU-T G.984.2 class B+ puts the ONU receiver between -8
	// and -27 dBm; one of the two units here reports its configured pair
	// (-27.96 and -7.00) and the other leaves them unprovisioned.
	ontRxFallbackLow  = -27.0
	ontRxFallbackHigh = -8.0

	// How close to an alarm threshold counts as "getting there" rather than
	// fine. 3 dB is half the power budget of a typical class B+ margin, so a
	// line inside this band has lost most of its headroom without having
	// failed yet.
	ontRxWarnMargin = 3.0
)

// ontMeter is a meter with the normal range spelled out beside it.
//
// The status page's existing meter renders a tooltip, which is fine for a
// figure whose units are self-explanatory. Optical power is not that: -13 dBm
// is meaningless to most people looking at this page, and "normal -27 to -8"
// next to it is the whole difference between a number and an answer. A
// tooltip cannot do that job because it does not exist on a phone.
type ontMeter struct {
	Label string
	Value string
	Range string
	Title string
	// All 0-100, as a percentage of the bar's width, and meaning exactly what
	// they mean on the uplink meters — the shaded band is the normal range.
	// Two-sided here, so unlike those it does not start at zero.
	Fill      int
	GoodStart int
	GoodWidth int
	// meterOK, meterWarn, meterBad or meterUnknown.
	State string
}

// ontReport is what the template renders. A nil report means no section at all,
// which is what a router with no ONT configured produces.
type ontReport struct {
	State     string
	StateText string
	Meters    []ontMeter
	// A sentence shown under the meters when something needs saying: the
	// reading is stale, the collector could not log in, the PON is down.
	// Empty on a healthy line, where the meters say everything.
	Note    string
	Updated string
}

// ontWindow is a two-sided operating range.
//
// Optical readings are unlike the uplink's: there, higher is worse and zero is
// perfect, so one threshold pair is enough. Here both ends are faults — a
// receiver can be swamped as well as starved — and the ideal sits somewhere in
// the middle. Hence four numbers and a tick position rather than newMeter's
// good/limit pair.
type ontWindow struct {
	alarmLo float64
	warnLo  float64
	warnHi  float64
	alarmHi float64
	ideal   float64
}

func (w ontWindow) grade(v float64) string {
	switch {
	case v <= w.alarmLo, v >= w.alarmHi:
		return meterBad
	case v < w.warnLo, v > w.warnHi:
		return meterWarn
	default:
		return meterOK
	}
}

// position maps a reading onto the bar, where 0 is the low alarm and 100 the
// high one. Unlike the uplink meters a full bar is not a bad bar; being at
// either end is. The colour carries the verdict and the tick carries the
// ideal.
func (w ontWindow) position(v float64) int {
	span := w.alarmHi - w.alarmLo
	if span <= 0 {
		return 0
	}
	pct := int(math.Round((v - w.alarmLo) / span * 100))
	if pct < 0 {
		return 0
	}
	if pct > 100 {
		return 100
	}
	return pct
}

// The windows for everything except receive power, which is taken from the ONT
// where it reports it.
//
// These are the conventional figures for the part rather than measurements of
// these two lines: class B+ ONU transmit power, the commercial temperature
// rating every SFF module carries, and 3.3 V nominal at the usual +/-5%. They
// are here to answer "is this number normal", which they do; they are not
// operator alarm thresholds and should not be read as if the ISP set them.
var (
	ontTxWindow = ontWindow{alarmLo: -0.5, warnLo: 0.5, warnHi: 5.0, alarmHi: 6.0, ideal: 2.5}

	ontTempWindow = ontWindow{alarmLo: 0, warnLo: 5, warnHi: 65, alarmHi: 70, ideal: 40}

	ontVoltWindow = ontWindow{alarmLo: 3.13, warnLo: 3.2, warnHi: 3.4, alarmHi: 3.47, ideal: 3.3}

	// Bias current is the loosest of these on purpose. What it actually
	// diagnoses is a laser ageing, and that shows as a rising trend over
	// months rather than as any one reading crossing a line — the Grafana
	// history is the right place to see it. The bar is here so the figure is
	// not presented naked, and its range is wide enough that it only colours
	// when something is genuinely wrong.
	ontBiasWindow = ontWindow{alarmLo: 0, warnLo: 2, warnHi: 40, alarmHi: 60, ideal: 15}
)

// ontMonitor reads the collector's textfile. Zero value is unusable; a nil
// monitor is the router without the feature.
type ontMonitor struct {
	path string
	// Injected so the staleness check is testable without sleeping.
	now func() time.Time
	// Where readings are kept so the uplink page can graph them. Nil on a
	// router with no uplink database, which leaves the status page's live band
	// working and simply offers no history — the same opt-in shape the rest of
	// this service uses.
	store *uplinkStore
}

func newONTMonitor(path string) *ontMonitor {
	path = strings.TrimSpace(path)
	if path == "" {
		return nil
	}
	return &ontMonitor{path: path, now: time.Now}
}

// ontSamples is the parsed textfile: metric name (with its label set, when it
// has one) to value.
type ontSamples map[string]float64

func (s ontSamples) value(name string) (float64, bool) {
	v, ok := s[name]
	return v, ok
}

// parseONTTextfile reads the subset of the Prometheus text format the collector
// emits: no timestamps, no exemplars, at most one label. Anything it does not
// recognise is skipped rather than treated as an error — a future metric added
// to the collector must not blank this section.
func parseONTTextfile(r *bufio.Scanner) ontSamples {
	samples := ontSamples{}
	for r.Scan() {
		line := strings.TrimSpace(r.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		idx := strings.LastIndex(line, " ")
		if idx <= 0 {
			continue
		}
		name := strings.TrimSpace(line[:idx])
		value, err := strconv.ParseFloat(strings.TrimSpace(line[idx+1:]), 64)
		if err != nil || math.IsNaN(value) || math.IsInf(value, 0) {
			continue
		}
		samples[name] = value
	}
	return samples
}

func (m *ontMonitor) read() (ontSamples, time.Time, error) {
	info, err := os.Stat(m.path)
	if err != nil {
		return nil, time.Time{}, err
	}
	file, err := os.Open(m.path)
	if err != nil {
		return nil, time.Time{}, err
	}
	defer file.Close()
	return parseONTTextfile(bufio.NewScanner(file)), info.ModTime(), nil
}

// rxWindow prefers the thresholds the ONT itself reports. One of the two units
// here leaves them unprovisioned, in which case the collector omits them
// (they read as negative infinity) and the class B+ figures stand in.
func rxWindow(samples ontSamples) ontWindow {
	lo, hi := ontRxFallbackLow, ontRxFallbackHigh
	if v, ok := samples.value(`router_ont_rx_power_threshold_dbm{bound="lower"}`); ok {
		lo = v
	}
	if v, ok := samples.value(`router_ont_rx_power_threshold_dbm{bound="upper"}`); ok {
		hi = v
	}
	// A malformed or inverted pair would make every reading "bad". Fall back
	// rather than accuse the line.
	if hi <= lo {
		lo, hi = ontRxFallbackLow, ontRxFallbackHigh
	}
	return ontWindow{
		alarmLo: lo,
		warnLo:  lo + ontRxWarnMargin,
		warnHi:  hi - ontRxWarnMargin,
		alarmHi: hi,
		ideal:   (lo + hi) / 2,
	}
}

// reading builds one bar, or an unknown one when the sample is absent.
func ontReading(label, unit string, samples ontSamples, name string, scale float64, window ontWindow, title string) ontMeter {
	raw, ok := samples.value(name)
	if !ok {
		return ontMeter{
			Label: label,
			Value: "—",
			Range: ontRangeText(window, unit, scale),
			Title: "not reported by the ONT",
			State: meterUnknown,
		}
	}
	v := raw * scale
	return ontMeter{
		Label:     label,
		Value:     fmt.Sprintf("%.1f %s", v, unit),
		Range:     ontRangeText(window, unit, scale),
		Title:     title,
		Fill:      window.position(v),
		GoodStart: window.position(window.warnLo),
		GoodWidth: window.position(window.warnHi) - window.position(window.warnLo),
		State:     window.grade(v),
	}
}

func ontRangeText(w ontWindow, unit string, _ float64) string {
	return fmt.Sprintf("normal %.1f to %.1f %s", w.warnLo, w.warnHi, unit)
}

// report is what the status page renders. Nil monitor, missing file and
// unreadable file all produce nil: no section rather than an empty one.
func (m *ontMonitor) report() *ontReport {
	if m == nil {
		return nil
	}
	samples, modified, err := m.read()
	if err != nil {
		return nil
	}

	rx := rxWindow(samples)
	meters := []ontMeter{
		ontReading("Receive power", "dBm", samples, "router_ont_rx_power_dbm", 1,
			rx, "Light arriving from the exchange. Falls when a connector is dirty or a splice degrades."),
		ontReading("Transmit power", "dBm", samples, "router_ont_tx_power_dbm", 1,
			ontTxWindow, "Light this box is sending back."),
		ontReading("Module temperature", "°C", samples, "router_ont_transceiver_temperature_celsius", 1,
			ontTempWindow, "Temperature of the optical module."),
		ontReading("Supply voltage", "V", samples, "router_ont_supply_voltage_volts", 1,
			ontVoltWindow, "Optical module supply rail, nominally 3.3 V."),
		// Amperes in the metric, milliamps on the page: base units are the
		// Prometheus convention and 0.012 A is not a figure anyone reads.
		ontReading("Laser bias", "mA", samples, "router_ont_bias_current_amperes", 1000,
			ontBiasWindow, "Drive current for the laser. Useful as a trend over months, not as a single reading."),
	}

	report := &ontReport{
		Meters:  meters,
		Updated: modified.Format("2006-01-02 15:04:05 MST"),
	}

	// Order matters below: each case describes a stronger failure than the one
	// after it, and the first that applies is the one worth saying.
	switch {
	case m.now().Sub(modified) > ontStaleAfter:
		report.State, report.StateText = stateUnknown, "stale"
		report.Note = "These readings are older than the collector's interval, so the line may have changed since. Check ont-textfile.service."
		for i := range report.Meters {
			report.Meters[i].State = meterUnknown
		}
		return report

	case sampleIsZero(samples, "router_ont_collector_success"):
		report.State, report.StateText = stateUnknown, "unavailable"
		report.Note = "The router could not read the fibre terminal. The line itself may be fine."
		return report

	case sampleIsZero(samples, "router_ont_pon_up"):
		report.State, report.StateText = stateDown, "fibre down"
		report.Note = "The fibre terminal reports no link to the exchange."
		return report
	}

	worst, label := meterOK, ""
	for _, bar := range report.Meters {
		switch bar.State {
		case meterBad:
			if worst != meterBad {
				worst, label = meterBad, bar.Label
			}
		case meterWarn:
			if worst == meterOK {
				worst, label = meterWarn, bar.Label
			}
		}
	}

	switch worst {
	case meterBad:
		report.State, report.StateText = stateDegraded, "out of range: "+strings.ToLower(label)
		report.Note = "A reading is outside its normal range. If the line is also slow or dropping, this is likely why."
	case meterWarn:
		report.State, report.StateText = stateDegraded, "marginal: "+strings.ToLower(label)
		report.Note = "A reading is close to the edge of its normal range but the line is still working."
	default:
		report.State, report.StateText = stateOK, "healthy"
	}
	return report
}

// How often the file is re-read for the history. Deliberately shorter than the
// collector's own interval: the primary key is the collector's write time, so
// an unchanged file is dropped by the insert and the only cost of sampling
// often is a local file read. Being faster than the writer means a reading is
// picked up promptly rather than up to a full interval late.
const ontSampleInterval = time.Minute

// recordEvery keeps the optical history topped up. Blocks; run it in a
// goroutine. A monitor with no store returns immediately, so the caller does
// not have to check.
func (m *ontMonitor) recordEvery(interval time.Duration) {
	if m == nil || m.store == nil {
		return
	}
	// Once before the first tick, so a page loaded straight after a restart
	// has a point to draw rather than an empty axis.
	m.record()
	for range time.Tick(interval) {
		m.record()
	}
}

// record stores the current reading, if there is a complete one to store.
//
// Partial readings are skipped rather than stored with zeros: a zero dBm is a
// plausible-looking value, and a graph is exactly where a fabricated one would
// be believed.
func (m *ontMonitor) record() {
	samples, modified, err := m.read()
	if err != nil {
		return
	}
	if sampleIsZero(samples, "router_ont_collector_success") {
		return
	}
	sample := opticalSample{TS: modified, PONUp: !sampleIsZero(samples, "router_ont_pon_up")}
	for _, field := range []struct {
		name string
		into *float64
	}{
		{"router_ont_rx_power_dbm", &sample.Rx},
		{"router_ont_tx_power_dbm", &sample.Tx},
		{"router_ont_transceiver_temperature_celsius", &sample.Temp},
		{"router_ont_supply_voltage_volts", &sample.Volt},
		{"router_ont_bias_current_amperes", &sample.Bias},
	} {
		value, ok := samples.value(field.name)
		if !ok {
			return
		}
		*field.into = value
	}
	if err := m.store.appendOptical(sample); err != nil {
		log.Printf("ont: %v", err)
	}
}

// history returns readings over a window, oldest first.
func (m *ontMonitor) history(from time.Time) []opticalSample {
	if m == nil || m.store == nil {
		return nil
	}
	samples, err := m.store.opticalSince(from)
	if err != nil {
		log.Printf("ont: %v", err)
		return nil
	}
	return samples
}

// sampleIsZero is true only when the sample is present and zero. An absent
// sample is not a failure — an older collector that never emitted it must not
// make the page claim the fibre is down.
func sampleIsZero(samples ontSamples, name string) bool {
	v, ok := samples.value(name)
	return ok && v == 0
}
