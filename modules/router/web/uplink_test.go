package main

import (
	"errors"
	"net"
	"net/netip"
	"strings"
	"testing"
	"time"
)

// Stands in for the interface being absent between pppd sessions.
var errNoInterface = errors.New("no such interface")

func TestParsePPPAddresses(t *testing.T) {
	tests := []struct {
		name      string
		output    string
		wantLocal string
		wantPeer  string
		wantOK    bool
	}{
		{
			// Real output from the router this was built for. The whole reason
			// the peer is parsed rather than assumed is visible here: the two
			// addresses are in adjacent /22s and look interchangeable, and
			// probing the local one answers in 48 microseconds over loopback
			// while looking like a healthy result.
			name: "point to point session",
			output: `12: ppp0: <POINTOPOINT,MULTICAST,NOARP,UP,LOWER_UP> mtu 1492 qdisc noqueue state UNKNOWN group default qlen 3
    inet 217.164.183.46 peer 217.164.182.1/32 scope global ppp0
       valid_lft forever preferred_lft forever`,
			wantLocal: "217.164.183.46",
			wantPeer:  "217.164.182.1",
			wantOK:    true,
		},
		{
			// An ordinary interface has no peer. Returning the local address
			// as the peer here would be worse than returning nothing.
			name: "address without a peer",
			output: `2: enp2s0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc fq_codel state UP group default qlen 1000
    inet 10.20.0.1/16 brd 10.20.255.255 scope global enp2s0
       valid_lft forever preferred_lft forever`,
			wantOK: false,
		},
		{
			name:   "interface with no address at all",
			output: `12: ppp0: <POINTOPOINT,MULTICAST,NOARP> mtu 1492 qdisc noqueue state DOWN group default qlen 3`,
			wantOK: false,
		},
		{
			name:   "empty output",
			output: "",
			wantOK: false,
		},
		{
			name:   "truncated peer",
			output: "    inet 217.164.183.46 peer",
			wantOK: false,
		},
		{
			name:   "unparseable addresses",
			output: "    inet not-an-address peer also-not/32 scope global ppp0",
			wantOK: false,
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			local, peer, ok := parsePPPAddresses(test.output)
			if ok != test.wantOK {
				t.Fatalf("ok = %v, want %v", ok, test.wantOK)
			}
			if !ok {
				return
			}
			if local.String() != test.wantLocal {
				t.Errorf("local = %s, want %s", local, test.wantLocal)
			}
			if peer.String() != test.wantPeer {
				t.Errorf("peer = %s, want %s", peer, test.wantPeer)
			}
		})
	}
}

func TestParseAnchors(t *testing.T) {
	t.Run("valid list", func(t *testing.T) {
		anchors, err := parseAnchors("cloudflare|1.1.1.1|core|, google|8.8.8.8|core|voice ,lighthouse|139.84.173.48|transit|")
		if err != nil {
			t.Fatalf("unexpected error: %v", err)
		}
		if len(anchors) != 3 {
			t.Fatalf("got %d anchors, want 3", len(anchors))
		}
		if anchors[0].Name != "cloudflare" || anchors[0].Address.String() != "1.1.1.1" || anchors[0].Role != roleCore {
			t.Errorf("first anchor = %+v", anchors[0])
		}
		if anchors[2].Role != roleTransit {
			t.Errorf("third anchor role = %s, want %s", anchors[2].Role, roleTransit)
		}
		if anchors[0].Tin != tinBestEffort {
			t.Errorf("anchors default to the %s tin, got %q", tinBestEffort, anchors[0].Tin)
		}
		if anchors[0].PairVoice {
			t.Error("first anchor asked for a voice pair it did not request")
		}
		if !anchors[1].PairVoice {
			t.Error("second anchor did not request its voice pair")
		}
	})

	t.Run("empty spec", func(t *testing.T) {
		anchors, err := parseAnchors("")
		if err != nil {
			t.Fatalf("unexpected error: %v", err)
		}
		if len(anchors) != 0 {
			t.Fatalf("got %d anchors, want 0", len(anchors))
		}
	})

	// Every one of these is a drift between the NixOS option and this parser,
	// so each has to fail loudly rather than drop the anchor and leave a probe
	// silently not running.
	rejected := []struct {
		name string
		spec string
	}{
		{"missing pair field", "cloudflare|1.1.1.1|core"},
		{"unknown role", "cloudflare|1.1.1.1|edge|"},
		{"peer role is not configurable", "cloudflare|1.1.1.1|peer|"},
		{"reserved name", peerTargetName + "|1.1.1.1|core|"},
		{"reserved voice suffix", "cloudflare" + voiceSuffix + "|1.1.1.1|core|"},
		{"empty name", "|1.1.1.1|core|"},
		{"bad address", "cloudflare|1.1.1.999|core|"},
		{"ipv6 address", "cloudflare|2606:4700:4700::1111|core|"},
		{"hostname instead of address", "cloudflare|one.one.one.one|core|"},
		{"unknown pair value", "cloudflare|1.1.1.1|core|video"},
	}
	for _, test := range rejected {
		t.Run(test.name, func(t *testing.T) {
			if _, err := parseAnchors(test.spec); err == nil {
				t.Fatalf("parseAnchors(%q) succeeded, want an error", test.spec)
			}
		})
	}
}

