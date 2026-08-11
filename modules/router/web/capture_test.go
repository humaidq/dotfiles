package main

import (
	"bytes"
	"context"
	"encoding/binary"
	"errors"
	"io"
	"net/netip"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

// pcapStream builds a pcap byte stream in the given byte order, with one
// record per entry in sizes. Written by hand rather than captured from
// tcpdump so a test can say exactly where the cut should land.
func pcapStream(t *testing.T, order binary.ByteOrder, magic uint32, sizes ...int) []byte {
	t.Helper()
	var out bytes.Buffer
	header := make([]byte, pcapGlobalHeaderLen)
	order.PutUint32(header[0:4], magic)
	order.PutUint16(header[4:6], 2) // version major
	order.PutUint16(header[6:8], 4) // version minor
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

// failingWriter errors on the Nth call to Write, counting from 1.
// Writes before the failure succeed; the failure itself returns an error.
type failingWriter struct {
	writes int
	fail   int
}

func (w *failingWriter) Write(p []byte) (int, error) {
	w.writes++
	if w.writes == w.fail {
		return 0, bytes.ErrTooLarge // a write error
	}
	return len(p), nil
}

func TestPcapRecordsReportsAWriteFailure(t *testing.T) {
	// Write sequence for a one-record stream: 1=global header (from pcapHeader),
	// 2=record header, 3=record payload. Fail on write #3 (the payload write).
	stream := pcapStream(t, binary.LittleEndian, 0xa1b2c3d4, 50)
	src := bytes.NewReader(stream)
	dst := &failingWriter{fail: 3}
	var count atomic.Uint64

	order, err := pcapHeader(dst, src)
	if err != nil {
		t.Fatalf("pcapHeader: %v", err)
	}
	count.Store(pcapGlobalHeaderLen)
	reason := pcapRecords(dst, src, order, 1<<20, &count)

	if reason != stopReasonWrite {
		t.Fatalf("reason = %q, want %q", reason, stopReasonWrite)
	}
}

func TestPcapRecordsCountStaysOnARecordBoundaryWhenAWriteFails(t *testing.T) {
	// Write sequence for a two-record stream: 1=global header (from pcapHeader),
	// 2=record 1 header, 3=record 1 payload, 4=record 2 header, 5=record 2 payload.
	// Fail on write #5 (record 2's payload). The record 2 header write succeeds,
	// but the payload write fails, leaving a header on disk without its payload.
	// The count must not advance for the failed record, staying at the boundary
	// after record 1 (header + payload).
	stream := pcapStream(t, binary.LittleEndian, 0xa1b2c3d4, 50, 50)
	src := bytes.NewReader(stream)
	dst := &failingWriter{fail: 5}
	var count atomic.Uint64

	order, err := pcapHeader(dst, src)
	if err != nil {
		t.Fatalf("pcapHeader: %v", err)
	}
	count.Store(pcapGlobalHeaderLen)
	reason := pcapRecords(dst, src, order, 1<<20, &count)

	if reason != stopReasonWrite {
		t.Fatalf("reason = %q, want %q", reason, stopReasonWrite)
	}
	// Count must stay at the end of the first whole record (header + payload),
	// not advance for record 2 whose payload write failed.
	if want := uint64(pcapGlobalHeaderLen + pcapRecordHeaderLen + 50); count.Load() != want {
		t.Fatalf("count = %d, want %d (end of first whole record)", count.Load(), want)
	}
}

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
	// The state check above passes even if the file were opened O_APPEND
	// instead of O_TRUNC — "running" says nothing about what is on disk
	// underneath the stale bytes. Start has already written the new global
	// header by the time it returns, so the file must no longer begin with
	// the old capture's content.
	raw, err := os.ReadFile(manager.path(testDevice))
	if err != nil {
		t.Fatalf("read capture: %v", err)
	}
	if bytes.HasPrefix(raw, []byte("stale")) {
		t.Fatal("stale capture bytes survived Start; the file was appended to rather than replaced")
	}
}

func TestCaptureFileSizeMatchesTheReportedByteCount(t *testing.T) {
	// On the ordinary stop path (no write ever fails) the file and the page's
	// byte count must both land on the size two whole records actually take,
	// computed independently here rather than derived from either the slot or
	// the file — comparing the slot to a stat of the same file proves nothing,
	// since Get computes a ready slot's Bytes from that exact stat. The write-
	// failure path, where the truncate actually does something, is covered by
	// TestCaptureTruncatesToTheLastWholeRecordOnAWriteFailure.
	manager := testManager(t, pcapStream(t, binary.LittleEndian, 0xa1b2c3d4, 100, 100))
	if err := manager.Start(testDevice); err != nil {
		t.Fatalf("Start: %v", err)
	}
	want := uint64(pcapGlobalHeaderLen + 2*(pcapRecordHeaderLen+100))
	deadline := time.Now().Add(2 * time.Second)
	for manager.Get(testDevice).Bytes != formatBytes(want) {
		if time.Now().After(deadline) {
			t.Fatalf("byte count reached %q, want %q", manager.Get(testDevice).Bytes, formatBytes(want))
		}
		time.Sleep(2 * time.Millisecond)
	}
	if err := manager.Stop(testDevice); err != nil {
		t.Fatalf("Stop: %v", err)
	}

	slot := manager.Get(testDevice)
	if slot.Bytes != formatBytes(want) {
		t.Fatalf("page reports %q, want %q", slot.Bytes, formatBytes(want))
	}
	info, err := os.Stat(manager.path(testDevice))
	if err != nil {
		t.Fatalf("stat capture: %v", err)
	}
	if uint64(info.Size()) != want {
		t.Fatalf("file is %d bytes, want %d", info.Size(), want)
	}
}

// failingCaptureFile wraps a real file, failing the Nth write so a test can
// rig the one condition copy's truncate exists for: a write that fails
// partway through a record, after that record's header already reached disk.
// Backed by a real *os.File (not a buffer) so a test can stat the actual file
// on disk afterwards, the way a browser downloading it would see it.
type failingCaptureFile struct {
	*os.File
	writes int
	fail   int
}

func (f *failingCaptureFile) Write(p []byte) (int, error) {
	f.writes++
	if f.writes == f.fail {
		return 0, bytes.ErrTooLarge
	}
	return f.File.Write(p)
}

// stallingStream serves head immediately, then blocks until ctx is done
// before serving tail. Used to pin the order of a write failure against a
// concurrent Stop: the stream will not hand over the record whose payload
// write is rigged to fail until entry.cancel has run, and Stop calls
// entry.stopped.Store(true) before it calls cancel — so by the time the write
// fails, stopped is guaranteed already set. Without that pin, a test relying
// on goroutine scheduling to race Stop against the write failure could pass
// or fail depending on timing rather than on the code under test.
type stallingStream struct {
	head, tail *bytes.Reader
	ctx        context.Context
}

func (s *stallingStream) Read(p []byte) (int, error) {
	if s.head.Len() > 0 {
		return s.head.Read(p)
	}
	<-s.ctx.Done()
	if s.tail.Len() > 0 {
		return s.tail.Read(p)
	}
	return 0, io.EOF
}

func (s *stallingStream) Close() error { return nil }

// failingCreate returns a create seam that opens the real file and fails the
// Nth write, per failingCaptureFile.
func failingCreate(fail int) func(path string) (captureFile, error) {
	return func(path string) (captureFile, error) {
		real, err := os.OpenFile(path, os.O_RDWR|os.O_CREATE|os.O_TRUNC, 0o600)
		if err != nil {
			return nil, err
		}
		return &failingCaptureFile{File: real, fail: fail}, nil
	}
}

func TestCaptureTruncatesToTheLastWholeRecordOnAWriteFailure(t *testing.T) {
	// The reviewer mutation-verified that capture_test.go's existing tests
	// stay green with file.Truncate deleted from copy, because none of them
	// can rig a write failure at the manager level. This one can, via the
	// create seam: it must fail if the truncate is removed.
	//
	// Write sequence to the file: 1=global header, 2=record1 header,
	// 3=record1 payload, 4=record2 header, 5=record2 payload (rigged to
	// fail). Mirrors TestPcapRecordsCountStaysOnARecordBoundaryWhenAWriteFails,
	// but through the manager's create seam rather than calling pcapRecords
	// directly, so it exercises copy's own truncate rather than pcapRecords'
	// internal count.
	manager := testManager(t, pcapStream(t, binary.LittleEndian, 0xa1b2c3d4, 50, 50))
	manager.create = failingCreate(5)
	if err := manager.Start(testDevice); err != nil {
		t.Fatalf("Start: %v", err)
	}
	t.Cleanup(func() { _ = manager.Stop(testDevice) })

	slot := waitForState(t, manager, testDevice, captureReady)
	if slot.Reason != stopReasonWrite {
		t.Fatalf("reason = %q, want %q", slot.Reason, stopReasonWrite)
	}

	info, err := os.Stat(manager.path(testDevice))
	if err != nil {
		t.Fatalf("stat capture: %v", err)
	}
	// Record 2's header write (write #4) reached disk before its payload
	// write (write #5) failed, so without the truncate the file would be
	// pcapGlobalHeaderLen + 2*pcapRecordHeaderLen + 50 = 106 bytes, ending on
	// a bare header with no payload. The truncate must cut that back to the
	// last whole record: header + one full record.
	want := int64(pcapGlobalHeaderLen + pcapRecordHeaderLen + 50)
	if info.Size() != want {
		t.Fatalf("file is %d bytes, want %d (last whole record; truncate did not run)", info.Size(), want)
	}
}

func TestCaptureStopReasonWriteTakesPrecedenceOverAConcurrentStop(t *testing.T) {
	// Without the `case reason == stopReasonWrite:` arm in copy's switch, a
	// Stop landing while a write is failing would record stopReasonOperator
	// and bury the fact that the capture actually died on a write error.
	//
	// This needs the write failure pinned to happen only after Stop has set
	// entry.stopped, or the race could go either way and the test would prove
	// nothing. stallingStream provides that pin: it withholds record 2, whose
	// payload write is rigged to fail, until the capture's context is
	// cancelled — which Stop does only after storing stopped=true.
	stream := pcapStream(t, binary.LittleEndian, 0xa1b2c3d4, 50, 50)
	split := pcapGlobalHeaderLen + pcapRecordHeaderLen + 50 // header + whole record 1
	manager := newCaptureManager(t.TempDir(), "lan0")
	manager.start = func(ctx context.Context, _ string, _ netip.Addr) (io.ReadCloser, error) {
		return &stallingStream{
			head: bytes.NewReader(stream[:split]),
			tail: bytes.NewReader(stream[split:]),
			ctx:  ctx,
		}, nil
	}
	manager.create = failingCreate(5)
	if err := manager.Start(testDevice); err != nil {
		t.Fatalf("Start: %v", err)
	}

	// Wait until record 1 has landed, which is exactly when the stream is
	// about to block on ctx.Done() waiting for record 2.
	deadline := time.Now().Add(2 * time.Second)
	want := formatBytes(pcapGlobalHeaderLen + pcapRecordHeaderLen + 50)
	for manager.Get(testDevice).Bytes != want {
		if time.Now().After(deadline) {
			t.Fatalf("record 1 never landed: %q", manager.Get(testDevice).Bytes)
		}
		time.Sleep(2 * time.Millisecond)
	}

	// Stop sets entry.stopped.Store(true) and then calls entry.cancel, which
	// is what releases the stalled stream to hand over record 2 and trigger
	// the rigged write failure. So by the time that failure happens, stopped
	// is already true — this is not a race, it is Stop's own two-step order.
	done := make(chan error, 1)
	go func() { done <- manager.Stop(testDevice) }()

	select {
	case err := <-done:
		if err != nil {
			t.Fatalf("Stop: %v", err)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("Stop hung")
	}

	slot := manager.Get(testDevice)
	if slot.Reason != stopReasonWrite {
		t.Fatalf("reason = %q, want %q (stopReasonWrite must win over a concurrent operator stop)", slot.Reason, stopReasonWrite)
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

// TestCaptureStartFailureDoesNotStrandAStop drives an actual racing Stop
// through two of run's three pre-copier failure paths. Each of those paths
// must close entry.done itself: a Stop that found the slot in the window
// before the failure is already blocked on <-entry.done, and a path that
// fails to close it hangs that request forever.
func TestCaptureStartFailureDoesNotStrandAStop(t *testing.T) {
	t.Run("capture directory unusable", func(t *testing.T) {
		manager := newCaptureManager(filepath.Join(t.TempDir(), "file-not-a-dir"), "lan0")
		if err := os.WriteFile(manager.dir, []byte("x"), 0o600); err != nil {
			t.Fatalf("write blocker: %v", err)
		}
		assertRacingStopIsReleasedByAFailedStart(t, manager)
	})

	t.Run("start seam fails", func(t *testing.T) {
		manager := newCaptureManager(t.TempDir(), "lan0")
		manager.start = func(context.Context, string, netip.Addr) (io.ReadCloser, error) {
			return nil, errors.New("exec: \"tcpdump\": executable file not found in $PATH")
		}
		assertRacingStopIsReleasedByAFailedStart(t, manager)
	})
}

// assertRacingStopIsReleasedByAFailedStart fires a Stop concurrently with a
// Start that is rigged to fail before the copier goroutine exists. The race
// means Stop may find nothing at all and return errNoCapture immediately, or
// it may find the entry and block on entry.done until run closes it — both
// are acceptable outcomes. What is not acceptable is Stop never returning,
// which is what a missing close(entry.done) on the exercised path produces.
func assertRacingStopIsReleasedByAFailedStart(t *testing.T, manager *captureManager) {
	t.Helper()
	for i := 0; i < 20; i++ {
		done := make(chan struct{})
		go func() {
			defer close(done)
			_ = manager.Stop(testDevice)
		}()

		err := manager.Start(testDevice)

		select {
		case <-done:
		case <-time.After(2 * time.Second):
			t.Fatalf("Stop racing a failed Start hung on iteration %d", i)
		}

		if err == nil {
			t.Fatalf("Start succeeded when it was rigged to fail, iteration %d", i)
		}
		if state := manager.Get(testDevice).State; state != captureIdle {
			t.Fatalf("state = %q after a failed start, want %q (iteration %d)", state, captureIdle, i)
		}
	}
}

func TestCapturePathIsBuiltFromTheParsedAddress(t *testing.T) {
	manager := testManager(t, nil)
	if got, want := manager.path(testDevice), filepath.Join(manager.dir, "192.168.0.10.pcap"); got != want {
		t.Fatalf("path = %q, want %q", got, want)
	}
}

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
	// Sweep removes only files with valid IP addresses as names. The parse
	// check is what guards against deleting unrelated files. The extension
	// check is an early-out for performance; it does not solely prevent
	// deletion of non-capture files.
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
