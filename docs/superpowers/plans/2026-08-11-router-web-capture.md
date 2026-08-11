# Peers-page packet capture Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a start/stop packet capture button to the router's per-device peers page, bounded at 200 MiB and 30 minutes, where stopping downloads the pcap in the same click.

**Architecture:** router-web spawns `tcpdump -w -` for one device and copies the pcap stream to a file through a copier that understands pcap record framing, so the size cap lands exactly on a record boundary. Only *running* captures are held in memory; a stopped capture is just its file on disk, which is what makes a router-web restart need no recovery code. Four routes on the existing mesh-only mux drive it.

**Tech Stack:** Go 1.24 (module `router-web`, no external dependencies), `html/template`, NixOS module (`modules/router/web.nix`), tcpdump from nixpkgs.

**Spec:** `docs/superpowers/specs/2026-08-11-router-web-capture-design.md`

## Global Constraints

- All work happens in `/home/humaid/repos/dotfiles`, on branch `master`.
- Go code lives in `modules/router/web/`. Run tests from that directory: `cd modules/router/web && go test ./...`.
- The module has **no external Go dependencies** and `vendorHash = null` in `package.nix`. Do not add any import outside the standard library.
- Every commit uses `git commit --no-gpg-sign` (the user's signing key is a hardware key that cannot be touched from an agent session).
- Commit messages follow the existing style in this directory: `router-web: <lowercase description>`.
- Size limit: **200 MiB** = `200 << 20` = 209715200 bytes. Duration limit: **30 minutes**. Retention: **24 hours**. Sweep interval: **1 hour**. Start grace window: **500 ms**.
- This repository is **public**. Never put a real device name, MAC, or per-person activity in code, tests, comments, or commit messages. Tests use the documentation ranges: LAN `192.168.0.0/24`, public peer `203.0.113.10`.
- Match the surrounding comment style in this package: comments explain *why* a decision was made, not what the line does. Look at `peers.go` and `shaping.go` before writing any.
- Run `gofmt -l .` in `modules/router/web` before every commit; it must print nothing.
- Where this plan's user-visible wording differs from the spec's (the spec writes the operator stop reason as "stopped by operator"; this plan uses `"stopped from the page"`), **this plan is the authority** — the tests assert the constants defined here.

---

## File Structure

| File | Responsibility |
| --- | --- |
| `modules/router/web/capture.go` | **New.** pcap stream framing, the capture manager (slots, limits, retention), and the tcpdump spawner. Everything about capture lifecycle. |
| `modules/router/web/capture_test.go` | **New.** Tests for the above. |
| `modules/router/web/peers.go` | **Modify.** Add the four HTTP routes, the `Capture` field on `peersPageData`, and extract the `Sec-Fetch-Site` check out of `handleAction` into a shared helper. |
| `modules/router/web/peers_test.go` | **Modify.** Route tests, and a test that the extracted CSRF helper still guards the existing actions. |
| `modules/router/web/peers.html` | **Modify.** The capture banner above the peers table. |
| `modules/router/web/main.go` | **Modify.** Construct the manager from `ROUTER_CAPTURE_DIR` and start the sweeper. |
| `modules/router/web.nix` | **Modify.** `CAP_NET_RAW`, `pkgs.tcpdump` on the service path, `StateDirectory`, `ROUTER_CAPTURE_DIR`. |

---

## Task 1: pcap stream framing

The piece that makes the 200 MiB cap exact. Pure functions over an `io.Reader`/`io.Writer` — no files, no processes, no manager.

**Files:**
- Create: `modules/router/web/capture.go`
- Create: `modules/router/web/capture_test.go`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `const pcapGlobalHeaderLen = 24`, `const pcapRecordHeaderLen = 16`, `const pcapMaxRecord = 262144`
  - `func pcapByteOrder(magic []byte) (binary.ByteOrder, error)`
  - `func pcapHeader(dst io.Writer, src io.Reader) (binary.ByteOrder, error)`
  - `func pcapRecords(dst io.Writer, src io.Reader, order binary.ByteOrder, limit uint64, count *atomic.Uint64) string`
  - `const stopReasonLimit = "reached the 200 MiB limit"`, `const stopReasonEOF = "capture ended"`
  - Test helper `func pcapStream(t *testing.T, order binary.ByteOrder, magic uint32, sizes ...int) []byte`

- [ ] **Step 1: Write the failing tests**

Create `modules/router/web/capture_test.go`:

```go
package main

import (
	"bytes"
	"encoding/binary"
	"sync/atomic"
	"testing"
)

// pcapStream builds a pcap byte stream in the given byte order, with one
// record per entry in sizes. Written by hand rather than captured from
// tcpdump so a test can say exactly where the cut should land.
func pcapStream(t *testing.T, order binary.ByteOrder, magic uint32, sizes ...int) []byte {
	t.Helper()
	var out bytes.Buffer
	header := make([]byte, pcapGlobalHeaderLen)
	order.PutUint32(header[0:4], magic)
	order.PutUint16(header[4:6], 2)  // version major
	order.PutUint16(header[6:8], 4)  // version minor
	order.PutUint32(header[16:20], 262144)
	order.PutUint32(header[20:24], 1) // LINKTYPE_ETHERNET
	out.Write(header)
	for i, size := range sizes {
		record := make([]byte, pcapRecordHeaderLen)
		order.PutUint32(record[0:4], uint32(1700000000+i))
		order.PutUint32(record[8:12], uint32(size))  // caplen
		order.PutUint32(record[12:16], uint32(size)) // origlen
		out.Write(record)
		out.Write(bytes.Repeat([]byte{byte(i + 1)}, size))
	}
	return out.Bytes()
}

func TestPcapByteOrderAcceptsAllFourMagics(t *testing.T) {
	for name, tc := range map[string]struct {
		order binary.ByteOrder
		magic uint32
	}{
		"micros little": {binary.LittleEndian, 0xa1b2c3d4},
		"micros big":    {binary.BigEndian, 0xa1b2c3d4},
		"nanos little":  {binary.LittleEndian, 0xa1b23c4d},
		"nanos big":     {binary.BigEndian, 0xa1b23c4d},
	} {
		t.Run(name, func(t *testing.T) {
			raw := make([]byte, 4)
			tc.order.PutUint32(raw, tc.magic)
			got, err := pcapByteOrder(raw)
			if err != nil {
				t.Fatalf("pcapByteOrder: %v", err)
			}
			if got.Uint32(raw) != tc.magic {
				t.Fatalf("byte order reads magic as %#x, want %#x", got.Uint32(raw), tc.magic)
			}
		})
	}
}

func TestPcapByteOrderRejectsNonPcap(t *testing.T) {
	if _, err := pcapByteOrder([]byte("tcpd")); err == nil {
		t.Fatal("pcapByteOrder accepted a stream that is not pcap")
	}
}

func TestPcapRecordsCutsAtTheLastWholeRecordUnderTheLimit(t *testing.T) {
	// Three 100-byte records: 24 header + 3*(16+100) = 372 bytes in full.
	// A limit of 300 admits two records (24 + 232 = 256) and refuses the
	// third, which would reach 372.
	stream := pcapStream(t, binary.LittleEndian, 0xa1b2c3d4, 100, 100, 100)
	src := bytes.NewReader(stream)
	var out bytes.Buffer
	var count atomic.Uint64

	order, err := pcapHeader(&out, src)
	if err != nil {
		t.Fatalf("pcapHeader: %v", err)
	}
	count.Store(pcapGlobalHeaderLen)
	reason := pcapRecords(&out, src, order, 300, &count)

	if reason != stopReasonLimit {
		t.Fatalf("reason = %q, want %q", reason, stopReasonLimit)
	}
	if out.Len() != 256 {
		t.Fatalf("wrote %d bytes, want 256 (header + two whole records)", out.Len())
	}
	if count.Load() != 256 {
		t.Fatalf("count = %d, want 256", count.Load())
	}
	if !bytes.Equal(out.Bytes(), stream[:256]) {
		t.Fatal("output is not a byte-for-byte prefix of the input stream")
	}
}

func TestPcapRecordsCopiesTheWholeStreamWhenItFits(t *testing.T) {
	stream := pcapStream(t, binary.BigEndian, 0xa1b23c4d, 40, 60)
	src := bytes.NewReader(stream)
	var out bytes.Buffer
	var count atomic.Uint64

	order, err := pcapHeader(&out, src)
	if err != nil {
		t.Fatalf("pcapHeader: %v", err)
	}
	count.Store(pcapGlobalHeaderLen)
	if reason := pcapRecords(&out, src, order, 1<<20, &count); reason != stopReasonEOF {
		t.Fatalf("reason = %q, want %q", reason, stopReasonEOF)
	}
	if !bytes.Equal(out.Bytes(), stream) {
		t.Fatalf("wrote %d bytes, want the whole %d-byte stream", out.Len(), len(stream))
	}
}

func TestPcapRecordsDropsARecordTruncatedMidPayload(t *testing.T) {
	// tcpdump killed between writing a record header and its payload. The
	// file must end at the last complete record, never mid-record.
	stream := pcapStream(t, binary.LittleEndian, 0xa1b2c3d4, 50, 50)
	truncated := stream[:len(stream)-20]
	src := bytes.NewReader(truncated)
	var out bytes.Buffer
	var count atomic.Uint64

	order, err := pcapHeader(&out, src)
	if err != nil {
		t.Fatalf("pcapHeader: %v", err)
	}
	count.Store(pcapGlobalHeaderLen)
	if reason := pcapRecords(&out, src, order, 1<<20, &count); reason != stopReasonEOF {
		t.Fatalf("reason = %q, want %q", reason, stopReasonEOF)
	}
	if want := pcapGlobalHeaderLen + pcapRecordHeaderLen + 50; out.Len() != want {
		t.Fatalf("wrote %d bytes, want %d (header + one whole record)", out.Len(), want)
	}
}

func TestPcapRecordsWritesHeaderOnlyWhenTheFirstRecordExceedsTheLimit(t *testing.T) {
	// A header-only pcap is a valid, empty capture. A partial first record
	// would be a file that will not open.
	stream := pcapStream(t, binary.LittleEndian, 0xa1b2c3d4, 500)
	src := bytes.NewReader(stream)
	var out bytes.Buffer
	var count atomic.Uint64

	order, err := pcapHeader(&out, src)
	if err != nil {
		t.Fatalf("pcapHeader: %v", err)
	}
	count.Store(pcapGlobalHeaderLen)
	if reason := pcapRecords(&out, src, order, 100, &count); reason != stopReasonLimit {
		t.Fatalf("reason = %q, want %q", reason, stopReasonLimit)
	}
	if out.Len() != pcapGlobalHeaderLen {
		t.Fatalf("wrote %d bytes, want %d (global header only)", out.Len(), pcapGlobalHeaderLen)
	}
}

func TestPcapRecordsStopsOnAnImpossibleCaplen(t *testing.T) {
	// A caplen larger than any snaplen means the stream has desynchronised.
	// Stopping keeps a valid file; trusting it would allocate wildly.
	stream := pcapStream(t, binary.LittleEndian, 0xa1b2c3d4, 10)
	binary.LittleEndian.PutUint32(stream[pcapGlobalHeaderLen+8:pcapGlobalHeaderLen+12], 1<<30)
	src := bytes.NewReader(stream)
	var out bytes.Buffer
	var count atomic.Uint64

	order, err := pcapHeader(&out, src)
	if err != nil {
		t.Fatalf("pcapHeader: %v", err)
	}
	count.Store(pcapGlobalHeaderLen)
	if reason := pcapRecords(&out, src, order, 1<<20, &count); reason != stopReasonEOF {
		t.Fatalf("reason = %q, want %q", reason, stopReasonEOF)
	}
	if out.Len() != pcapGlobalHeaderLen {
		t.Fatalf("wrote %d bytes, want %d (global header only)", out.Len(), pcapGlobalHeaderLen)
	}
}

func TestPcapHeaderRejectsAStreamThatIsNotPcap(t *testing.T) {
	var out bytes.Buffer
	src := bytes.NewReader([]byte("tcpdump: no such device eth9\n and more padding here"))
	if _, err := pcapHeader(&out, src); err == nil {
		t.Fatal("pcapHeader accepted stderr text as a pcap stream")
	}
	if out.Len() != 0 {
		t.Fatalf("wrote %d bytes from a stream that is not pcap, want 0", out.Len())
	}
}

func TestPcapHeaderRejectsAStreamShorterThanTheHeader(t *testing.T) {
	var out bytes.Buffer
	if _, err := pcapHeader(&out, bytes.NewReader([]byte{0xd4, 0xc3})); err == nil {
		t.Fatal("pcapHeader accepted a two-byte stream")
	}
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd modules/router/web && go test ./... 2>&1 | head -30`
Expected: compile failure — `undefined: pcapGlobalHeaderLen`, `undefined: pcapByteOrder`, `undefined: pcapHeader`, `undefined: pcapRecords`, `undefined: stopReasonLimit`, `undefined: stopReasonEOF`.

- [ ] **Step 3: Write the implementation**

Create `modules/router/web/capture.go`:

```go
package main

import (
	"encoding/binary"
	"fmt"
	"io"
	"sync/atomic"
)

// pcap stream layout. A capture file is a 24-byte global header followed by
// records, each a 16-byte header whose third word is the captured length,
// then that many bytes of packet.
const (
	pcapGlobalHeaderLen = 24
	pcapRecordHeaderLen = 16
	// libpcap's own sanity bound on a record. A caplen above it means the
	// stream has desynchronised rather than that a very large frame arrived,
	// and trusting it would allocate on a number taken from a damaged file.
	pcapMaxRecord = 262144
)

// Why a capture stopped. Shown on the peers page, so these read as sentences
// rather than as identifiers.
const (
	stopReasonLimit = "reached the 200 MiB limit"
	stopReasonEOF   = "capture ended"
)

// pcapByteOrder identifies a pcap stream from its first four bytes.
//
// The magic is a 32-bit constant written in the *writer's* native byte order,
// so which order reads it back correctly is what identifies the file. Both the
// microsecond and nanosecond variants are accepted: which one tcpdump emits
// depends on how it was built, and nothing here reads timestamps anyway.
func pcapByteOrder(magic []byte) (binary.ByteOrder, error) {
	const (
		micros = 0xa1b2c3d4
		nanos  = 0xa1b23c4d
	)
	if value := binary.LittleEndian.Uint32(magic); value == micros || value == nanos {
		return binary.LittleEndian, nil
	}
	if value := binary.BigEndian.Uint32(magic); value == micros || value == nanos {
		return binary.BigEndian, nil
	}
	return nil, fmt.Errorf("not a pcap stream: magic %x", magic)
}

// pcapHeader reads the global header, verifies the stream really is pcap, and
// copies the header to dst.
//
// Verifying here is what turns "tcpdump printed an error and exited" into a
// failed start rather than into a file on disk that will not open. Nothing is
// written unless the stream checks out.
func pcapHeader(dst io.Writer, src io.Reader) (binary.ByteOrder, error) {
	header := make([]byte, pcapGlobalHeaderLen)
	if _, err := io.ReadFull(src, header); err != nil {
		return nil, fmt.Errorf("read pcap header: %w", err)
	}
	order, err := pcapByteOrder(header[:4])
	if err != nil {
		return nil, err
	}
	if _, err := dst.Write(header); err != nil {
		return nil, fmt.Errorf("write pcap header: %w", err)
	}
	return order, nil
}

// pcapRecords copies whole packet records until the stream ends or the next
// record would take the file past limit, and reports which of the two
// happened. count carries the bytes written so far — seeded by the caller with
// the global header's length — so the peers page can report progress while
// this is still running.
//
// Each record is read into memory before any of it is written, so a stream
// that ends mid-record leaves the file ending at the last complete record
// rather than at a torn one. That matters because the ordinary way a capture
// stops is the process being killed, which lands mid-record about as often as
// not.
//
// A short read is the ordinary end of a capture and not an error: whatever
// reached disk is a valid file, and the caller has better context for saying
// why the stream ended than this loop does.
func pcapRecords(dst io.Writer, src io.Reader, order binary.ByteOrder, limit uint64, count *atomic.Uint64) string {
	header := make([]byte, pcapRecordHeaderLen)
	payload := make([]byte, pcapMaxRecord)
	written := count.Load()

	for {
		if _, err := io.ReadFull(src, header); err != nil {
			return stopReasonEOF
		}
		caplen := uint64(order.Uint32(header[8:12]))
		if caplen > pcapMaxRecord {
			return stopReasonEOF
		}
		if written+pcapRecordHeaderLen+caplen > limit {
			return stopReasonLimit
		}
		if _, err := io.ReadFull(src, payload[:caplen]); err != nil {
			return stopReasonEOF
		}
		if _, err := dst.Write(header); err != nil {
			return stopReasonEOF
		}
		if _, err := dst.Write(payload[:caplen]); err != nil {
			return stopReasonEOF
		}
		written += pcapRecordHeaderLen + caplen
		count.Store(written)
	}
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd modules/router/web && go test ./... -run 'TestPcap' -v`
Expected: all nine test functions PASS.

- [ ] **Step 5: Check formatting and commit**

```bash
cd /home/humaid/repos/dotfiles/modules/router/web
gofmt -l .
cd /home/humaid/repos/dotfiles
git add modules/router/web/capture.go modules/router/web/capture_test.go
git commit --no-gpg-sign -m "router-web: pcap record framing so a capture can be cut at an exact size"
```

`gofmt -l .` must print nothing before you commit.

---

## Task 2: Capture manager lifecycle

Slots, limits, and the state machine. Uses Task 1's framing. The `start` field is the seam that keeps every test off a real interface.

**Files:**
- Modify: `modules/router/web/capture.go`
- Modify: `modules/router/web/capture_test.go`

**Interfaces:**
- Consumes: `pcapHeader`, `pcapRecords`, `stopReasonLimit`, `stopReasonEOF`, `pcapGlobalHeaderLen` (Task 1); `formatBytes` from `main.go`.
- Produces:
  - `type captureSlot struct { State, Bytes, Limit, Elapsed, Stopped, Reason string }`
  - `type captureManager struct { ... }` with `start func(ctx context.Context, iface string, device netip.Addr) (io.ReadCloser, error)`, and exported-in-package fields `dir`, `iface`, `maxBytes`, `maxAge`, `retain`
  - `func newCaptureManager(dir, iface string) *captureManager`
  - `func (m *captureManager) Start(device netip.Addr) error`
  - `func (m *captureManager) Stop(device netip.Addr) error`
  - `func (m *captureManager) Get(device netip.Addr) captureSlot`
  - `func (m *captureManager) Open(device netip.Addr) (*os.File, os.FileInfo, error)`
  - `func (m *captureManager) Discard(device netip.Addr) error`
  - `func (m *captureManager) path(device netip.Addr) string`
  - `var errCaptureRunning`, `var errNoCapture`
  - `const captureIdle = "idle"`, `captureRunning = "running"`, `captureReady = "ready"`
  - `const stopReasonOperator`, `const stopReasonAge`
  - `const captureMaxBytes`, `captureMaxAge`, `captureRetain`, `captureSweepEvery`, `captureStartGrace`

- [ ] **Step 1: Write the failing tests**

Append to `modules/router/web/capture_test.go`. Add `"context"`, `"errors"`, `"io"`, `"net/netip"`, `"os"`, `"path/filepath"`, `"strings"`, `"testing"`, `"time"` to its imports as needed.

```go
// testManager builds a manager over a temporary directory whose captures are
// the given canned stream rather than a real interface.
func testManager(t *testing.T, stream []byte) *captureManager {
	t.Helper()
	manager := newCaptureManager(t.TempDir(), "lan0")
	manager.start = func(ctx context.Context, _ string, _ netip.Addr) (io.ReadCloser, error) {
		return &blockingStream{reader: bytes.NewReader(stream), ctx: ctx}, nil
	}
	return manager
}

// blockingStream serves a canned stream and then blocks until its context is
// cancelled, the way tcpdump sits waiting for the next packet. Without the
// block every capture would finish the instant it started and no test could
// observe a running one.
type blockingStream struct {
	reader *bytes.Reader
	ctx    context.Context
}

func (s *blockingStream) Read(p []byte) (int, error) {
	if s.reader.Len() > 0 {
		return s.reader.Read(p)
	}
	<-s.ctx.Done()
	return 0, io.EOF
}

func (s *blockingStream) Close() error { return nil }

// waitForState polls until the slot reaches want, so a test never sleeps on a
// fixed guess about how fast a goroutine ran.
func waitForState(t *testing.T, manager *captureManager, device netip.Addr, want string) captureSlot {
	t.Helper()
	deadline := time.Now().Add(2 * time.Second)
	var slot captureSlot
	for time.Now().Before(deadline) {
		slot = manager.Get(device)
		if slot.State == want {
			return slot
		}
		time.Sleep(2 * time.Millisecond)
	}
	t.Fatalf("slot state = %q after 2s, want %q", slot.State, want)
	return slot
}

var testDevice = netip.MustParseAddr("192.168.0.10")

func TestCaptureStartsAndReportsRunning(t *testing.T) {
	manager := testManager(t, pcapStream(t, binary.LittleEndian, 0xa1b2c3d4, 100, 100))
	if err := manager.Start(testDevice); err != nil {
		t.Fatalf("Start: %v", err)
	}
	t.Cleanup(func() { _ = manager.Stop(testDevice) })

	slot := manager.Get(testDevice)
	if slot.State != captureRunning {
		t.Fatalf("state = %q, want %q", slot.State, captureRunning)
	}
	if slot.Limit != formatBytes(captureMaxBytes) {
		t.Fatalf("limit = %q, want %q", slot.Limit, formatBytes(captureMaxBytes))
	}
}

func TestCaptureRefusesASecondStartForTheSameDevice(t *testing.T) {
	manager := testManager(t, pcapStream(t, binary.LittleEndian, 0xa1b2c3d4, 100))
	if err := manager.Start(testDevice); err != nil {
		t.Fatalf("Start: %v", err)
	}
	t.Cleanup(func() { _ = manager.Stop(testDevice) })

	if err := manager.Start(testDevice); !errors.Is(err, errCaptureRunning) {
		t.Fatalf("second Start returned %v, want errCaptureRunning", err)
	}
}

func TestCaptureRunsForTwoDevicesAtOnce(t *testing.T) {
	manager := testManager(t, pcapStream(t, binary.LittleEndian, 0xa1b2c3d4, 100))
	other := netip.MustParseAddr("192.168.0.20")
	for _, device := range []netip.Addr{testDevice, other} {
		if err := manager.Start(device); err != nil {
			t.Fatalf("Start %s: %v", device, err)
		}
		t.Cleanup(func() { _ = manager.Stop(device) })
	}
	for _, device := range []netip.Addr{testDevice, other} {
		if state := manager.Get(device).State; state != captureRunning {
			t.Fatalf("%s state = %q, want %q", device, state, captureRunning)
		}
	}
	if _, err := os.Stat(manager.path(other)); err != nil {
		t.Fatalf("second device has no capture file: %v", err)
	}
}

func TestCaptureStopLeavesAReadyFile(t *testing.T) {
	manager := testManager(t, pcapStream(t, binary.LittleEndian, 0xa1b2c3d4, 100, 100))
	if err := manager.Start(testDevice); err != nil {
		t.Fatalf("Start: %v", err)
	}
	// The records are copied by a goroutine; wait for them before stopping,
	// or this asserts on a race rather than on the feature.
	deadline := time.Now().Add(2 * time.Second)
	for manager.Get(testDevice).Bytes != formatBytes(pcapGlobalHeaderLen+2*(pcapRecordHeaderLen+100)) {
		if time.Now().After(deadline) {
			t.Fatalf("records never reached the file: %q", manager.Get(testDevice).Bytes)
		}
		time.Sleep(2 * time.Millisecond)
	}
	if err := manager.Stop(testDevice); err != nil {
		t.Fatalf("Stop: %v", err)
	}

	slot := manager.Get(testDevice)
	if slot.State != captureReady {
		t.Fatalf("state = %q, want %q", slot.State, captureReady)
	}
	if slot.Reason != stopReasonOperator {
		t.Fatalf("reason = %q, want %q", slot.Reason, stopReasonOperator)
	}
	raw, err := os.ReadFile(manager.path(testDevice))
	if err != nil {
		t.Fatalf("read capture: %v", err)
	}
	if want := pcapGlobalHeaderLen + 2*(pcapRecordHeaderLen+100); len(raw) != want {
		t.Fatalf("capture is %d bytes, want %d", len(raw), want)
	}
}

func TestCaptureStopWithoutACaptureIsRefused(t *testing.T) {
	manager := testManager(t, nil)
	if err := manager.Stop(testDevice); !errors.Is(err, errNoCapture) {
		t.Fatalf("Stop returned %v, want errNoCapture", err)
	}
}

func TestCaptureStopsItselfAtTheSizeLimit(t *testing.T) {
	manager := testManager(t, pcapStream(t, binary.LittleEndian, 0xa1b2c3d4, 100, 100, 100))
	manager.maxBytes = 300 // admits two of the three records

	if err := manager.Start(testDevice); err != nil {
		t.Fatalf("Start: %v", err)
	}
	slot := waitForState(t, manager, testDevice, captureReady)
	if slot.Reason != stopReasonLimit {
		t.Fatalf("reason = %q, want %q", slot.Reason, stopReasonLimit)
	}
	info, err := os.Stat(manager.path(testDevice))
	if err != nil {
		t.Fatalf("stat capture: %v", err)
	}
	if info.Size() != 256 {
		t.Fatalf("capture is %d bytes, want 256", info.Size())
	}
}

func TestCaptureStopsItselfAtTheTimeLimit(t *testing.T) {
	manager := testManager(t, pcapStream(t, binary.LittleEndian, 0xa1b2c3d4, 100))
	manager.maxAge = 50 * time.Millisecond

	if err := manager.Start(testDevice); err != nil {
		t.Fatalf("Start: %v", err)
	}
	slot := waitForState(t, manager, testDevice, captureReady)
	if slot.Reason != stopReasonAge {
		t.Fatalf("reason = %q, want %q", slot.Reason, stopReasonAge)
	}
}

func TestCaptureStartFailsWhenTheStreamIsNotPcap(t *testing.T) {
	manager := newCaptureManager(t.TempDir(), "lan0")
	manager.start = func(context.Context, string, netip.Addr) (io.ReadCloser, error) {
		return io.NopCloser(strings.NewReader("tcpdump: lan0: No such device exists\n")), nil
	}
	if err := manager.Start(testDevice); err == nil {
		t.Fatal("Start succeeded on a stream that is not pcap")
	}
	if state := manager.Get(testDevice).State; state != captureIdle {
		t.Fatalf("state = %q after a failed start, want %q", state, captureIdle)
	}
	if _, err := os.Stat(manager.path(testDevice)); !os.IsNotExist(err) {
		t.Fatal("a failed start left a file behind")
	}
}

func TestCaptureStartFailsWhenTheProcessCannotBeSpawned(t *testing.T) {
	manager := newCaptureManager(t.TempDir(), "lan0")
	manager.start = func(context.Context, string, netip.Addr) (io.ReadCloser, error) {
		return nil, errors.New("exec: \"tcpdump\": executable file not found in $PATH")
	}
	if err := manager.Start(testDevice); err == nil {
		t.Fatal("Start succeeded when the process could not be spawned")
	}
	if state := manager.Get(testDevice).State; state != captureIdle {
		t.Fatalf("state = %q after a failed start, want %q", state, captureIdle)
	}
}

func TestCaptureReadsAReadyFileLeftByAPreviousProcess(t *testing.T) {
	// Restart recovery. A capture killed by a router-web restart leaves a
	// valid partial file and no in-memory state; it must read as ready.
	manager := testManager(t, nil)
	stream := pcapStream(t, binary.LittleEndian, 0xa1b2c3d4, 100)
	if err := os.WriteFile(manager.path(testDevice), stream, 0o600); err != nil {
		t.Fatalf("write capture: %v", err)
	}
	slot := manager.Get(testDevice)
	if slot.State != captureReady {
		t.Fatalf("state = %q, want %q", slot.State, captureReady)
	}
	if slot.Bytes != formatBytes(uint64(len(stream))) {
		t.Fatalf("bytes = %q, want %q", slot.Bytes, formatBytes(uint64(len(stream))))
	}
}

func TestCaptureOpenRefusesARunningOrAbsentCapture(t *testing.T) {
	manager := testManager(t, pcapStream(t, binary.LittleEndian, 0xa1b2c3d4, 100))

	if _, _, err := manager.Open(testDevice); !errors.Is(err, errNoCapture) {
		t.Fatalf("Open with no capture returned %v, want errNoCapture", err)
	}
	if err := manager.Start(testDevice); err != nil {
		t.Fatalf("Start: %v", err)
	}
	t.Cleanup(func() { _ = manager.Stop(testDevice) })
	if _, _, err := manager.Open(testDevice); !errors.Is(err, errCaptureRunning) {
		t.Fatalf("Open on a running capture returned %v, want errCaptureRunning", err)
	}
}

func TestCaptureDiscardRemovesTheFileAndTheReason(t *testing.T) {
	manager := testManager(t, pcapStream(t, binary.LittleEndian, 0xa1b2c3d4, 100))
	if err := manager.Start(testDevice); err != nil {
		t.Fatalf("Start: %v", err)
	}
	if err := manager.Stop(testDevice); err != nil {
		t.Fatalf("Stop: %v", err)
	}
	if err := manager.Discard(testDevice); err != nil {
		t.Fatalf("Discard: %v", err)
	}
	slot := manager.Get(testDevice)
	if slot.State != captureIdle {
		t.Fatalf("state = %q, want %q", slot.State, captureIdle)
	}
	if slot.Reason != "" {
		t.Fatalf("reason = %q after discard, want empty", slot.Reason)
	}
	if _, err := os.Stat(manager.path(testDevice)); !os.IsNotExist(err) {
		t.Fatal("discard left the file behind")
	}
}

func TestCaptureDiscardOfNothingSucceeds(t *testing.T) {
	// The button can be pressed twice, or after a sweep. Neither is an error.
	if err := testManager(t, nil).Discard(testDevice); err != nil {
		t.Fatalf("Discard: %v", err)
	}
}

func TestCaptureStartReplacesAReadyCapture(t *testing.T) {
	manager := testManager(t, pcapStream(t, binary.LittleEndian, 0xa1b2c3d4, 100))
	if err := os.WriteFile(manager.path(testDevice), []byte("stale"), 0o600); err != nil {
		t.Fatalf("write stale capture: %v", err)
	}
	if err := manager.Start(testDevice); err != nil {
		t.Fatalf("Start: %v", err)
	}
	t.Cleanup(func() { _ = manager.Stop(testDevice) })
	if state := manager.Get(testDevice).State; state != captureRunning {
		t.Fatalf("state = %q, want %q", state, captureRunning)
	}
}

func TestCaptureStopRacingStartNeitherPanicsNorHangs(t *testing.T) {
	// Stop reads entry.cancel and waits on entry.done, both of which must be
	// usable from the instant the slot is published — otherwise a stop
	// arriving while the capture is still opening either panics on a nil
	// cancel or blocks on a channel nobody will close.
	for i := 0; i < 50; i++ {
		manager := testManager(t, pcapStream(t, binary.LittleEndian, 0xa1b2c3d4, 100))
		done := make(chan struct{})
		go func() {
			defer close(done)
			_ = manager.Stop(testDevice)
		}()
		_ = manager.Start(testDevice)
		select {
		case <-done:
		case <-time.After(2 * time.Second):
			t.Fatalf("Stop racing Start hung on iteration %d", i)
		}
		_ = manager.Stop(testDevice)
	}
}

func TestCaptureStartFailureDoesNotStrandAStop(t *testing.T) {
	// A start that cannot even create its file must still release a Stop that
	// found the slot in the window before the failure.
	manager := newCaptureManager(filepath.Join(t.TempDir(), "file-not-a-dir"), "lan0")
	if err := os.WriteFile(manager.dir, []byte("x"), 0o600); err != nil {
		t.Fatalf("write blocker: %v", err)
	}
	if err := manager.Start(testDevice); err == nil {
		t.Fatal("Start succeeded with an unusable capture directory")
	}
	if state := manager.Get(testDevice).State; state != captureIdle {
		t.Fatalf("state = %q, want %q", state, captureIdle)
	}
}

func TestCapturePathIsBuiltFromTheParsedAddress(t *testing.T) {
	manager := testManager(t, nil)
	if got, want := manager.path(testDevice), filepath.Join(manager.dir, "192.168.0.10.pcap"); got != want {
		t.Fatalf("path = %q, want %q", got, want)
	}
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd modules/router/web && go test ./... 2>&1 | head -30`
Expected: compile failure — `undefined: newCaptureManager`, `undefined: captureRunning`, `undefined: errCaptureRunning`, and the rest of the identifiers listed under Interfaces.

- [ ] **Step 3: Write the implementation**

Append to `modules/router/web/capture.go`, and extend its import block to `"context"`, `"encoding/binary"`, `"errors"`, `"fmt"`, `"io"`, `"log"`, `"net/netip"`, `"os"`, `"os/exec"`, `"path/filepath"`, `"sync"`, `"sync/atomic"`, `"time"`.

```go
// Bounds on a capture. The size limit is the one the operator was promised;
// the age limit is what makes "autostops" true on a quiet device, which would
// otherwise never reach the size limit at all.
const (
	captureMaxBytes   = 200 << 20 // 200 MiB
	captureMaxAge     = 30 * time.Minute
	captureRetain     = 24 * time.Hour
	captureSweepEvery = time.Hour
	// How long Start waits for the stream to prove itself pcap. tcpdump emits
	// the global header immediately, so this is only ever spent on a failure —
	// which is the point: a missing binary or an unusable interface reports as
	// a failed start rather than as a running capture that is not running.
	captureStartGrace = 500 * time.Millisecond
)

// What a device's capture slot is doing.
const (
	captureIdle    = "idle"
	captureRunning = "running"
	captureReady   = "ready"
)

const (
	stopReasonOperator = "stopped from the page"
	stopReasonAge      = "reached the 30 minute limit"
)

var (
	errCaptureRunning = errors.New("a capture is already running for this device")
	errNoCapture      = errors.New("no capture for this device")
)

// captureSlot is what the peers page is told. Pre-formatted rather than raw
// numbers so the template stays free of logic, matching the rest of the page.
type captureSlot struct {
	State   string
	Bytes   string
	Limit   string
	Elapsed string
	Stopped string
	Reason  string
}

// capture is one running capture. Only running captures are held: a stopped
// one is its file on disk and nothing more, which is what lets a router-web
// restart need no recovery code.
type capture struct {
	device  netip.Addr
	path    string
	started time.Time
	bytes   atomic.Uint64
	// Set by Stop before the process is killed, so the copier can tell an
	// operator stop from the process dying on its own — both of which arrive
	// at the copier as nothing more than a closed pipe.
	stopped atomic.Bool
	cancel  context.CancelFunc
	done    chan struct{}
}

type captureManager struct {
	mu     sync.Mutex
	active map[netip.Addr]*capture
	// Why each device's waiting capture stopped. Lost on restart, which is
	// why it is kept apart from the state itself: the file answers "is there a
	// capture", this only decorates it.
	reasons  map[netip.Addr]string
	dir      string
	iface    string
	maxBytes uint64
	maxAge   time.Duration
	retain   time.Duration
	// start opens a pcap byte stream for one device. The seam that keeps every
	// test off a real interface.
	start func(ctx context.Context, iface string, device netip.Addr) (io.ReadCloser, error)
}

func newCaptureManager(dir, iface string) *captureManager {
	return &captureManager{
		active:   map[netip.Addr]*capture{},
		reasons:  map[netip.Addr]string{},
		dir:      dir,
		iface:    iface,
		maxBytes: captureMaxBytes,
		maxAge:   captureMaxAge,
		retain:   captureRetain,
		start:    startTcpdump,
	}
}

// path names a device's capture. Built from the parsed address rather than
// from request text, so no request can reach outside the capture directory.
func (m *captureManager) path(device netip.Addr) string {
	return filepath.Join(m.dir, device.String()+".pcap")
}

// Start begins a capture for one device.
//
// A capture already waiting to be downloaded is replaced rather than refused:
// the page warns before the button is pressed, and refusing would put an extra
// click on the common path of "capture that again, this time while it is
// happening".
func (m *captureManager) Start(device netip.Addr) error {
	// The context and its cancel are built before the slot is published, not
	// inside run: a Stop arriving in that window finds the entry in the map
	// and calls entry.cancel, which must not be nil when it does.
	ctx, cancel := context.WithTimeout(context.Background(), m.maxAge)
	entry := &capture{
		device:  device,
		path:    m.path(device),
		started: time.Now(),
		cancel:  cancel,
		done:    make(chan struct{}),
	}

	m.mu.Lock()
	if _, running := m.active[device]; running {
		m.mu.Unlock()
		cancel()
		return errCaptureRunning
	}
	// The slot is claimed before any slow work, so two posts arriving together
	// cannot both get past the check above.
	m.active[device] = entry
	delete(m.reasons, device)
	m.mu.Unlock()

	if err := m.run(ctx, entry); err != nil {
		m.mu.Lock()
		if m.active[device] == entry {
			delete(m.active, device)
		}
		m.mu.Unlock()
		return err
	}
	return nil
}

// run sets the capture going and reports whether it started.
//
// Every failure path before the copier exists closes entry.done itself. A Stop
// that raced the start is already blocked on that channel, and leaving it
// unclosed would block that request forever. The paths after the copier exists
// are closed by the copier's own defer, so nothing is closed twice.
func (m *captureManager) run(ctx context.Context, entry *capture) error {
	if err := os.MkdirAll(m.dir, 0o700); err != nil {
		entry.cancel()
		close(entry.done)
		return fmt.Errorf("capture directory: %w", err)
	}
	file, err := os.Create(entry.path)
	if err != nil {
		entry.cancel()
		close(entry.done)
		return fmt.Errorf("create capture file: %w", err)
	}

	stream, err := m.start(ctx, m.iface, entry.device)
	if err != nil {
		entry.cancel()
		file.Close()
		os.Remove(entry.path)
		close(entry.done)
		return fmt.Errorf("start capture: %w", err)
	}

	started := make(chan error, 1)
	go m.copy(ctx, entry, file, stream, started)

	select {
	case err := <-started:
		return err
	case <-time.After(captureStartGrace):
		// Header not seen yet and no failure either. Treated as a success: the
		// alternative is refusing a capture that is merely slow to start, and
		// a later failure still lands in the journal and on the page.
		return nil
	}
}

// copy drains the stream to the file and closes the slot when it ends. Runs
// for the whole life of the capture.
func (m *captureManager) copy(ctx context.Context, entry *capture, file *os.File, stream io.ReadCloser, started chan<- error) {
	defer close(entry.done)

	order, err := pcapHeader(file, stream)
	if err != nil {
		entry.cancel()
		stream.Close()
		file.Close()
		os.Remove(entry.path)
		wrapped := fmt.Errorf("capture produced no pcap stream: %w", err)
		// Cleared before the error is handed back, so a caller that retries
		// immediately does not meet its own abandoned slot. This also covers
		// the case where the grace window expired and nobody is listening.
		m.finish(entry, "")
		started <- wrapped
		return
	}
	entry.bytes.Store(pcapGlobalHeaderLen)
	started <- nil

	reason := pcapRecords(file, stream, order, m.maxBytes, &entry.bytes)
	entry.cancel()
	stream.Close()
	file.Close()

	// pcapRecords sees a closed pipe and nothing else, so which of the three
	// ways a capture ends actually happened is decided here.
	switch {
	case entry.stopped.Load():
		reason = stopReasonOperator
	case reason == stopReasonEOF && errors.Is(ctx.Err(), context.DeadlineExceeded):
		reason = stopReasonAge
	}
	m.finish(entry, reason)
}

func (m *captureManager) finish(entry *capture, reason string) {
	m.mu.Lock()
	if m.active[entry.device] == entry {
		delete(m.active, entry.device)
	}
	if reason != "" {
		m.reasons[entry.device] = reason
	}
	m.mu.Unlock()
	log.Printf("capture device=%q stopped=%q bytes=%d", entry.device, reason, entry.bytes.Load())
}

// Stop ends a running capture and waits for its file to be closed, so the
// download that follows sees a complete file rather than a partly flushed one.
func (m *captureManager) Stop(device netip.Addr) error {
	m.mu.Lock()
	entry, running := m.active[device]
	m.mu.Unlock()
	if !running {
		return errNoCapture
	}
	entry.stopped.Store(true)
	entry.cancel()
	<-entry.done
	return nil
}

// Get reports what a device's capture slot is doing. Running captures come
// from the map; everything else is answered from the file on disk.
func (m *captureManager) Get(device netip.Addr) captureSlot {
	m.mu.Lock()
	entry, running := m.active[device]
	reason := m.reasons[device]
	m.mu.Unlock()

	if running {
		return captureSlot{
			State:   captureRunning,
			Bytes:   formatBytes(entry.bytes.Load()),
			Limit:   formatBytes(m.maxBytes),
			Elapsed: formatElapsed(time.Since(entry.started)),
		}
	}

	info, err := os.Stat(m.path(device))
	if err != nil || info.Size() == 0 {
		return captureSlot{State: captureIdle}
	}
	return captureSlot{
		State:   captureReady,
		Bytes:   formatBytes(uint64(info.Size())),
		Stopped: info.ModTime().Format("15:04"),
		Reason:  reason,
	}
}

// Open opens a waiting capture for download.
//
// A running capture is refused: it is being appended to, so its length is not
// a number the server can state, and half a capture downloaded silently is
// worse than a refusal.
func (m *captureManager) Open(device netip.Addr) (*os.File, os.FileInfo, error) {
	m.mu.Lock()
	_, running := m.active[device]
	m.mu.Unlock()
	if running {
		return nil, nil, errCaptureRunning
	}
	file, err := os.Open(m.path(device))
	if err != nil {
		return nil, nil, errNoCapture
	}
	info, err := file.Stat()
	if err != nil {
		file.Close()
		return nil, nil, errNoCapture
	}
	return file, info, nil
}

// Discard deletes a waiting capture. A capture holds packet payloads, so
// throwing one away is an action worth having a button for rather than
// something left to the retention sweep.
func (m *captureManager) Discard(device netip.Addr) error {
	m.mu.Lock()
	_, running := m.active[device]
	if !running {
		delete(m.reasons, device)
	}
	m.mu.Unlock()
	if running {
		return errCaptureRunning
	}
	if err := os.Remove(m.path(device)); err != nil && !errors.Is(err, os.ErrNotExist) {
		return err
	}
	return nil
}

// formatElapsed renders a running capture's age. Seconds matter here in a way
// they do not for the router's uptime, so this is not formatUptime.
func formatElapsed(d time.Duration) string {
	seconds := int(d.Seconds())
	if seconds < 60 {
		return fmt.Sprintf("%ds", seconds)
	}
	return fmt.Sprintf("%dm %ds", seconds/60, seconds%60)
}

// startTcpdump spawns tcpdump writing pcap to its stdout.
//
// -U keeps it packet-buffered. Without it tcpdump buffers a non-tty stdout,
// and both the byte count on the page and the file on disk would lag the
// traffic by a buffer at a time — which on a quiet device means the page
// showing nothing captured for minutes.
//
// -s 0 is deliberate: a truncated capture answers "who" but not "what", and
// re-running a capture costs real waiting time.
func startTcpdump(ctx context.Context, iface string, device netip.Addr) (io.ReadCloser, error) {
	cmd := exec.CommandContext(ctx, "tcpdump",
		"-i", iface, "-nn", "-s", "0", "-U", "-w", "-", "host", device.String())
	// tcpdump's diagnostics go to the journal, where a capture that failed for
	// a reason tcpdump knows about can be read after the fact.
	cmd.Stderr = os.Stderr
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return nil, err
	}
	if err := cmd.Start(); err != nil {
		return nil, err
	}
	return &tcpdumpStream{ReadCloser: stdout, cmd: cmd}, nil
}

// tcpdumpStream reaps the process when the stream is closed. Without the Wait
// every stopped capture would leave a zombie behind, and router-web is a
// long-running service.
type tcpdumpStream struct {
	io.ReadCloser
	cmd *exec.Cmd
}

func (s *tcpdumpStream) Close() error {
	err := s.ReadCloser.Close()
	// Non-zero because it was killed, which is how every capture ends.
	_ = s.cmd.Wait()
	return err
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd modules/router/web && go test ./... -run 'TestCapture|TestPcap' -v`
Expected: every test PASSes. Then run with the race detector, which is what this task's concurrency needs:
Run: `cd modules/router/web && go test -race ./... -run 'TestCapture'`
Expected: PASS, no `DATA RACE` reports.

- [ ] **Step 5: Check formatting and commit**

```bash
cd /home/humaid/repos/dotfiles/modules/router/web
gofmt -l .
cd /home/humaid/repos/dotfiles
git add modules/router/web/capture.go modules/router/web/capture_test.go
git commit --no-gpg-sign -m "router-web: capture slots, bounded at 200 MiB and 30 minutes"
```

---

## Task 3: Retention sweep

A capture nobody collected must not sit on the router's disk forever.

**Files:**
- Modify: `modules/router/web/capture.go`
- Modify: `modules/router/web/capture_test.go`

**Interfaces:**
- Consumes: `captureManager`, `newCaptureManager`, `captureRetain`, `captureSweepEvery` (Task 2).
- Produces:
  - `func (m *captureManager) sweep(now time.Time)`
  - `func (m *captureManager) sweepEvery(interval time.Duration)`

- [ ] **Step 1: Write the failing tests**

Append to `modules/router/web/capture_test.go`:

```go
func TestSweepRemovesCapturesPastTheRetentionWindow(t *testing.T) {
	manager := testManager(t, nil)
	stale := manager.path(netip.MustParseAddr("192.168.0.30"))
	fresh := manager.path(netip.MustParseAddr("192.168.0.31"))
	for _, path := range []string{stale, fresh} {
		if err := os.WriteFile(path, []byte("pcap"), 0o600); err != nil {
			t.Fatalf("write %s: %v", path, err)
		}
	}
	old := time.Now().Add(-48 * time.Hour)
	if err := os.Chtimes(stale, old, old); err != nil {
		t.Fatalf("chtimes: %v", err)
	}

	manager.sweep(time.Now())

	if _, err := os.Stat(stale); !os.IsNotExist(err) {
		t.Fatal("sweep kept a capture older than the retention window")
	}
	if _, err := os.Stat(fresh); err != nil {
		t.Fatalf("sweep removed a capture inside the retention window: %v", err)
	}
}

func TestSweepSkipsARunningCapture(t *testing.T) {
	// A long capture on a quiet device can outlive the retention window while
	// still being written. Deleting the file out from under it would leave a
	// capture running with nowhere to land.
	manager := testManager(t, pcapStream(t, binary.LittleEndian, 0xa1b2c3d4, 100))
	manager.retain = 0
	if err := manager.Start(testDevice); err != nil {
		t.Fatalf("Start: %v", err)
	}
	t.Cleanup(func() { _ = manager.Stop(testDevice) })

	manager.sweep(time.Now().Add(time.Hour))

	if _, err := os.Stat(manager.path(testDevice)); err != nil {
		t.Fatalf("sweep removed a running capture's file: %v", err)
	}
}

func TestSweepIgnoresFilesThatAreNotCaptures(t *testing.T) {
	manager := testManager(t, nil)
	other := filepath.Join(manager.dir, "notes.txt")
	badName := filepath.Join(manager.dir, "not-an-address.pcap")
	for _, path := range []string{other, badName} {
		if err := os.WriteFile(path, []byte("x"), 0o600); err != nil {
			t.Fatalf("write %s: %v", path, err)
		}
		old := time.Now().Add(-48 * time.Hour)
		if err := os.Chtimes(path, old, old); err != nil {
			t.Fatalf("chtimes: %v", err)
		}
	}

	manager.sweep(time.Now())

	for _, path := range []string{other, badName} {
		if _, err := os.Stat(path); err != nil {
			t.Fatalf("sweep removed %s, which it does not own", path)
		}
	}
}

func TestSweepSurvivesAMissingDirectory(t *testing.T) {
	// The directory does not exist until the first capture. A sweeper that
	// panicked on that would take the whole process down at boot.
	manager := newCaptureManager(filepath.Join(t.TempDir(), "absent"), "lan0")
	manager.sweep(time.Now())
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd modules/router/web && go test ./... 2>&1 | head -20`
Expected: compile failure — `manager.sweep undefined (type *captureManager has no field or method sweep)`.

- [ ] **Step 3: Write the implementation**

Append to `modules/router/web/capture.go`. Add `"strings"` to the import block.

```go
// sweep deletes captures nobody collected.
//
// Without it a capture started once and forgotten sits on the router's disk
// until someone notices — and a capture is a file full of packet payloads,
// which is not a thing to leave lying about indefinitely.
//
// now is a parameter rather than a call to time.Now so a test can age a file
// without sleeping.
func (m *captureManager) sweep(now time.Time) {
	entries, err := os.ReadDir(m.dir)
	if err != nil {
		// The directory does not exist until the first capture, which is the
		// ordinary state of a router nobody has captured on.
		return
	}
	for _, item := range entries {
		if item.IsDir() || filepath.Ext(item.Name()) != ".pcap" {
			continue
		}
		device, err := netip.ParseAddr(strings.TrimSuffix(item.Name(), ".pcap"))
		if err != nil {
			// Not a name this wrote, so not a file this deletes.
			continue
		}
		m.mu.Lock()
		_, running := m.active[device]
		m.mu.Unlock()
		if running {
			// A long capture on a quiet device can outlive the window while
			// still being written to.
			continue
		}
		info, err := item.Info()
		if err != nil || now.Sub(info.ModTime()) < m.retain {
			continue
		}
		if err := os.Remove(m.path(device)); err == nil {
			log.Printf("capture swept device=%q age=%s bytes=%d",
				device, now.Sub(info.ModTime()).Round(time.Minute), info.Size())
		}
	}
}

// sweepEvery runs the sweep until the process exits. Started once from
// main.go; it holds no state of its own.
func (m *captureManager) sweepEvery(interval time.Duration) {
	for range time.Tick(interval) {
		m.sweep(time.Now())
	}
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd modules/router/web && go test ./... -run 'TestSweep' -v`
Expected: all four PASS.
Run: `cd modules/router/web && go test ./...`
Expected: `ok  	router-web` — nothing from Tasks 1–2 regressed.

- [ ] **Step 5: Check formatting and commit**

```bash
cd /home/humaid/repos/dotfiles/modules/router/web
gofmt -l .
cd /home/humaid/repos/dotfiles
git add modules/router/web/capture.go modules/router/web/capture_test.go
git commit --no-gpg-sign -m "router-web: sweep captures nobody collected after a day"
```

---

## Task 4: HTTP routes

Four routes on the mesh mux, plus lifting the CSRF check out of `handleAction` so the new routes and the old ones share one copy.

**Files:**
- Modify: `modules/router/web/peers.go:31-35` (the `peersPageData` struct), `:62-87` (`peersServer` and its constructor), `:211-243` (`mux`), `:267-324` (`render`), `:328-338` (`handleAction`'s CSRF block)
- Modify: `modules/router/web/peers_test.go`

**Interfaces:**
- Consumes: `captureManager` and its methods, `captureSlot` (Tasks 2–3); `peersServer.device`, `peersServer.render`, `peersServer.logAction` (existing).
- Produces:
  - `peersPageData.Capture captureSlot`
  - `peersServer.captures *captureManager` (nil disables the feature and its routes)
  - `func sameOrigin(w http.ResponseWriter, r *http.Request) bool`
  - `func (s *peersServer) captureRequest(w http.ResponseWriter, r *http.Request) (netip.Addr, bool)`
  - Handlers `handleCaptureStart`, `handleCaptureStop`, `handleCaptureDiscard`, `handleCaptureDownload`
  - Routes `POST /peers/{device}/capture/start`, `POST /peers/{device}/capture/stop`, `POST /peers/{device}/capture/discard`, `GET /peers/{device}/capture.pcap`

- [ ] **Step 1: Write the failing tests**

Append to `modules/router/web/peers_test.go`. Its import block already has `context`, `errors`, `html/template`, `net/http`, `net/http/httptest`, `net/netip`, `os`, `strings`, `testing`, `time`; add `"encoding/binary"` and `"io"` if the compiler asks for them.

```go
// testPeersServerWithCaptures is testPeersServer with a capture manager whose
// captures come from a canned stream rather than a real interface.
func testPeersServerWithCaptures(t *testing.T) *peersServer {
	t.Helper()
	server := testPeersServer(t)
	server.captures = testManager(t, pcapStream(t, binary.LittleEndian, 0xa1b2c3d4, 100, 100))
	return server
}

func postForm(path string) *http.Request {
	req := httptest.NewRequest(http.MethodPost, path, nil)
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	return req
}

func TestCaptureStartRouteRedirectsToThePage(t *testing.T) {
	server := testPeersServerWithCaptures(t)
	t.Cleanup(func() { _ = server.captures.Stop(testDevice) })

	rec := httptest.NewRecorder()
	server.mux().ServeHTTP(rec, postForm("/peers/192.168.0.10/capture/start"))

	if rec.Code != http.StatusSeeOther {
		t.Fatalf("status = %d, want 303\n%s", rec.Code, rec.Body.String())
	}
	if got := rec.Header().Get("Location"); got != "/peers/192.168.0.10" {
		t.Fatalf("Location = %q, want /peers/192.168.0.10", got)
	}
	if state := server.captures.Get(testDevice).State; state != captureRunning {
		t.Fatalf("state = %q, want %q", state, captureRunning)
	}
}

func TestCaptureStopRouteRedirectsToTheDownload(t *testing.T) {
	// One click stops and downloads: the redirect target is the file, not the
	// page. The file stays on disk so a cancelled download is still there.
	server := testPeersServerWithCaptures(t)
	if err := server.captures.Start(testDevice); err != nil {
		t.Fatalf("Start: %v", err)
	}

	rec := httptest.NewRecorder()
	server.mux().ServeHTTP(rec, postForm("/peers/192.168.0.10/capture/stop"))

	if rec.Code != http.StatusSeeOther {
		t.Fatalf("status = %d, want 303\n%s", rec.Code, rec.Body.String())
	}
	if got := rec.Header().Get("Location"); got != "/peers/192.168.0.10/capture.pcap" {
		t.Fatalf("Location = %q, want /peers/192.168.0.10/capture.pcap", got)
	}
}

func TestCaptureDownloadServesThePcapAsAnAttachment(t *testing.T) {
	server := testPeersServerWithCaptures(t)
	if err := server.captures.Start(testDevice); err != nil {
		t.Fatalf("Start: %v", err)
	}
	if err := server.captures.Stop(testDevice); err != nil {
		t.Fatalf("Stop: %v", err)
	}

	rec := httptest.NewRecorder()
	server.mux().ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/peers/192.168.0.10/capture.pcap", nil))

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200\n%s", rec.Code, rec.Body.String())
	}
	disposition := rec.Header().Get("Content-Disposition")
	if !strings.HasPrefix(disposition, `attachment; filename="192.168.0.10-`) {
		t.Fatalf("Content-Disposition = %q, want an attachment named after the device", disposition)
	}
	if !strings.HasSuffix(disposition, `.pcap"`) {
		t.Fatalf("Content-Disposition = %q, want a .pcap filename", disposition)
	}
	if got := rec.Header().Get("Content-Type"); got != "application/vnd.tcpdump.pcap" {
		t.Fatalf("Content-Type = %q, want application/vnd.tcpdump.pcap", got)
	}
	if rec.Body.Len() < pcapGlobalHeaderLen {
		t.Fatalf("body is %d bytes, want at least a pcap header", rec.Body.Len())
	}
}