func TestEchoRequestRoundTrip(t *testing.T) {
	packet := echoRequest(0x1234, 0x5678)

	if got := len(packet); got != 64 {
		t.Errorf("packet length = %d, want 64", got)
	}
	if packet[0] != 8 {
		t.Errorf("type = %d, want 8 (echo request)", packet[0])
	}

	// A correct checksum makes the ones-complement sum of the whole message
	// zero. This is the check the far end performs before replying, so getting
	// it wrong means silence rather than an error.
	if sum := internetChecksum(packet); sum != 0 {
		t.Errorf("checksum over the finished packet = %#04x, want 0", sum)
	}

	// Turn it into the reply the peer would send back and read it.
	packet[0] = 0
	id, seq, ok := parseEchoReply(packet)
	if !ok {
		t.Fatal("parseEchoReply rejected a well-formed reply")
	}
	if id != 0x1234 || seq != 0x5678 {
		t.Errorf("id/seq = %#04x/%#04x, want 0x1234/0x5678", id, seq)
	}
}

func TestParseEchoReply(t *testing.T) {
	reply := echoRequest(0xabcd, 7)
	reply[0] = 0

	t.Run("with an ipv4 header", func(t *testing.T) {
		// Linux hands a raw ICMP socket the IP header too. A 20-byte header
		// with IHL 5.
		header := make([]byte, 20)
		header[0] = 0x45
		id, seq, ok := parseEchoReply(append(header, reply...))
		if !ok || id != 0xabcd || seq != 7 {
			t.Fatalf("ok=%v id=%#04x seq=%d, want true/0xabcd/7", ok, id, seq)
		}
	})

	t.Run("with a header carrying options", func(t *testing.T) {
		header := make([]byte, 24)
		header[0] = 0x46 // IHL 6, so 24 bytes
		id, _, ok := parseEchoReply(append(header, reply...))
		if !ok || id != 0xabcd {
			t.Fatalf("ok=%v id=%#04x, want true/0xabcd", ok, id)
		}
	})

	rejected := map[string][]byte{
		"too short":               {0, 0, 0},
		"echo request not reply":  echoRequest(1, 1),
		"destination unreachable": {3, 0, 0, 0, 0, 0, 0, 0},
		// An IHL that runs past the buffer would panic a slice, so it has to
		// be rejected rather than trusted.
		"impossible header length": append([]byte{0x4f}, make([]byte, 19)...),
	}
	for name, packet := range rejected {
		t.Run(name, func(t *testing.T) {
			if _, _, ok := parseEchoReply(packet); ok {
				t.Fatalf("parseEchoReply accepted %s", name)
			}
		})
	}
}

