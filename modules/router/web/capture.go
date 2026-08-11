package main

import (
	"context"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"log"
	"net/netip"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"time"
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
	stopReasonLimit = "reached the size limit"
	stopReasonEOF   = "capture ended"
	// A write error and a clean end of capture are different events. A capture
	// that died on a full disk must report that fact, not claim the capture
	// simply ended.
	stopReasonWrite = "capture stopped: cannot write the capture file"
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
// count is advanced only after both the record header and payload have been
// written successfully, so it always names a whole-record boundary. The caller
// can truncate the file back to count's value if a write fails partway, and
// the result will still be valid pcap.
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
			return stopReasonWrite
		}
		if _, err := dst.Write(payload[:caplen]); err != nil {
			return stopReasonWrite
		}
		written += pcapRecordHeaderLen + caplen
		count.Store(written)
	}
}

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
	stopReasonAge      = "reached the time limit"
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

// captureFile is what copy needs of its destination. An interface rather than
// *os.File so a test can rig a write failure, which is the one path where the
// truncate in copy earns its place: real disk writes essentially never fail,
// so nothing else exercises it.
type captureFile interface {
	io.Writer
	Truncate(size int64) error
	Close() error
}

// createCaptureFile opens a device's capture file for writing. The default
// for captureManager.create; a test replaces it to rig a write failure.
//
// O_TRUNC because Start replaces a ready capture rather than refusing a
// second one, and a leftover ready file must not survive into the new
// capture as garbage at the front. 0o600: a capture is packet payloads, and
// the state directory being 0700 is not a reason for the file inside it to
// be any more permissive.
func createCaptureFile(path string) (captureFile, error) {
	return os.OpenFile(path, os.O_RDWR|os.O_CREATE|os.O_TRUNC, 0o600)
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
	// create opens a device's capture file. The seam that lets a test rig a
	// write failure to exercise copy's truncate and its stopReasonWrite
	// precedence, neither of which a real disk write can be made to fail on.
	create func(path string) (captureFile, error)
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
		create:   createCaptureFile,
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
	file, err := m.create(entry.path)
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
func (m *captureManager) copy(ctx context.Context, entry *capture, file captureFile, stream io.ReadCloser, started chan<- error) {
	defer close(entry.done)

	order, err := pcapHeader(file, stream)
	if err != nil {
		entry.cancel()
		stream.Close()
		file.Close()
		os.Remove(entry.path)
		wrapped := fmt.Errorf("capture produced no pcap stream: %w", err)
		// Logged here rather than left to the caller: once the 500ms grace
		// window has passed, nobody is receiving on started, and without this
		// the failure would vanish — no reason is stored (see below), so the
		// journal would be the only place it could still surface.
		log.Printf("capture device=%q start failed: %v", entry.device, wrapped)
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
	// Back to the last whole record. pcapRecords advances the count only once
	// a record's header and payload have both been written, so the count names
	// a record boundary — and a write that failed part way through a record is
	// the one way this file could otherwise end torn.
	if err := file.Truncate(int64(entry.bytes.Load())); err != nil {
		log.Printf("capture device=%q truncate: %v", entry.device, err)
	}
	file.Close()

	// pcapRecords sees a closed pipe and nothing else, so which of the ways a
	// capture ends actually happened is decided here.
	switch {
	case reason == stopReasonWrite:
		// The more useful of the two things that may have happened, so an
		// operator stop does not paper over a capture that ran out of disk.
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
		// A missing file is the ordinary "nothing captured yet" and floods the
		// journal if logged; anything else (permissions, I/O) is not ordinary
		// and would otherwise read as absence with no trace of the real cause.
		if !errors.Is(err, os.ErrNotExist) {
			log.Printf("capture device=%q open: %v", device, err)
		}
		return nil, nil, errNoCapture
	}
	info, err := file.Stat()
	if err != nil {
		log.Printf("capture device=%q stat: %v", device, err)
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
			// Early-out on unrelated files. The parse check below is what
			// prevents deletion of captures that are not named <IP>.pcap.
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
		// Delete the file we actually found, not a path rebuilt from its name.
		// The file whose age was measured must be the file that is deleted.
		target := filepath.Join(m.dir, item.Name())
		if err := os.Remove(target); err == nil {
			log.Printf("capture swept device=%q age=%s bytes=%d",
				device, now.Sub(info.ModTime()).Round(time.Minute), info.Size())
		}
	}
}

// sweepEvery runs the sweep until the process exits. Started once from
// main.go; it holds no state of its own. The ticker is intentionally never
// stopped because the sweep runs for the process's lifetime.
func (m *captureManager) sweepEvery(interval time.Duration) {
	for range time.Tick(interval) {
		m.sweep(time.Now())
	}
}