func TestCaptureDownloadOfNothingIs404(t *testing.T) {
	rec := httptest.NewRecorder()
	testPeersServerWithCaptures(t).mux().ServeHTTP(rec,
		httptest.NewRequest(http.MethodGet, "/peers/192.168.0.10/capture.pcap", nil))
	if rec.Code != http.StatusNotFound {
		t.Fatalf("status = %d, want 404", rec.Code)
	}
}

func TestCaptureDiscardRouteReturnsToThePage(t *testing.T) {
	server := testPeersServerWithCaptures(t)
	if err := server.captures.Start(testDevice); err != nil {
		t.Fatalf("Start: %v", err)
	}
	if err := server.captures.Stop(testDevice); err != nil {
		t.Fatalf("Stop: %v", err)
	}

	rec := httptest.NewRecorder()
	server.mux().ServeHTTP(rec, postForm("/peers/192.168.0.10/capture/discard"))

	if rec.Code != http.StatusSeeOther {
		t.Fatalf("status = %d, want 303\n%s", rec.Code, rec.Body.String())
	}
	if state := server.captures.Get(testDevice).State; state != captureIdle {
		t.Fatalf("state = %q, want %q", state, captureIdle)
	}
}

func TestCaptureRoutesRefuseCrossSiteRequests(t *testing.T) {
	for _, path := range []string{
		"/peers/192.168.0.10/capture/start",
		"/peers/192.168.0.10/capture/stop",
		"/peers/192.168.0.10/capture/discard",
	} {
		t.Run(path, func(t *testing.T) {
			req := postForm(path)
			req.Header.Set("Sec-Fetch-Site", "cross-site")
			rec := httptest.NewRecorder()
			testPeersServerWithCaptures(t).mux().ServeHTTP(rec, req)
			if rec.Code != http.StatusForbidden {
				t.Fatalf("status = %d, want 403", rec.Code)
			}
		})
	}
}