func TestPercentile(t *testing.T) {
	tests := []struct {
		name     string
		values   []float64
		fraction float64
		want     float64
	}{
		{"empty", nil, 0.5, 0},
		{"single", []float64{4.2}, 0.95, 4.2},
		{"median of odd", []float64{3, 1, 2}, 0.5, 2},
		{"unsorted input", []float64{9, 1, 5, 3, 7}, 0.5, 5},
		{"p95 takes the top", []float64{1, 1, 1, 1, 1, 1, 1, 1, 1, 100}, 0.95, 100},
		{"zero fraction clamps to the first", []float64{1, 2, 3}, 0, 1},
		{"fraction of one takes the last", []float64{1, 2, 3}, 1, 3},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			if got := percentile(test.values, test.fraction); got != test.want {
				t.Errorf("percentile = %v, want %v", got, test.want)
			}
		})
	}
}

func TestMeanAbsoluteDifference(t *testing.T) {
	// The measurement that motivated this function: one cold-path punt in an
	// otherwise flat run. Standard deviation over these is about 82 ms and
	// describes nothing; the successive difference is dominated by the two
	// steps on and off the spike and still reports a line that is mostly calm.
	spiked := []float64{312, 1.47, 7.84, 8.67, 1.56}
	got := meanAbsoluteDifference(spiked)
	if got < 80 || got > 85 {
		t.Errorf("jitter across the punt = %v, want roughly 82", got)
	}

	flat := []float64{5.0, 5.1, 5.0, 5.1}
	if got := meanAbsoluteDifference(flat); got > 0.11 {
		t.Errorf("jitter across a flat run = %v, want under 0.11", got)
	}

	if got := meanAbsoluteDifference([]float64{1}); got != 0 {
		t.Errorf("jitter of one sample = %v, want 0", got)
	}
	if got := meanAbsoluteDifference(nil); got != 0 {
		t.Errorf("jitter of no samples = %v, want 0", got)
	}
}

func newTestTarget(role string) *uplinkTarget {
	return &uplinkTarget{
		anchor:  anchor{Name: "test", Role: role, Tin: tinBestEffort},
		addr:    netip.MustParseAddr("1.1.1.1"),
		pending: map[uint16]pendingProbe{},
		buckets: map[int64]*minuteBucket{},
	}
}

func TestTargetRecordAggregation(t *testing.T) {
	target := newTestTarget(roleCore)
	base := time.Date(2026, 8, 15, 10, 30, 0, 0, time.UTC)

	target.record(base.Add(1*time.Second), true, 5*time.Millisecond, 1000, 100)
	target.record(base.Add(2*time.Second), true, 7*time.Millisecond, 3000, 200)
	target.record(base.Add(3*time.Second), false, 0, 2000, 150)
	target.record(base.Add(4*time.Second), true, 6*time.Millisecond, 1000, 100)

	rows := target.takeReady(base.Add(2 * time.Minute))
	if len(rows) != 1 {
		t.Fatalf("got %d rows, want 1", len(rows))
	}

	row := rows[0]
	if row.Sent != 4 || row.Received != 3 {
		t.Errorf("sent/received = %d/%d, want 4/3", row.Sent, row.Received)
	}
	if row.Loss() != 0.25 {
		t.Errorf("loss = %v, want 0.25", row.Loss())
	}
	if row.RTTMin != 5 || row.RTTMax != 7 {
		t.Errorf("min/max = %v/%v, want 5/7", row.RTTMin, row.RTTMax)
	}
	if row.RTTP50 != 6 {
		t.Errorf("p50 = %v, want 6", row.RTTP50)
	}
	// Peaks, not averages: the busiest second in the minute is what the
	// latency has to be read against.
	if row.DownPeak != 3000 || row.UpPeak != 200 {
		t.Errorf("peaks = %d/%d, want 3000/200", row.DownPeak, row.UpPeak)
	}
	if !row.TS.Equal(base) {
		t.Errorf("row timestamp = %v, want %v", row.TS, base)
	}
}

