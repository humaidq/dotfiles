package main

import (
	"fmt"
	"html/template"
	"log"
	"math"
	"net/http"
	"os"
	"sort"
	"strconv"
	"strings"
	"time"
)

// Rendering and export for the uplink history: the band at the top of the
// landing page, the detail page behind it, and the Prometheus endpoint.
//
// The band and the detail page read the same store the prober writes, plus the
// prober's in-memory view for anything fresher than the last completed minute.
// Nothing here computes a measurement; if a number is not in uplink.go it is
// not a number this page is entitled to show.

// How far back each view looks.
const (
	bandWindow   = 24 * time.Hour
	detailWindow = 24 * time.Hour
	eventWindow  = 30 * 24 * time.Hour
	eventLimit   = 200
	dailyWindow  = 90 * 24 * time.Hour
	// How much optical history the trace covers. Long enough that a slow drift
	// is visible as a slope rather than as noise, short enough that a fault
	// last week does not compress this week into a flat line.
	opticalWindow  = 14 * 24 * time.Hour
	baselineWindow = 7 * 24 * time.Hour
)

// Health states, worst last. These are strings because they are also CSS class
// suffixes on the band.
const (
	stateUnknown  = "unknown"
	stateOK       = "ok"
	stateDegraded = "degraded"
	stateDown     = "down"
)

// uplinkService owns the read side.
type uplinkService struct {
	store  *uplinkStore
	prober *uplinkProber
	tmpl   *template.Template
	// Mirrors the retention the prober enforces, shown on the page so the
	// window the data covers is stated rather than inferred.
	retention time.Duration
}

// uplinkBand is the one-line summary at the top of the landing page.
//
// It carries each figure twice. The strings are the long form — "5.70 ms p50 /
// 6.29 ms p95" — and are what the detail page prints, where the reader came
// for numbers. Meters are the same readings as bars, and are what the status
// page shows: that page is opened to answer "is the line all right", and a row
// of five measurements answers it slower than five bars do.
type uplinkBand struct {
	State     string
	StateText string
	Latency   string
	Jitter    string
	Loss      string
	Transit   string
	Flaps     string
	Meters    []meter
	Sparkline template.HTML
}

// meter is one band figure reduced to what a bar needs: a short value, how
// full the bar is, where "good" ends on it, and which side of that the reading
// falls. Title keeps the long form for the tooltip, so nothing the band used
// to say is actually lost.
type meter struct {
	Label string
	Value string
	Title string
	// All 0-100, as a percentage of the bar's width.
	//
	// GoodStart and GoodWidth delimit the normal range as a shaded band on the
	// track, rather than marking one edge of it with a tick. A single tick was
	// ambiguous and demonstrably so: it meant "the good range ends here" on
	// these bars and "this is the ideal value" on the fibre ones, which are
	// different claims drawn identically. A band says which part of the track
	// is fine and needs no legend to do it.
	Fill      int
	GoodStart int
	GoodWidth int
	// meterOK, meterWarn, meterBad or meterUnknown.
	State string
}

const (
	meterOK      = "ok"
	meterWarn    = "warn"
	meterBad     = "bad"
	meterUnknown = "unknown"
)

// Where each bar's good range ends and where the bar itself ends. The second
// number is both the "this is a fault" threshold and the full-scale value, so
// a bar that is full is a bar that is bad — there is no reading that fills it
// while still being fine.
//
// Chosen for this line rather than in the abstract: the core anchors are
// in-country and answer in single-digit milliseconds, so 30 ms of p95 already
// means something is queueing. Loss reuses the 2% that opens a degradation
// episode in uplink.go, so the bar and the event log cannot disagree about
// what a bad minute is. Transit is judged loosely because it crosses an ocean
// and a submarine cable reroute is not this router's fault.
const (
	meterLatencyGood, meterLatencyLimit = 30.0, 60.0
	meterJitterGood, meterJitterLimit   = 5.0, 15.0
	meterLossGood, meterLossLimit       = 0.5, episodeLossThreshold * 100
	meterTransitGood, meterTransitLimit = 120.0, 250.0
	// Any dropped session is worth seeing, so the good range is zero: one flap
	// puts the bar a third of the way along and out of the good zone.
	meterFlapsGood, meterFlapsLimit = 0.0, 3.0
)