func TestCaptureDownloadRefusesCrossSiteRequests(t *testing.T) {
	// A capture is packet payloads. The download gets the same guard as the
	// buttons rather than a weaker one because it is a GET.
	req := httptest.NewRequest(http.MethodGet, "/peers/192.168.0.10/capture.pcap", nil)
	req.Header.Set("Sec-Fetch-Site", "cross-site")
	rec := httptest.NewRecorder()
	testPeersServerWithCaptures(t).mux().ServeHTTP(rec, req)
	if rec.Code != http.StatusForbidden {
		t.Fatalf("status = %d, want 403", rec.Code)
	}
}

func TestCaptureRoutesRefuseADeviceOutsideTheLAN(t *testing.T) {
	for _, path := range []string{
		"/peers/203.0.113.10/capture/start",
		"/peers/203.0.113.10/capture/stop",
		"/peers/203.0.113.10/capture/discard",
	} {
		t.Run(path, func(t *testing.T) {
			rec := httptest.NewRecorder()
			testPeersServerWithCaptures(t).mux().ServeHTTP(rec, postForm(path))
			if rec.Code != http.StatusNotFound {
				t.Fatalf("status = %d, want 404", rec.Code)
			}
		})
	}
	rec := httptest.NewRecorder()
	testPeersServerWithCaptures(t).mux().ServeHTTP(rec,
		httptest.NewRequest(http.MethodGet, "/peers/203.0.113.10/capture.pcap", nil))
	if rec.Code != http.StatusNotFound {
		t.Fatalf("download status = %d, want 404", rec.Code)
	}
}