func TestTargetRecordBucketsBySendTime(t *testing.T) {
	// A probe sent in the last second of a minute and lost two seconds later
	// belongs to the minute whose quality it was measuring, not to the one the
	// timeout fired in.
	target := newTestTarget(roleCore)
	sent := time.Date(2026, 8, 15, 10, 30, 59, 0, time.UTC)

	target.record(sent, false, 0, 0, 0)

	rows := target.takeReady(sent.Add(3 * time.Minute))
	if len(rows) != 1 {
		t.Fatalf("got %d rows, want 1", len(rows))
	}
	if got := rows[0].TS.Minute(); got != 30 {
		t.Errorf("bucketed into minute %d, want 30", got)
	}
}

func TestTargetWarmupDiscardsColdPathProbes(t *testing.T) {
	// The 312 ms first packet is the access node building forwarding state.
	// Recording it would put a spike in the history after every reconnect,
	// including the nightly redial.
	target := newTestTarget(roleCore)
	target.warmup = warmupProbes
	base := time.Date(2026, 8, 15, 10, 30, 0, 0, time.UTC)

	target.record(base.Add(1*time.Second), true, 312*time.Millisecond, 0, 0)
	target.record(base.Add(2*time.Second), true, 40*time.Millisecond, 0, 0)
	target.record(base.Add(3*time.Second), true, 20*time.Millisecond, 0, 0)
	target.record(base.Add(4*time.Second), true, 1470*time.Microsecond, 0, 0)

	rows := target.takeReady(base.Add(2 * time.Minute))
	if len(rows) != 1 {
		t.Fatalf("got %d rows, want 1", len(rows))
	}
	if rows[0].Sent != 1 {
		t.Errorf("sent = %d, want 1: the warmup probes should not be counted at all", rows[0].Sent)
	}
	if rows[0].RTTMax != 1.47 {
		t.Errorf("max = %v ms, want 1.47: the cold-path probe leaked into the history", rows[0].RTTMax)
	}
}

func TestSetAddressRearmsWarmup(t *testing.T) {
	target := newTestTarget(rolePeer)
	target.warmup = 0
	target.pending[1] = pendingProbe{sentAt: time.Now()}

	if changed := target.setAddress(netip.MustParseAddr("217.164.182.1")); !changed {
		t.Fatal("setAddress reported no change for a new address")
	}
	if target.warmup != warmupProbes {
		t.Errorf("warmup = %d, want %d after a peer change", target.warmup, warmupProbes)
	}
	// In-flight probes to the old peer must not be attributed to the new one.
	if len(target.pending) != 0 {
		t.Errorf("pending = %d, want 0 after a peer change", len(target.pending))
	}

	if changed := target.setAddress(netip.MustParseAddr("217.164.182.1")); changed {
		t.Error("setAddress reported a change for the same address")
	}
}

func TestTakeReadyLeavesIncompleteMinutes(t *testing.T) {
	target := newTestTarget(roleCore)
	now := time.Now()

	target.record(now, true, time.Millisecond, 0, 0)

	// The current minute is still accumulating and a probe sent in it may
	// still be answered. Writing it now would record a short minute.
	if rows := target.takeReady(now); len(rows) != 0 {
		t.Fatalf("got %d rows for the current minute, want 0", len(rows))
	}
	if rows := target.takeReady(now.Add(2 * time.Minute)); len(rows) != 1 {
		t.Fatalf("got %d rows once the minute was complete, want 1", len(rows))
	}
}