// newMeter builds a bar from a reading and its two thresholds.
func newMeter(label, value, title string, reading, good, limit float64) meter {
	bar := meter{Label: label, Value: value, Title: title, State: meterOK}
	switch {
	case reading > limit:
		bar.State = meterBad
	case reading > good:
		bar.State = meterWarn
	}
	bar.Fill = scaleToBar(reading, limit)
	// One-sided: everything from empty up to the threshold is fine, so the
	// band starts at zero.
	bar.GoodStart, bar.GoodWidth = 0, scaleToBar(good, limit)
	// A healthy line reads near zero on every bar, and an empty track looks
	// like a missing measurement rather than a good one. A sliver says "this
	// was measured, and it is nowhere near the limit".
	if bar.Fill < 2 {
		bar.Fill = 2
	}
	return bar
}

func scaleToBar(value, limit float64) int {
	if limit <= 0 || value <= 0 {
		return 0
	}
	if value >= limit {
		return 100
	}
	return int(value / limit * 100)
}

// unknownMeter is the bar for a figure the history cannot answer yet. Empty
// rather than zero-and-green: "not measured" and "measured, excellent" are the
// two readings this page must never confuse.
func unknownMeter(label string) meter {
	return meter{Label: label, Value: "—", Title: "not measured yet", State: meterUnknown}
}

// band builds the summary. Every field degrades to an em dash rather than
// failing: the landing page predates this feature and must still render when
// the history is empty, the database is unreadable, or the prober has been
// running for less than a minute.
func (s *uplinkService) band() *uplinkBand {
	now := time.Now()
	band := &uplinkBand{
		State:     stateUnknown,
		StateText: "measuring",
		Latency:   "—",
		Jitter:    "—",
		Loss:      "—",
		Transit:   "—",
		Flaps:     "—",
	}

	if !s.prober.linkUp() {
		band.State = stateDown
		band.StateText = "link down"
	}

	// Every bar starts unknown and is replaced only by a reading that actually
	// arrived, so a store that cannot answer leaves an empty track rather than
	// a green one.
	latency, jitter, loss, transit := unknownMeter("Latency"), unknownMeter("Jitter"),
		unknownMeter("Loss 24h"), unknownMeter("Transit")
	flaps := unknownMeter("Drops 24h")

	// The core anchors carry the headline latency. The peer is excluded on
	// purpose — its RTT measures the access node's control plane, not the
	// line. See the comment at the top of uplink.go.
	core := s.bestWithRole(roleCore)
	if core != "" {
		if row, ok, err := s.store.latest(core); err != nil {
			log.Printf("uplink: band latest: %v", err)
		} else if ok && row.Received > 0 {
			band.Latency = fmt.Sprintf("%s p50 / %s p95", formatMillis(row.RTTP50), formatMillis(row.RTTP95))
			band.Jitter = formatMillis(row.Jitter)
			// The bar is judged on p95, not the median: the median is what the
			// line does when nothing is happening, and p95 is what someone on a
			// call actually notices.
			latency = newMeter("Latency", formatMillisCompact(row.RTTP95), band.Latency+" to "+core,
				row.RTTP95, meterLatencyGood, meterLatencyLimit)
			jitter = newMeter("Jitter", formatMillisCompact(row.Jitter), band.Jitter+" to "+core,
				row.Jitter, meterJitterGood, meterJitterLimit)
			if band.State == stateUnknown {
				band.State, band.StateText = stateOK, "healthy"
			}
		}

		if sent, received, err := s.store.lossSince(core, now.Add(-bandWindow)); err != nil {
			log.Printf("uplink: band loss: %v", err)
		} else if sent > 0 {
			pct := float64(sent-received) / float64(sent) * 100
			band.Loss = fmt.Sprintf("%.2f%% of %d", pct, sent)
			loss = newMeter("Loss 24h", formatPercentCompact(pct), band.Loss+" probes to "+core,
				pct, meterLossGood, meterLossLimit)
		}

		if rows, err := s.store.since(core, now.Add(-bandWindow)); err != nil {
			log.Printf("uplink: band history: %v", err)
		} else {
			band.Sparkline = sparkline(rows, 320, 28)
		}
	}

	// Named as well as timed: with several transit anchors "78 ms p50" alone
	// does not say which continent answered it. The bar drops the name into the
	// tooltip — on the status page the question is whether the number is fine,
	// and which anchor produced it is a detail-page concern.
	if name := s.bestWithRole(roleTransit); name != "" {
		if row, ok, err := s.store.latest(name); err != nil {
			log.Printf("uplink: band transit: %v", err)
		} else if ok && row.Received > 0 {
			band.Transit = fmt.Sprintf("%s p50 (%s)", formatMillis(row.RTTP50), name)
			transit = newMeter("Transit", formatMillisCompact(row.RTTP50), band.Transit,
				row.RTTP50, meterTransitGood, meterTransitLimit)
		}
	}

	if count, err := s.store.countEvents(eventPPPDown, now.Add(-bandWindow)); err != nil {
		log.Printf("uplink: band flaps: %v", err)
	} else {
		band.Flaps = fmt.Sprintf("%d in 24h", count)
		flaps = newMeter("Drops 24h", strconv.Itoa(count),
			fmt.Sprintf("%d PPP session drops in the last 24 hours", count),
			float64(count), meterFlapsGood, meterFlapsLimit)
	}

	band.Meters = []meter{latency, jitter, loss, transit, flaps}

	// A degraded anchor downgrades the state, but never upgrades a down link.
	if band.State != stateDown {
		for _, snapshot := range s.prober.snapshots() {
			if snapshot.Degraded {
				band.State, band.StateText = stateDegraded, "degraded: "+snapshot.Name
				break
			}
		}
	}

	return band
}

