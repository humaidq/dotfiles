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