func TestLoadSampler(t *testing.T) {
	counters := map[string]uint64{"rx_bytes": 0, "tx_bytes": 0}
	present := true

	sampler := &loadSampler{
		iface: "ppp0",
		read: func(_, counter string) (uint64, error) {
			if !present {
				return 0, errNoInterface
			}
			return counters[counter], nil
		},
	}

	base := time.Date(2026, 8, 15, 10, 0, 0, 0, time.UTC)

	// The first sample only establishes a baseline; there is no interval to
	// divide by yet.
	sampler.sample(base)
	if down, up := sampler.rates(); down != 0 || up != 0 {
		t.Errorf("first sample rates = %d/%d, want 0/0", down, up)
	}

	counters["rx_bytes"] = 1_250_000 // 10 Mbit over one second
	counters["tx_bytes"] = 125_000   // 1 Mbit over one second
	sampler.sample(base.Add(time.Second))
	if down, up := sampler.rates(); down != 10_000_000 || up != 1_000_000 {
		t.Errorf("rates = %d/%d, want 10000000/1000000", down, up)
	}

	// pppd recreates the interface on reconnect, so the counters restart. A
	// naive delta would report a colossal negative rate as an enormous
	// positive one.
	counters["rx_bytes"] = 1000
	counters["tx_bytes"] = 500
	sampler.sample(base.Add(2 * time.Second))
	if down, up := sampler.rates(); down != 0 || up != 0 {
		t.Errorf("rates after a counter reset = %d/%d, want 0/0", down, up)
	}

	// And the interface disappearing entirely between sessions.
	present = false
	sampler.sample(base.Add(3 * time.Second))
	if down, up := sampler.rates(); down != 0 || up != 0 {
		t.Errorf("rates with no interface = %d/%d, want 0/0", down, up)
	}

	// Recovery starts a fresh baseline rather than diffing against a
	// pre-outage counter.
	present = true
	counters["rx_bytes"] = 2000
	sampler.sample(base.Add(4 * time.Second))
	if down, _ := sampler.rates(); down != 0 {
		t.Errorf("rates on the first sample after recovery = %d, want 0", down)
	}
	counters["rx_bytes"] = 2000 + 125_000
	sampler.sample(base.Add(5 * time.Second))
	if down, _ := sampler.rates(); down != 1_000_000 {
		t.Errorf("rates after recovery = %d, want 1000000", down)
	}
}

func TestFormatMillis(t *testing.T) {
	tests := []struct {
		value float64
		want  string
	}{
		// Sub-millisecond RTTs are real on this link; rounding them away would
		// erase the difference between a healthy access node and a busy one.
		{0.843, "0.84 ms"},
		{1.47, "1.47 ms"},
		{8.67, "8.67 ms"},
		{26.188, "26.2 ms"},
		{312.085, "312 ms"},
		{0, "—"},
		{-1, "—"},
	}

	for _, test := range tests {
		if got := formatMillis(test.value); got != test.want {
			t.Errorf("formatMillis(%v) = %q, want %q", test.value, got, test.want)
		}
	}
}

func TestFormatBitrate(t *testing.T) {
	tests := []struct {
		bits uint64
		want string
	}{
		{0, "0 bit/s"},
		{999, "999 bit/s"},
		{1_000_000, "1.0 Mbit/s"},
		{500_000_000, "500.0 Mbit/s"},
		{1_000_000_000, "1.0 Gbit/s"},
	}

	for _, test := range tests {
		if got := formatBitrate(test.bits); got != test.want {
			t.Errorf("formatBitrate(%d) = %q, want %q", test.bits, got, test.want)
		}
	}
}

func TestSummariseSeparatesIdleFromLoaded(t *testing.T) {
	base := time.Date(2026, 8, 15, 10, 0, 0, 0, time.UTC)
	var rows []minuteRow

	// Twenty quiet minutes at the line's real latency.
	for i := range 20 {
		rows = append(rows, minuteRow{
			TS: base.Add(time.Duration(i) * time.Minute), Sent: 60, Received: 60,
			RTTMin: 4.7, RTTP50: 5.2, RTTP95: 5.9, RTTMax: 6.8, DownPeak: 2_000_000,
		})
	}
	// Ten minutes at line rate, with latency an order of magnitude worse.
	for i := 20; i < 30; i++ {
		rows = append(rows, minuteRow{
			TS: base.Add(time.Duration(i) * time.Minute), Sent: 60, Received: 60,
			RTTMin: 6.0, RTTP50: 45, RTTP95: 120, RTTMax: 180, DownPeak: 100_000_000,
		})
	}

	var view uplinkTargetView
	summarise(&view, rows)

	if view.Sent != 1800 || view.Lost != 0 {
		t.Errorf("sent/lost = %d/%d, want 1800/0", view.Sent, view.Lost)
	}
	if view.Idle != "5.90 ms" {
		t.Errorf("idle p95 = %q, want \"5.90 ms\"", view.Idle)
	}
	if view.Loaded != "120 ms" {
		t.Errorf("loaded p95 = %q, want \"120 ms\"", view.Loaded)
	}
	if view.PeakDown != "100.0 Mbit/s" {
		t.Errorf("peak = %q, want \"100.0 Mbit/s\"", view.PeakDown)
	}
}

