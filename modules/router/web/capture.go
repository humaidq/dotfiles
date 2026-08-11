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