func TestCaptureStartFailureRendersTheNoticeNotAnError(t *testing.T) {
	// A failed start must leave the peers page working: the device's peers are
	// the reason the operator is on this page at all.
	server := testPeersServer(t)
	server.captures = newCaptureManager(t.TempDir(), "lan0")
	server.captures.start = func(context.Context, string, netip.Addr) (io.ReadCloser, error) {
		return nil, errors.New("tcpdump not found")
	}

	rec := httptest.NewRecorder()
	server.mux().ServeHTTP(rec, postForm("/peers/192.168.0.10/capture/start"))

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200 with a notice", rec.Code)
	}
	if !strings.Contains(rec.Body.String(), "tcpdump not found") {
		t.Fatalf("notice missing from the page: %q", rec.Body.String())
	}
	if !strings.Contains(rec.Body.String(), "203.0.113.10") {
		t.Fatalf("peer table missing from a page that failed to start a capture: %q", rec.Body.String())
	}
}

func TestCaptureRoutesAbsentWithoutAManager(t *testing.T) {
	// A router with no capture directory configured behaves exactly as it did
	// before this feature.
	server := testPeersServer(t)
	rec := httptest.NewRecorder()
	server.mux().ServeHTTP(rec, postForm("/peers/192.168.0.10/capture/start"))
	if rec.Code != http.StatusNotFound {
		t.Fatalf("status = %d, want 404", rec.Code)
	}
}