func TestSummariseEmptyAndAllLost(t *testing.T) {
	var empty uplinkTargetView
	summarise(&empty, nil)
	if empty.Sent != 0 || empty.Loss != "" {
		t.Errorf("summarising nothing filled fields: %+v", empty)
	}

	base := time.Date(2026, 8, 15, 10, 0, 0, 0, time.UTC)
	outage := uplinkTargetView{Loss: "—"}
	summarise(&outage, []minuteRow{
		{TS: base, Sent: 60, Received: 0},
		{TS: base.Add(time.Minute), Sent: 60, Received: 0},
	})
	if outage.Loss != "100.00%" {
		t.Errorf("loss = %q, want \"100.00%%\"", outage.Loss)
	}
	if outage.Lost != 120 {
		t.Errorf("lost = %d, want 120", outage.Lost)
	}
	// With no successful probe there is no latency to report, and a zero here
	// would render as a suspiciously fast line.
	if outage.P50 != "" {
		t.Errorf("p50 = %q, want empty when nothing was answered", outage.P50)
	}
}

func TestSparkline(t *testing.T) {
	t.Run("no history", func(t *testing.T) {
		// The landing page has to render before the first minute is written.
		got := string(sparkline(nil, 320, 28))
		if !strings.Contains(got, "<svg") {
			t.Errorf("empty sparkline is not an svg: %q", got)
		}
		if strings.Contains(got, "polyline") {
			t.Errorf("empty sparkline drew a line: %q", got)
		}
	})

	t.Run("marks lost minutes", func(t *testing.T) {
		base := time.Date(2026, 8, 15, 10, 0, 0, 0, time.UTC)
		rows := []minuteRow{
			{TS: base, Sent: 60, Received: 60, RTTP50: 5},
			{TS: base.Add(time.Minute), Sent: 60, Received: 0},
			{TS: base.Add(2 * time.Minute), Sent: 60, Received: 60, RTTP50: 6},
		}
		got := string(sparkline(rows, 320, 28))
		if !strings.Contains(got, "spark-loss") {
			t.Errorf("a fully lost minute was not marked: %q", got)
		}
		if !strings.Contains(got, "polyline") {
			t.Errorf("no line drawn: %q", got)
		}
	})

	t.Run("a single spike does not flatten the trace", func(t *testing.T) {
		// Scaled to p95 rather than the maximum, so one cold-path punt does
		// not compress every real value onto the baseline.
		base := time.Date(2026, 8, 15, 10, 0, 0, 0, time.UTC)
		rows := []minuteRow{{TS: base, Sent: 60, Received: 60, RTTP50: 312}}
		for i := 1; i < 40; i++ {
			rows = append(rows, minuteRow{
				TS: base.Add(time.Duration(i) * time.Minute), Sent: 60, Received: 60, RTTP50: 5,
			})
		}
		got := string(sparkline(rows, 320, 28))
		if strings.Contains(got, "aria-label=\"median latency over 39m, peak 406 ms\"") {
			t.Errorf("sparkline scaled to the spike: %q", got)
		}
	})
}