// bestWithRole picks the anchor of a role to headline with: the one with the
// lowest recent median.
//
// Lowest rather than first-configured, because config order carries no
// meaning and the band would otherwise report whichever anchor happened to be
// typed first. Lowest rather than an average, because one sick anchor must not
// make a healthy line look broken — a genuinely degraded uplink degrades all
// of them, and the detail page shows each separately regardless.
//
// For transit this also makes the figure mean something specific: the nearest
// international path. With anchors in Europe, India and the US the average
// would be a number describing nowhere, while the minimum answers "how far
// away is the first place off this continent".
//
// A target with no completed minute is a candidate of last resort, so a band
// rendered in the first minute after a restart names something rather than
// falling back to an em dash for every field.
func (s *uplinkService) bestWithRole(role string) string {
	best, bestRTT := "", 0.0
	for _, snapshot := range s.prober.snapshots() {
		// Best effort only. Headlining a Voice-marked probe would report the
		// one queue almost no traffic uses, which is the whole reason that
		// target is a second opinion rather than the primary.
		if snapshot.Role != role || snapshot.Tin != tinBestEffort {
			continue
		}
		row, ok, err := s.store.latest(snapshot.Name)
		if err != nil || !ok || row.Received == 0 {
			if best == "" {
				best = snapshot.Name
			}
			continue
		}
		if bestRTT == 0 || row.RTTP50 < bestRTT {
			best, bestRTT = snapshot.Name, row.RTTP50
		}
	}
	return best
}

// What the detail page renders for one target.
type uplinkTargetView struct {
	Name    string
	Role    string
	Tin     string
	Address string
	// Why this target is here and what it can be trusted to say. Rendered on
	// the page because the peer row is otherwise the most misleading number on
	// it: consistently the worst jitter, and consistently not a fault.
	Note string
	// The live probe, fresher than the store by up to a minute.
	Live     string
	LiveOK   bool
	Baseline string

	Sent     int
	Lost     int
	Loss     string
	P50      string
	P95      string
	Max      string
	Jitter   string
	Idle     string
	Loaded   string
	PeakDown string

	Sparkline template.HTML
}

type uplinkEventView struct {
	Started  string
	Duration string
	Kind     string
	Target   string
	Detail   string
	Ongoing  bool
}

type uplinkDayView struct {
	Day    string
	Target string
	Loss   string
	P50    string
	P95    string
	Max    string
}

type uplinkPageData struct {
	Nav           navData
	Hostname      string
	Generated     string
	Band          *uplinkBand
	Targets       []uplinkTargetView
	Events        []uplinkEventView
	Days          []uplinkDayView
	RetentionDays int
	// The fibre terminal. Nil when no ONT is configured, which keeps the whole
	// section out of the page rather than rendering an empty graph.
	ONT *ontReport
	// The receive-power trace. Empty until there are at least two readings to
	// draw a line between, which on a fresh router is the first few minutes.
	ONTHistory    template.HTML
	ONTSpan       string
	ONTWindowDays int
}