func TestLANMuxHasNoCaptureRoutes(t *testing.T) {
	// The capture routes are mesh-only, like every other peers route.
	config := loadConfig()
	tmpl := template.Must(template.New("index").Parse("landing"))
	lan := landingMux(config, tmpl)
	for _, path := range []string{
		"/peers/192.168.0.10/capture/start",
		"/peers/192.168.0.10/capture.pcap",
	} {
		rec := httptest.NewRecorder()
		lan.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, path, nil))
		if rec.Code != http.StatusNotFound {
			t.Fatalf("landing mux answered %s with %d, want 404", path, rec.Code)
		}
	}
}

func TestCaptureActionsAreLogged(t *testing.T) {
	var out strings.Builder
	log.SetOutput(&out)
	t.Cleanup(func() { log.SetOutput(os.Stderr) })

	server := testPeersServerWithCaptures(t)
	server.mux().ServeHTTP(httptest.NewRecorder(), postForm("/peers/192.168.0.10/capture/start"))
	server.mux().ServeHTTP(httptest.NewRecorder(), postForm("/peers/192.168.0.10/capture/stop"))

	body := out.String()
	for _, want := range []string{
		`action=capture-start peer="-" device="192.168.0.10" result="ok"`,
		`action=capture-stop peer="-" device="192.168.0.10" result="ok"`,
	} {
		if !strings.Contains(body, want) {
			t.Fatalf("journal is missing %s\n%s", want, body)
		}
	}
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd modules/router/web && go test ./... 2>&1 | head -30`
Expected: compile failure — `server.captures undefined (type *peersServer has no field or method captures)`.

- [ ] **Step 3: Write the implementation**

**3a.** In `modules/router/web/peers.go`, add the field to `peersPageData`:

```go
type peersPageData struct {
	Device string
	Peers  []peerRow
	Error  string
	// What this device's capture slot is doing. Zero when no capture
	// directory is configured, which the template reads as "no banner".
	Capture captureSlot
}
```

**3b.** Add the field to `peersServer`, below `namer`:

```go
	// Set by main.go when a capture directory is configured. Nil disables the
	// feature: no routes, no banner, and the page behaves exactly as it did
	// before captures existed.
	captures *captureManager
```

Leave `newPeersServer` alone — `captures` is assigned after construction, the way `namer` already is.

**3c.** Extract the CSRF check. Delete this block from the top of the closure in `handleAction`:

```go
		if site := r.Header.Get("Sec-Fetch-Site"); site != "" && site != "same-origin" {
			http.Error(w, "cross-site request refused", http.StatusForbidden)
			return
		}
```

and replace it with:

```go
		if !sameOrigin(w, r) {
			return
		}
```

Then add, above `handleAction`:

```go
// sameOrigin refuses a cross-site request, answering it and reporting false.
//
// Browsers send Sec-Fetch-Site on every request, and a cross-site form POST
// carries "cross-site". Non-browser callers (curl over the mesh) send no such
// header, so absence is allowed and only an explicit cross-origin value is
// refused. This is the whole CSRF defence: these endpoints are otherwise
// unauthenticated by design.
//
// Shared rather than repeated per handler. Copied into each of the seven
// routes that need it, one copy would eventually drift — and on these routes
// that means an unauthenticated firewall mutation or a capture handed to
// another origin.
func sameOrigin(w http.ResponseWriter, r *http.Request) bool {
	if site := r.Header.Get("Sec-Fetch-Site"); site != "" && site != "same-origin" {
		http.Error(w, "cross-site request refused", http.StatusForbidden)
		return false
	}
	return true
}
```

**3d.** Register the routes. In `mux()`, before `return mux`:

```go
	// Absent unless a capture directory is configured, so a router without one
	// answers 404 here exactly as it did before this feature.
	if s.captures != nil {
		mux.HandleFunc("POST /peers/{device}/capture/start", s.handleCaptureStart)
		mux.HandleFunc("POST /peers/{device}/capture/stop", s.handleCaptureStop)
		mux.HandleFunc("POST /peers/{device}/capture/discard", s.handleCaptureDiscard)
		mux.HandleFunc("GET /peers/{device}/capture.pcap", s.handleCaptureDownload)
	}
```

**3e.** Fill the slot in `render`. After the `shapes` block and before `data := peersPageData{...}` is used, change the construction to:

```go
	data := peersPageData{Device: device.String(), Error: notice}
	if s.captures != nil {
		data.Capture = s.captures.Get(device)
	}
```

**3f.** Add the handlers at the end of `peers.go`:

```go
// captureRequest applies the two guards every capture route needs: the CSRF
// check, and the {device} check that keeps the route from being pointed at an
// address outside the LAN. It answers the request itself when either fails.
func (s *peersServer) captureRequest(w http.ResponseWriter, r *http.Request) (netip.Addr, bool) {
	if !sameOrigin(w, r) {
		return netip.Addr{}, false
	}
	device, ok := s.device(r)
	if !ok {
		http.NotFound(w, r)
		return netip.Addr{}, false
	}
	return device, true
}

// captureResult renders an action's outcome for the journal.
func captureResult(err error) string {
	if err != nil {
		return "error: " + err.Error()
	}
	return "ok"
}

func (s *peersServer) handleCaptureStart(w http.ResponseWriter, r *http.Request) {
	device, ok := s.captureRequest(w, r)
	if !ok {
		return
	}
	err := s.captures.Start(device)
	s.logAction("capture-start", netip.Addr{}, device, captureResult(err))
	if err != nil {
		// Rendered rather than returned as an error status: the device's peers
		// are why the operator is on this page, and a capture that would not
		// start must not take them away.
		s.render(w, r, device, "Cannot start a capture: "+err.Error())
		return
	}
	http.Redirect(w, r, "/peers/"+device.String(), http.StatusSeeOther)
}

// handleCaptureStop ends the capture and sends the browser to the download, so
// one click both stops and collects. The file stays on disk either way, so a
// download that fails or is cancelled has not lost the capture.
func (s *peersServer) handleCaptureStop(w http.ResponseWriter, r *http.Request) {
	device, ok := s.captureRequest(w, r)
	if !ok {
		return
	}
	err := s.captures.Stop(device)
	s.logAction("capture-stop", netip.Addr{}, device, captureResult(err))
	if err != nil {
		s.render(w, r, device, "Cannot stop the capture: "+err.Error())
		return
	}
	http.Redirect(w, r, "/peers/"+device.String()+"/capture.pcap", http.StatusSeeOther)
}

func (s *peersServer) handleCaptureDiscard(w http.ResponseWriter, r *http.Request) {
	device, ok := s.captureRequest(w, r)
	if !ok {
		return
	}
	err := s.captures.Discard(device)
	s.logAction("capture-discard", netip.Addr{}, device, captureResult(err))
	if err != nil {
		s.render(w, r, device, "Cannot discard the capture: "+err.Error())
		return
	}
	http.Redirect(w, r, "/peers/"+device.String(), http.StatusSeeOther)
}

func (s *peersServer) handleCaptureDownload(w http.ResponseWriter, r *http.Request) {
	device, ok := s.captureRequest(w, r)
	if !ok {
		return
	}
	file, info, err := s.captures.Open(device)
	if err != nil {
		http.Error(w, "no capture to download", http.StatusNotFound)
		return
	}
	defer file.Close()

	// Named for the device and the time it stopped, because a directory of
	// files called capture.pcap is a directory nobody can read later. No
	// quoting needed: both halves come from a parsed address and a formatted
	// time, neither of which can carry a quote.
	name := fmt.Sprintf("%s-%s.pcap", device, info.ModTime().Format("20060102-1504"))
	w.Header().Set("Content-Type", "application/vnd.tcpdump.pcap")
	w.Header().Set("Content-Disposition", `attachment; filename="`+name+`"`)
	http.ServeContent(w, r, name, info.ModTime(), file)
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd modules/router/web && go test ./... -run 'TestCapture|TestLANMux|TestAction' -v`
Expected: all PASS, including the pre-existing `TestActionRefusesCrossSiteRequest` and `TestActionDropAllRefusesCrossSiteRequest`, which now exercise the extracted helper.
Run: `cd modules/router/web && go test -race ./...`
Expected: `ok  	router-web`, no `DATA RACE`.

- [ ] **Step 5: Check formatting and commit**

```bash
cd /home/humaid/repos/dotfiles/modules/router/web
gofmt -l .
cd /home/humaid/repos/dotfiles
git add modules/router/web/peers.go modules/router/web/peers_test.go
git commit --no-gpg-sign -m "router-web: capture start, stop, download and discard routes"
```

---

## Task 5: Capture banner on the peers page

**Files:**
- Modify: `modules/router/web/peers.html`
- Modify: `modules/router/web/peers_test.go`

**Interfaces:**
- Consumes: `peersPageData.Capture` and the `captureSlot` fields (Task 4).
- Produces: no Go identifiers — the rendered banner and its three states.

- [ ] **Step 1: Write the failing tests**

Append to `modules/router/web/peers_test.go`:

```go
func TestRealTemplateRendersTheIdleCaptureButton(t *testing.T) {
	tmpl := template.Must(template.ParseFiles("peers.html"))
	var out strings.Builder
	if err := tmpl.Execute(&out, peersPageData{
		Device:  "192.168.0.10",
		Capture: captureSlot{State: captureIdle},
	}); err != nil {
		t.Fatalf("execute peers.html: %v", err)
	}
	body := out.String()
	if !strings.Contains(body, `action="/peers/192.168.0.10/capture/start"`) {
		t.Fatalf("start button absent:\n%s", body)
	}
	for _, unwanted := range []string{"capture/stop", "capture.pcap", "capture/discard"} {
		if strings.Contains(body, unwanted) {
			t.Fatalf("idle page offers %s:\n%s", unwanted, body)
		}
	}
}

func TestRealTemplateRendersTheRunningCaptureBanner(t *testing.T) {
	tmpl := template.Must(template.ParseFiles("peers.html"))
	var out strings.Builder
	if err := tmpl.Execute(&out, peersPageData{
		Device: "192.168.0.10",
		Capture: captureSlot{
			State:   captureRunning,
			Bytes:   "12.4 MiB",
			Limit:   "200.0 MiB",
			Elapsed: "3m 12s",
		},
	}); err != nil {
		t.Fatalf("execute peers.html: %v", err)
	}
	body := out.String()
	if !strings.Contains(body, `action="/peers/192.168.0.10/capture/stop"`) {
		t.Fatalf("stop button absent:\n%s", body)
	}
	for _, want := range []string{"12.4 MiB", "200.0 MiB", "3m 12s"} {
		if !strings.Contains(body, want) {
			t.Fatalf("running banner is missing %q:\n%s", want, body)
		}
	}
	if strings.Contains(body, "capture/start") {
		t.Fatalf("running page still offers to start a capture:\n%s", body)
	}
}

func TestRealTemplateRendersTheReadyCaptureBanner(t *testing.T) {
	tmpl := template.Must(template.ParseFiles("peers.html"))
	var out strings.Builder
	if err := tmpl.Execute(&out, peersPageData{
		Device: "192.168.0.10",
		Capture: captureSlot{
			State:   captureReady,
			Bytes:   "43.1 MiB",
			Stopped: "14:02",
			Reason:  stopReasonLimit,
		},
	}); err != nil {
		t.Fatalf("execute peers.html: %v", err)
	}
	body := out.String()
	for _, want := range []string{
		`href="/peers/192.168.0.10/capture.pcap"`,
		`action="/peers/192.168.0.10/capture/discard"`,
		"43.1 MiB",
		"14:02",
		stopReasonLimit,
	} {
		if !strings.Contains(body, want) {
			t.Fatalf("ready banner is missing %q:\n%s", want, body)
		}
	}
}

func TestRealTemplateOmitsTheBannerWithoutAManager(t *testing.T) {
	// A router with no capture directory renders the page it always did.
	// Asserted on the routes rather than on the word "capture", which the
	// stylesheet carries on every render.
	tmpl := template.Must(template.ParseFiles("peers.html"))
	var out strings.Builder
	if err := tmpl.Execute(&out, peersPageData{Device: "192.168.0.10"}); err != nil {
		t.Fatalf("execute peers.html: %v", err)
	}
	for _, unwanted := range []string{
		"capture/start", "capture/stop", "capture/discard", "capture.pcap",
	} {
		if strings.Contains(out.String(), unwanted) {
			t.Fatalf("page offers %s without a manager:\n%s", unwanted, out.String())
		}
	}
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd modules/router/web && go test ./... -run 'TestRealTemplate' -v`
Expected: `TestRealTemplateRendersTheIdleCaptureButton`, `...RunningCaptureBanner` and `...ReadyCaptureBanner` FAIL with "start button absent" / "stop button absent" / missing href. `TestRealTemplateOmitsTheBannerWithoutAManager` passes already.

- [ ] **Step 3: Write the implementation**

**3a.** In `modules/router/web/peers.html`, add to the `<style>` block, after the `form.device button` rule:

```css
form.capture { display: inline; }
form.capture button { background: #eef4ff; border: 1px solid #468; color: #235; font-weight: 600; }
p.capture { margin: 0 0 1rem; color: #444; }
p.capture .figure { font-variant-numeric: tabular-nums; }
p.capture .why { color: #666; }
```

**3b.** Insert the banner immediately after the `drop-all` form's trailing note — that is, after the line `<p class="note">Ends every connection this device has, to every peer at once, and blocks nothing. Its apps reconnect from scratch.</p>` and before `{{if .Peers}}`:

```html
{{if eq .Capture.State "running"}}
<p class="capture">
<form class="capture" method="post" action="/peers/{{.Device}}/capture/stop">
<button type="submit">stop &amp; download capture</button>
</form>
<span class="figure">capturing &mdash; {{.Capture.Bytes}} of {{.Capture.Limit}}, {{.Capture.Elapsed}} elapsed</span>
</p>
<p class="note">Stops on its own at the limit or after 30 minutes, whichever comes first. Stopping downloads the file and leaves a copy here.</p>
{{else if eq .Capture.State "ready"}}
<p class="capture">
<a href="/peers/{{.Device}}/capture.pcap">download capture</a>
<span class="figure">&mdash; {{.Capture.Bytes}}, stopped {{.Capture.Stopped}}</span>
{{if .Capture.Reason}}<span class="why">({{.Capture.Reason}})</span>{{end}}
<form class="capture" method="post" action="/peers/{{.Device}}/capture/discard">
<button type="submit">discard</button>
</form>
</p>
<p class="note">Kept for 24 hours, then deleted. Starting a new capture for this device replaces it.</p>
{{else if eq .Capture.State "idle"}}
<form class="capture" method="post" action="/peers/{{.Device}}/capture/start" style="margin: 0 0 1rem">
<button type="submit">start capture</button>
</form>
<p class="note">Records this device&rsquo;s full packets, in both directions, to a file you download. It follows the address this page is for &mdash; a device&rsquo;s traffic under a different address is not in it. Stops on its own at 200 MiB or 30 minutes.</p>
{{end}}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd modules/router/web && go test ./... -run 'TestRealTemplate|TestDropAll' -v`
Expected: all PASS, including the pre-existing `TestRealTemplateRendersAllThreeActions` and `TestDropAllRendersWithNoPeers`.
Run: `cd modules/router/web && go test ./...`
Expected: `ok  	router-web`.

- [ ] **Step 5: Commit**

```bash
cd /home/humaid/repos/dotfiles
git add modules/router/web/peers.html modules/router/web/peers_test.go
git commit --no-gpg-sign -m "router-web: capture banner on the peers page"
```

---

## Task 6: Wire it into the service

The manager is constructed from the environment, the sweeper starts, and the NixOS module grants what tcpdump needs.

**Files:**
- Modify: `modules/router/web/main.go:399-432` (`startMeshServer`)
- Modify: `modules/router/web.nix:49-83` (`serviceConfig`)
- Modify: `modules/router/web/peers_test.go`

**Interfaces:**
- Consumes: `newCaptureManager`, `sweepEvery`, `captureSweepEvery` (Tasks 2–3); `peersServer.captures` (Task 4).
- Produces: the running feature. No new Go identifiers.

- [ ] **Step 1: Write the failing test**

Append to `modules/router/web/peers_test.go`:

```go
func TestCaptureManagerTakesItsInterfaceFromTheEnvironment(t *testing.T) {
	// The capture filter is applied on the LAN interface, so a manager built
	// with the wrong one would capture nothing and say nothing about why.
	t.Setenv("ROUTER_LAN_INTERFACE", "lan9")
	manager := newCaptureManager(t.TempDir(), getenvDefault("ROUTER_LAN_INTERFACE", "enp2s0"))
	if manager.iface != "lan9" {
		t.Fatalf("iface = %q, want lan9", manager.iface)
	}
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd modules/router/web && go test ./... -run 'TestCaptureManagerTakesItsInterface' -v`
Expected: this one passes immediately (it exercises Task 2's constructor). That is fine — it is a regression guard on the wiring below, not a driver for it. Confirm it passes, then continue.

- [ ] **Step 3: Wire main.go**

In `modules/router/web/main.go`, inside `startMeshServer`, after the line `peers.namer = newNamerFromEnv()` and before `handler := peers.mux()`:

```go
	// Captures are opt-in on the directory: a router without one keeps every
	// route and every pixel it had before this feature.
	if dir := strings.TrimSpace(os.Getenv("ROUTER_CAPTURE_DIR")); dir != "" {
		peers.captures = newCaptureManager(dir, getenvDefault("ROUTER_LAN_INTERFACE", "enp2s0"))
		go peers.captures.sweepEvery(captureSweepEvery)
	}
```

`strings` and `os` are already imported by `main.go`.

- [ ] **Step 4: Wire web.nix**

In `modules/router/web.nix`:

**4a.** Add tcpdump to the service `path` list (it currently holds `iproute2`, `procps`, `conntrack-tools`, `nftables`):

```nix
      path = with pkgs; [
        iproute2
        procps
        conntrack-tools
        nftables
        # The peers page's capture button shells out to this. A DynamicUser
        # service builds its PATH from this list alone, so being in
        # environment.systemPackages would not be enough.
        tcpdump
      ];
```

**4b.** Add `CAP_NET_RAW` to both capability lists:

```nix
        AmbientCapabilities = [
          "CAP_NET_BIND_SERVICE"
          "CAP_NET_ADMIN"
          # Opening a capture socket. tcpdump inherits this service's ambient
          # set, so the capture needs no setuid helper of its own.
          "CAP_NET_RAW"
        ];
        CapabilityBoundingSet = [
          "CAP_NET_BIND_SERVICE"
          "CAP_NET_ADMIN"
          "CAP_NET_RAW"
        ];
```

**4c.** Add the state directory and its environment variable. Inside `serviceConfig`, alongside `Restart`:

```nix
        # Where captures land. DynamicUser puts this under
        # /var/lib/private/router-web and keeps it across restarts, which is
        # what lets a capture interrupted by a restart still be downloaded.
        StateDirectory = "router-web";
        StateDirectoryMode = "0700";
```

and in the `Environment` list, after `ROUTER_CALL_MARK`:

```nix
          "ROUTER_CAPTURE_DIR=%S/router-web/captures"
```

`%S` is systemd's state directory root; with `DynamicUser` it resolves to the private path the service actually sees.

- [ ] **Step 5: Verify the whole thing builds and passes**

```bash
cd /home/humaid/repos/dotfiles/modules/router/web
gofmt -l .
go vet ./...
go test -race ./...
```
Expected: `gofmt -l .` prints nothing, `go vet` prints nothing, tests print `ok  	router-web`.

```bash
cd /home/humaid/repos/dotfiles
nix fmt
git diff --stat
```
Expected: `nix fmt` reformats nothing outside the files this plan touched. If it does touch other files, revert those — they are unrelated drift.

```bash
cd /home/humaid/repos/dotfiles
nix flake check
```
Expected: passes. This is the real gate for this repository (CI only runs `nix flake show`). It is slow; let it finish.

- [ ] **Step 6: Commit**

```bash
cd /home/humaid/repos/dotfiles
git add modules/router/web/main.go modules/router/web/peers_test.go modules/router/web.nix
git commit --no-gpg-sign -m "router: give router-web a capture directory and CAP_NET_RAW"
```

---

## Verification checklist

Run after Task 6, before calling the feature done:

- [ ] `cd modules/router/web && go test -race ./...` → `ok`
- [ ] `cd modules/router/web && gofmt -l .` → no output
- [ ] `cd modules/router/web && go vet ./...` → no output
- [ ] `nix flake check` → passes
- [ ] `git log --oneline -6` shows six commits, none signed
- [ ] `grep -rn 'capture' modules/router/web/peers.go | grep -c 'sameOrigin'` — confirm the CSRF helper is called from `captureRequest`, and that `handleAction` calls it too rather than keeping its own copy

Manual check on the router, after deploying (`sudo nixos-rebuild switch --flake .#<router>`):

- [ ] Open `http://<mesh-address>/peers/<a LAN device>` and press **start capture**; the banner shows a byte count that grows on reload.
- [ ] Press **stop & download capture**; the browser downloads a `.pcap` that opens in Wireshark with no "cut short" warning.
- [ ] Reload the page; the banner offers the same capture again with **download** and **discard**.
- [ ] `journalctl -u router-web | grep capture` shows `action=capture-start`, `action=capture-stop` and a `capture device=... stopped=...` line.