func TestExpandAnchors(t *testing.T) {
	anchors := []anchor{
		{Name: "cloudflare", Role: roleCore, Address: netip.MustParseAddr("1.1.1.1"), Tin: tinBestEffort},
		{Name: "google", Role: roleCore, Address: netip.MustParseAddr("8.8.8.8"), Tin: tinBestEffort, PairVoice: true},
	}

	got := expandAnchors(anchors)

	// The peer first, then each anchor with its twin immediately after it: the
	// two rows of a pair are only meaningful read against each other, so the
	// page must not separate them.
	wantNames := []string{peerTargetName, "cloudflare", "google", "google" + voiceSuffix}
	if len(got) != len(wantNames) {
		t.Fatalf("got %d targets (%v), want %d", len(got), got, len(wantNames))
	}
	for i, want := range wantNames {
		if got[i].Name != want {
			t.Errorf("target %d = %q, want %q", i, got[i].Name, want)
		}
	}

	if got[0].Role != rolePeer || got[0].Tin != tinBestEffort {
		t.Errorf("peer = %+v, want a best-effort liveness target", got[0])
	}

	twin := got[3]
	if twin.Tin != tinVoice {
		t.Errorf("twin tin = %q, want %q", twin.Tin, tinVoice)
	}
	// Same address, so the pair measures one path through two queues. A twin
	// pointing somewhere else would compare two unrelated things.
	if twin.Address != anchors[1].Address {
		t.Errorf("twin address = %s, want %s", twin.Address, anchors[1].Address)
	}
	if twin.Role != roleCore {
		t.Errorf("twin role = %q, want it to inherit %q", twin.Role, roleCore)
	}
	// Otherwise the twin would spawn a twin of its own.
	if twin.PairVoice {
		t.Error("twin still requests a pair")
	}

	if got[1].Tin != tinBestEffort {
		t.Errorf("unpaired anchor tin = %q, want %q", got[1].Tin, tinBestEffort)
	}
}

func TestExpandAnchorsWithNone(t *testing.T) {
	// The peer is probed even with nothing configured, so the page can always
	// say whether the session is carrying packets.
	got := expandAnchors(nil)
	if len(got) != 1 || got[0].Name != peerTargetName {
		t.Fatalf("got %+v, want just the peer", got)
	}
}

func TestNeedsVoice(t *testing.T) {
	prober := &uplinkProber{}

	if prober.needsVoice(expandAnchors([]anchor{{Name: "a", Role: roleCore}})) {
		t.Error("opened a voice socket for a config that asked for none")
	}
	if !prober.needsVoice(expandAnchors([]anchor{{Name: "a", Role: roleCore, PairVoice: true}})) {
		t.Error("no voice socket for a config that asked for one")
	}
}

func TestSocketForPicksTheMarkedSocket(t *testing.T) {
	// Stand-ins: socketFor only ever compares identity, never writes here.
	best, voice := &net.IPConn{}, &net.IPConn{}
	prober := &uplinkProber{conn: best, voiceConn: voice}

	beTarget := &uplinkTarget{anchor: anchor{Name: "a", Tin: tinBestEffort}}
	if got := prober.socketFor(beTarget); got != net.PacketConn(best) {
		t.Error("best-effort target did not use the unmarked socket")
	}

	voiceTarget := &uplinkTarget{anchor: anchor{Name: "a" + voiceSuffix, Tin: tinVoice}}
	if got := prober.socketFor(voiceTarget); got != net.PacketConn(voice) {
		t.Error("voice target did not use the marked socket")
	}

	// A voice target with no marked socket must fall back rather than
	// nil-panic; construction refuses this combination, so this is a guard.
	unpaired := &uplinkProber{conn: best}
	if got := unpaired.socketFor(voiceTarget); got != net.PacketConn(best) {
		t.Error("voice target with no voice socket did not fall back")
	}
}

func TestVoiceTOSIsExpeditedForwarding(t *testing.T) {
	// DSCP 46 (EF) sits in the top six bits of the TOS byte, and CAKE's
	// diffserv4 classifier reads it from there. Getting the shift wrong would
	// put the probe in some other tin and silently invalidate the whole
	// differential.
	if voiceTOS != 0xB8 {
		t.Errorf("voiceTOS = %#02x, want 0xb8 (DSCP EF << 2)", voiceTOS)
	}
	if voiceTOS>>2 != 46 {
		t.Errorf("DSCP = %d, want 46", voiceTOS>>2)
	}
}