const targetNotes = "" +
	"reachability only — its latency and jitter measure the access node's control plane, not the line"

func roleNote(role, tin string) string {
	if tin == tinVoice {
		// Stated on the row because this target is meaningless read alone —
		// it is low by construction, and only the gap against its best-effort
		// twin carries information.
		return "the same address marked into the Voice tin: compare against its best-effort twin, do not read alone"
	}
	switch role {
	case rolePeer:
		return targetNotes
	case roleCore:
		return "in-country: the ISP's own network"
	case roleTransit:
		return "abroad: international transit and peering"
	}
	return ""
}

// pageHandler binds the nav strip to the listener this handler is registered
// on. The uplink page is served on both, and only the listener knows whether
// the devices section is reachable from it — the service is one object shared
// by both and cannot tell them apart.
func (s *uplinkService) pageHandler(nav navSource, ont *ontMonitor, showPeers bool) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		s.handlePage(w, r, nav.data("uplink", showPeers), ont)
	}
}

func (s *uplinkService) handlePage(w http.ResponseWriter, r *http.Request, nav navData, ont *ontMonitor) {
	if r.URL.Path != "/uplink" && r.URL.Path != "/uplink/" {
		http.NotFound(w, r)
		return
	}

	hostname, err := os.Hostname()
	if err != nil || strings.TrimSpace(hostname) == "" {
		hostname = "unavailable"
	}

	now := time.Now()
	data := uplinkPageData{
		Nav:           nav,
		Hostname:      hostname,
		Generated:     now.Format("2006-01-02 15:04:05 MST"),
		Band:          s.band(),
		RetentionDays: int(s.retention.Hours() / 24),
	}

	for _, snapshot := range s.prober.snapshots() {
		view := uplinkTargetView{
			Name:    snapshot.Name,
			Role:    snapshot.Role,
			Tin:     snapshot.Tin,
			Address: snapshot.Address,
			Note:    roleNote(snapshot.Role, snapshot.Tin),
			Live:    "no reply",
			Loss:    "—", P50: "—", P95: "—", Max: "—", Jitter: "—",
			Idle: "—", Loaded: "—", PeakDown: "—", Baseline: "—",
		}
		if snapshot.LastOK {
			view.Live, view.LiveOK = formatMillis(float64(snapshot.LastRTT)/float64(time.Millisecond)), true
		} else if snapshot.LostRun > 0 {
			view.Live = fmt.Sprintf("%d lost in a row", snapshot.LostRun)
		}

		rows, err := s.store.since(snapshot.Name, now.Add(-detailWindow))
		if err != nil {
			log.Printf("uplink: page history %s: %v", snapshot.Name, err)
		}
		summarise(&view, rows)
		view.Sparkline = sparkline(rows, 720, 48)

		if value, ok, err := s.store.baseline(snapshot.Name, now.Add(-baselineWindow)); err == nil && ok {
			view.Baseline = formatMillis(value)
		}

		data.Targets = append(data.Targets, view)
	}

	events, err := s.store.events(now.Add(-eventWindow), eventLimit)
	if err != nil {
		log.Printf("uplink: page events: %v", err)
	}
	for _, event := range events {
		view := uplinkEventView{
			Started: event.TS.Format("2006-01-02 15:04"),
			Kind:    event.Kind,
			Target:  event.Target,
			Detail:  event.Detail,
		}
		if event.Ended.IsZero() {
			view.Ongoing = true
			view.Duration = "ongoing"
		} else {
			view.Duration = formatDuration(event.Ended.Sub(event.TS))
		}
		data.Events = append(data.Events, view)
	}

	// The fibre, from the other end of the same line. The band is the live
	// reading, identical to the one on the status page; the graph below it is
	// what this page exists for and the status page deliberately has not got.
	data.ONT = ont.report()
	if samples := ont.history(now.Add(-opticalWindow)); len(samples) > 1 {
		data.ONTHistory = opticalSparkline(samples, 720, 48)
		data.ONTSpan = describeOpticalSpan(samples)
		data.ONTWindowDays = int(opticalWindow / (24 * time.Hour))
	}

	_, offset := now.Zone()
	days, err := s.store.daily(now.Add(-dailyWindow), offset)
	if err != nil {
		log.Printf("uplink: page daily: %v", err)
	}
	for _, day := range days {
		data.Days = append(data.Days, uplinkDayView{
			Day:    day.Day.Format("2006-01-02"),
			Target: day.Target,
			Loss:   fmt.Sprintf("%.2f%%", day.Loss()*100),
			P50:    formatMillis(day.RTTP50),
			P95:    formatMillis(day.RTTP95),
			Max:    formatMillis(day.RTTMax),
		})
	}

	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	if err := s.tmpl.Execute(w, data); err != nil {
		log.Printf("uplink: render: %v", err)
	}
}

// summarise fills the aggregate columns for one target from its window.
//
// The idle and loaded figures are the point of the whole load-sampling
// exercise: the same p95 computed over the minutes when the line was nearly
// empty and the minutes when it was nearly full. A line with clean idle
// latency and loaded latency an order of magnitude worse is bufferbloat, which
// is a local queue-management problem and not something to raise with the ISP.
func summarise(view *uplinkTargetView, rows []minuteRow) {
	if len(rows) == 0 {
		return
	}

	var sent, received int
	var p50s, p95s, jitters []float64
	var maximum float64
	var peakDown uint64

	for _, row := range rows {
		sent += row.Sent
		received += row.Received
		if row.Received == 0 {
			continue
		}
		p50s = append(p50s, row.RTTP50)
		p95s = append(p95s, row.RTTP95)
		jitters = append(jitters, row.Jitter)
		if row.RTTMax > maximum {
			maximum = row.RTTMax
		}
		if row.DownPeak > peakDown {
			peakDown = row.DownPeak
		}
	}

	view.Sent = sent
	view.Lost = sent - received
	if sent > 0 {
		view.Loss = fmt.Sprintf("%.2f%%", float64(sent-received)/float64(sent)*100)
	}
	if len(p50s) == 0 {
		return
	}

	view.P50 = formatMillis(percentile(p50s, 0.50))
	view.P95 = formatMillis(percentile(p95s, 0.95))
	view.Max = formatMillis(maximum)
	view.Jitter = formatMillis(percentile(jitters, 0.50))
	view.PeakDown = formatBitrate(peakDown)

	if peakDown == 0 {
		return
	}

	// Thresholds as a fraction of the busiest minute seen in the window rather
	// than of a configured line rate: the configured rate is what CAKE was
	// told, and the question here is what the line was actually doing.
	const (
		idleBelow   = 0.10
		loadedAbove = 0.70
	)
	var idle, loaded []float64
	for _, row := range rows {
		if row.Received == 0 {
			continue
		}
		share := float64(row.DownPeak) / float64(peakDown)
		switch {
		case share < idleBelow:
			idle = append(idle, row.RTTP95)
		case share > loadedAbove:
			loaded = append(loaded, row.RTTP95)
		}
	}
	if len(idle) > 0 {
		view.Idle = formatMillis(percentile(idle, 0.50))
	}
	if len(loaded) > 0 {
		view.Loaded = formatMillis(percentile(loaded, 0.50))
	}
}

// opticalSparkline draws receive power over the window.
//
// Scaled to the readings rather than to the alarm window, which is the
// opposite of what the meters beside it do, and deliberate. On a healthy line
// every sample sits near the middle of a 20 dB window, so drawing the window
// would render every trace as the same flat line halfway up and the graph
// would be decoration. The question here is "is it moving", and that needs an
// axis that fits the data. The span is printed next to it so a trace that
// looks dramatic cannot be mistaken for a large change.
//
// Minutes where the PON was down are marked rather than drawn through: a line
// interpolated across an outage is a line claiming a measurement that was
// never taken.
func opticalSparkline(samples []opticalSample, width, height int) template.HTML {
	if len(samples) < 2 {
		return template.HTML(fmt.Sprintf(
			`<svg class="spark" viewBox="0 0 %d %d" width="%d" height="%d" role="img" aria-label="no optical history yet"></svg>`,
			width, height, width, height))
	}

	first := samples[0].TS.Unix()
	last := samples[len(samples)-1].TS.Unix()
	span := float64(last - first)
	if span <= 0 {
		span = 1
	}

	lo, hi := math.Inf(1), math.Inf(-1)
	for _, s := range samples {
		if !s.PONUp {
			continue
		}
		lo = math.Min(lo, s.Rx)
		hi = math.Max(hi, s.Rx)
	}
	if math.IsInf(lo, 1) {
		lo, hi = 0, 1
	}
	// A line that has not moved at all would divide by zero and, worse, would
	// draw at whatever height the rounding happened to give. Pad it into a
	// visible band centred on the reading.
	if hi-lo < 0.2 {
		mid := (hi + lo) / 2
		lo, hi = mid-0.1, mid+0.1
	}

	var line strings.Builder
	var marks strings.Builder
	for _, s := range samples {
		x := float64(s.TS.Unix()-first) / span * float64(width)
		if !s.PONUp {
			fmt.Fprintf(&marks, `<rect x="%.1f" y="0" width="1.5" height="%d" class="spark-loss"/>`, x, height)
			continue
		}
		// More light is up, which is the way round everyone expects even
		// though the numbers are negative.
		frac := (s.Rx - lo) / (hi - lo)
		y := float64(height) - frac*float64(height-2) - 1
		if line.Len() > 0 {
			line.WriteByte(' ')
		}
		fmt.Fprintf(&line, "%.1f,%.1f", x, y)
	}

	return sparkWithAxis(fmt.Sprintf("%.1f", hi), fmt.Sprintf("%.1f", lo), fmt.Sprintf(
		`<svg class="spark" viewBox="0 0 %d %d" width="%d" height="%d" preserveAspectRatio="none" role="img" `+
			`aria-label="receive power over time, %.1f to %.1f dBm">`+
			`%s<polyline class="spark-line" fill="none" points="%s"/></svg>`,
		width, height, width, height, lo, hi, marks.String(), line.String()))
}

// describeOpticalSpan states what the trace's axis actually covers, so a
// steep-looking line can be read as the fraction of a dB it usually is.
func describeOpticalSpan(samples []opticalSample) string {
	lo, hi := math.Inf(1), math.Inf(-1)
	counted := 0
	for _, s := range samples {
		if !s.PONUp {
			continue
		}
		lo = math.Min(lo, s.Rx)
		hi = math.Max(hi, s.Rx)
		counted++
	}
	if counted == 0 {
		return "no readings with the fibre up"
	}
	return fmt.Sprintf("%.2f to %.2f dBm across %d readings", lo, hi, counted)
}

// sparkWithAxis puts the two ends of the vertical scale beside a trace.
//
// The numbers are HTML rather than <text> inside the SVG, and that is forced
// rather than stylistic. These traces stretch to the width of the page with
// preserveAspectRatio="none", which scales the viewBox non-uniformly — any
// text inside would be stretched with it and render squashed or smeared
// depending on the window. Putting them outside also means they are real text
// at the page's own font size rather than 9px scaled by whatever the browser
// happened to choose.
//
// Two numbers rather than a full axis, and no time labels at all: the heading
// already says what window the trace covers, so the vertical scale is the only
// thing a reader cannot otherwise know. Without it a trace that moves a tenth
// of a dB and one that moves ten look identical, which makes the graph
// decorative.
func sparkWithAxis(top, bottom, svg string) template.HTML {
	return template.HTML(fmt.Sprintf(
		`<div class="spark-wrap"><span class="spark-axis spark-axis-top">%s</span>`+
			`<span class="spark-axis spark-axis-bot">%s</span>%s</div>`,
		template.HTMLEscapeString(top), template.HTMLEscapeString(bottom), svg))
}

// sparkline draws median latency over the window, with lost minutes marked.
//
// Inline SVG with no script and no external request: this page has to render
// on a LAN with no working uplink, which rules out a charting library from a
// CDN, and the router already serves everything else here as static HTML.
func sparkline(rows []minuteRow, width, height int) template.HTML {
	if len(rows) == 0 {
		return template.HTML(fmt.Sprintf(
			`<svg class="spark" viewBox="0 0 %d %d" width="%d" height="%d" role="img" aria-label="no history yet"></svg>`,
			width, height, width, height))
	}

	sort.Slice(rows, func(i, j int) bool { return rows[i].TS.Before(rows[j].TS) })

	first := rows[0].TS.Unix()
	last := rows[len(rows)-1].TS.Unix()
	span := float64(last - first)
	if span <= 0 {
		span = 1
	}

	// Scaled to the 95th percentile of the medians rather than the maximum, so
	// one cold-path spike does not flatten the whole trace into the baseline.
	scale := make([]float64, 0, len(rows))
	for _, row := range rows {
		if row.Received > 0 {
			scale = append(scale, row.RTTP50)
		}
	}
	top := percentile(scale, 0.95) * 1.3
	if top <= 0 {
		top = 1
	}

	var line strings.Builder
	var marks strings.Builder
	for _, row := range rows {
		x := float64(row.TS.Unix()-first) / span * float64(width)
		if row.Received == 0 {
			fmt.Fprintf(&marks, `<rect x="%.1f" y="0" width="1.5" height="%d" class="spark-loss"/>`, x, height)
			continue
		}
		value := row.RTTP50 / top
		if value > 1 {
			value = 1
		}
		y := float64(height) - value*float64(height-2) - 1
		if line.Len() > 0 {
			line.WriteByte(' ')
		}
		fmt.Fprintf(&line, "%.1f,%.1f", x, y)
	}

	label := fmt.Sprintf("median latency over %s, peak %s", formatDuration(time.Duration(span)*time.Second), formatMillis(top))
	return sparkWithAxis(formatMillisCompact(top), "0", fmt.Sprintf(
		`<svg class="spark" viewBox="0 0 %d %d" width="%d" height="%d" preserveAspectRatio="none" role="img" aria-label="%s">%s<polyline class="spark-line" points="%s"/></svg>`,
		width, height, width, height, template.HTMLEscapeString(label), marks.String(), line.String()))
}

// handleMetrics exports the same numbers to Prometheus.
//
// Served from the app rather than written as a node_exporter textfile, which
// is how the other two router collectors publish: those run as root from a
// timer, and this one runs under DynamicUser, which cannot write into the
// textfile directory (0755 root root). Alloy scrapes this endpoint instead.
func (s *uplinkService) handleMetrics(w http.ResponseWriter, _ *http.Request) {
	w.Header().Set("Content-Type", "text/plain; version=0.0.4; charset=utf-8")

	var out strings.Builder
	out.WriteString("# HELP router_uplink_link_up Whether the PPP session currently has an address.\n")
	out.WriteString("# TYPE router_uplink_link_up gauge\n")
	fmt.Fprintf(&out, "router_uplink_link_up %d\n", boolToInt(s.prober.linkUp()))

	out.WriteString("# HELP router_uplink_probes_sent_total Probes sent since this process started.\n")
	out.WriteString("# TYPE router_uplink_probes_sent_total counter\n")
	out.WriteString("# HELP router_uplink_probes_received_total Probes answered since this process started.\n")
	out.WriteString("# TYPE router_uplink_probes_received_total counter\n")
	out.WriteString("# HELP router_uplink_target_up Whether the most recent probe to a target was answered.\n")
	out.WriteString("# TYPE router_uplink_target_up gauge\n")
	out.WriteString("# HELP router_uplink_degraded Whether a target is inside an open degradation episode.\n")
	out.WriteString("# TYPE router_uplink_degraded gauge\n")

	snapshots := s.prober.snapshots()
	for _, snapshot := range snapshots {
		labels := metricLabels(snapshot)
		fmt.Fprintf(&out, "router_uplink_probes_sent_total%s %d\n", labels, snapshot.SentTotal)
		fmt.Fprintf(&out, "router_uplink_probes_received_total%s %d\n", labels, snapshot.ReceivedTotal)
		fmt.Fprintf(&out, "router_uplink_target_up%s %d\n", labels, boolToInt(snapshot.LastOK))
		fmt.Fprintf(&out, "router_uplink_degraded%s %d\n", labels, boolToInt(snapshot.Degraded))
	}

	out.WriteString("# HELP router_uplink_rtt_seconds Round-trip time over the last completed minute.\n")
	out.WriteString("# TYPE router_uplink_rtt_seconds gauge\n")
	out.WriteString("# HELP router_uplink_jitter_seconds Mean absolute difference between successive round-trip times.\n")
	out.WriteString("# TYPE router_uplink_jitter_seconds gauge\n")
	out.WriteString("# HELP router_uplink_load_peak_bits_per_second Peak WAN throughput during the last completed minute.\n")
	out.WriteString("# TYPE router_uplink_load_peak_bits_per_second gauge\n")

	for _, snapshot := range snapshots {
		row, ok, err := s.store.latest(snapshot.Name)
		if err != nil || !ok || row.Received == 0 {
			continue
		}
		labels := metricLabels(snapshot)
		trimmed := strings.TrimSuffix(labels, "}")
		fmt.Fprintf(&out, "router_uplink_rtt_seconds%s,quantile=\"0.5\"} %g\n", trimmed, row.RTTP50/1000)
		fmt.Fprintf(&out, "router_uplink_rtt_seconds%s,quantile=\"0.95\"} %g\n", trimmed, row.RTTP95/1000)
		fmt.Fprintf(&out, "router_uplink_rtt_seconds%s,quantile=\"1\"} %g\n", trimmed, row.RTTMax/1000)
		fmt.Fprintf(&out, "router_uplink_jitter_seconds%s %g\n", labels, row.Jitter/1000)
		fmt.Fprintf(&out, "router_uplink_load_peak_bits_per_second%s,direction=\"down\"} %d\n", trimmed, row.DownPeak)
		fmt.Fprintf(&out, "router_uplink_load_peak_bits_per_second%s,direction=\"up\"} %d\n", trimmed, row.UpPeak)
	}

	fmt.Fprint(w, out.String())
}

func metricLabels(snapshot targetSnapshot) string {
	return fmt.Sprintf("{target=%q,role=%q,tin=%q,address=%q}",
		snapshot.Name, snapshot.Role, snapshot.Tin, snapshot.Address)
}

func boolToInt(value bool) int {
	if value {
		return 1
	}
	return 0
}

// formatMillis renders a millisecond figure at a precision that matches how
// well it is known. Sub-millisecond RTTs are real on this link — the peer
// answers in under a millisecond — and rounding them to "1 ms" would erase the
// difference between a healthy access node and a busy one.
// formatMillisCompact is formatMillis narrowed to what fits beside a bar. Two
// decimals are right in a table of measurements and wrong next to a bar, where
// the bar carries the magnitude and the number is only there to be quoted.
func formatMillisCompact(value float64) string {
	switch {
	case value <= 0:
		return "—"
	case value < 10:
		return fmt.Sprintf("%.1f ms", value)
	default:
		return fmt.Sprintf("%.0f ms", value)
	}
}

// formatPercentCompact renders a loss percentage in at most four characters.
// Anything under a tenth of a percent becomes "<0.1%" rather than rounding to
// "0%": zero loss and nearly-zero loss look the same on the bar, and the label
// is the only place the difference can survive.
func formatPercentCompact(value float64) string {
	switch {
	case value <= 0:
		return "0%"
	case value < 0.1:
		return "<0.1%"
	case value < 10:
		return fmt.Sprintf("%.1f%%", value)
	default:
		return fmt.Sprintf("%.0f%%", value)
	}
}

func formatMillis(value float64) string {
	switch {
	case value <= 0:
		return "—"
	case value < 10:
		return fmt.Sprintf("%.2f ms", value)
	case value < 100:
		return fmt.Sprintf("%.1f ms", value)
	default:
		return fmt.Sprintf("%.0f ms", value)
	}
}

func formatBitrate(bits uint64) string {
	units := []string{"bit/s", "kbit/s", "Mbit/s", "Gbit/s"}
	size := float64(bits)
	unit := units[0]
	for _, next := range units[1:] {
		if size < 1000 {
			break
		}
		size /= 1000
		unit = next
	}
	if unit == "bit/s" {
		return fmt.Sprintf("%d %s", bits, unit)
	}
	return fmt.Sprintf("%.1f %s", size, unit)
}

func formatDuration(d time.Duration) string {
	switch {
	case d < time.Minute:
		return fmt.Sprintf("%ds", int(d.Seconds()))
	case d < time.Hour:
		return fmt.Sprintf("%dm", int(d.Minutes()))
	case d < 24*time.Hour:
		return fmt.Sprintf("%dh %dm", int(d.Hours()), int(d.Minutes())%60)
	default:
		return fmt.Sprintf("%dd %dh", int(d.Hours())/24, int(d.Hours())%24)
	}
}
