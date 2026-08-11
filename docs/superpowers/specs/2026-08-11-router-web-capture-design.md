# Packet capture from the peers page

## Problem

The peers page shows which endpoints a device is talking to, how much, and over
which ports. It cannot show what is in those conversations. Answering "what is
this actually sending" today means opening an ssh session to the router,
remembering tcpdump's flags, picking a filename, remembering to bound the
capture, and then copying the file off by hand. That friction is paid every
time, and it is paid at the moment the traffic is happening — which is the
moment it is least convenient.

The page already has the device's address, already runs on the mesh-only
listener, and already shells out to privileged tools. A capture button belongs
there.

## Scope

One capture per device, covering all of that device's traffic. Started and
stopped from `/peers/{device}`, downloaded in the same click that stops it,
bounded at 200 MiB and 30 minutes so that a forgotten capture cannot fill the
router's disk.

Not in scope: per-peer captures, a filter box in the UI, and capture of a
device's IPv6 traffic from a page keyed on its IPv4 address. The filter is
`host <the address this page is for>` and the page says so.

## Approach

router-web owns the capture process directly. It spawns

    tcpdump -i <lan> -nn -s 0 -U -w - host <device>

and copies the pcap stream from tcpdump's stdout to disk through a copier that
understands pcap record framing. The alternative — a `capture` shell tool
alongside `tempblock` and `killconn`, using `dumpcap -a filesize:` — reads
better against repo convention but costs a 336 MB closure on the router for
wireshark-cli, against 43 MB for tcpdump which the base module already
installs. tcpdump on its own has no size-based autostop (`-C n -W 1` is a ring
that never stops), so the choice was between a new dependency and about sixty
lines of framing code. The framing code also yields the exact cut and the live
byte counter for free, and lands in the language where this package already has
real test coverage.

`-U` (packet-buffered) is deliberate: without it tcpdump buffers its non-tty
stdout, and both the byte counter on the page and the file on disk would lag
the traffic by a chunk at a time.

## Components

### `modules/router/web/capture.go`

`captureManager` owns the slots:

```go
type captureManager struct {
    mu       sync.Mutex
    active   map[netip.Addr]*capture
    dir      string
    iface    string
    maxBytes uint64
    maxAge   time.Duration
    retain   time.Duration
    start    func(ctx context.Context, iface string, device netip.Addr) (io.ReadCloser, error)
}
```

`start` is the seam. In production it spawns tcpdump and returns its stdout; in
tests it returns a canned pcap stream, so no test touches a real interface.

`pcapCopy` is what makes the cap exact. It reads the 24-byte global header,
recognising both byte orders and both the microsecond (`0xa1b2c3d4`) and
nanosecond (`0xa1b23c4d`) magics, and copies it. It then loops: read a 16-byte
record header, take `caplen` from it in the file's byte order, and if
`written + 16 + caplen` would exceed the limit, stop. Otherwise copy the whole
record through. The file therefore always ends on a record boundary and always
parses. `pcapCopy` returns why it stopped: `limit`, `eof`, or an error.

### State is derived, not stored

`Get(device)` resolves a slot in three steps:

1. present in `active` → **running**, with the live byte count and start time;
2. otherwise `<dir>/<device>.pcap` stats → **ready**, with that file's size and
   mtime;
3. otherwise → **idle**.

Nothing about a stopped capture is held in memory and nothing is persisted
beyond the pcap itself. A router-web restart therefore needs no recovery code:
the partial file a killed capture leaves behind reads as a ready capture, which
is exactly what it is.

The capture path is built from the parsed `netip.Addr`, never from request
text, and `s.device` has already rejected any address outside the LAN prefix
before a path exists.

## Routes

All on the mesh mux, under `/peers/{device}/`, all sharing the existing
`Sec-Fetch-Site` CSRF check.

| Route | Behaviour |
| --- | --- |
| `POST capture/start` | Refused if this device already has a capture running. A *ready* capture is replaced. Waits up to 500 ms for either the pcap global header or an early process exit, then redirects to the page. |
| `POST capture/stop` | Kills the process, closes the file, answers `303` to the download URL. |
| `GET capture.pcap` | Serves a ready capture as `attachment; filename="192.168.1.57-20260811-2043.pcap"`. Refused while running or when absent. |
| `POST capture/discard` | Deletes the file; the slot returns to idle. |

The 500 ms wait on start is what keeps the button honest. A missing tcpdump or
an unusable interface fails synchronously and renders as a notice, rather than
showing a running capture that is not running.

Stop redirecting to the download, rather than streaming the response body, is
what lets one click both stop and download while the file stays on disk — a
cancelled or failed download is still there afterwards.

Start, stop and discard are written to the journal through the existing
`logAction`, which already renders a peerless action's peer as `-`. A capture
is a more invasive act than a block and should be as collectable later.

## Interface

The banner sits above the peers table, next to `drop all connections`:

- idle — a `start capture` button;
- running — `capturing — 12.4 MiB of 200.0 MiB, 3m elapsed` with
  `stop & download`, and a note that starting a new capture discards a waiting
  one;
- ready — `capture ready — 43.1 MiB, stopped 14:02` with `download` and
  `discard`, plus why it stopped.

Sizes are rendered by the existing `formatBytes`, so the banner reads in MiB
throughout rather than mixing units with the limit.

Figures update on reload. No JavaScript and no polling: the page is otherwise
entirely server-rendered forms, and a self-refreshing banner would re-read the
connection table — the expensive part of rendering this page — every few
seconds.

## Limits

| Limit | Value | Mechanism |
| --- | --- | --- |
| Size | 200 MiB | `pcapCopy`, cut on a record boundary |
| Duration | 30 minutes | `context.WithTimeout` on the tcpdump process |
| Retention | 24 hours | Hourly sweep of `*.pcap` by mtime |

Whichever of size and duration fires first stops the capture, and the reason is
shown in the banner. The sweep skips any file whose device is in `active`, and
logs what it deletes.

There is no total disk ceiling. The worst case is one 200 MiB file per LAN
device captured within the retention window — on a thirty-device network, 6 GB
if every device were captured, which is unlikely but not impossible. Adding a
ceiling later is a guard on `start`, not a redesign.

## Failure handling

Every failure leaves the peers page working, matching how unreadable conntrack
and lease files are already handled there.

| Failure | Result |
| --- | --- |
| tcpdump missing or interface unusable | Start fails synchronously; notice on the page; slot stays idle |
| tcpdump dies mid-capture | What was written stays as a ready capture; the reason records the error |
| Capture directory unwritable | Start fails with a notice; nothing else on the page is affected |
| Unparseable pcap header | Treated as a start failure rather than writing a file that will not open |
| Device outside the LAN prefix | `404` from the existing `s.device` guard, before any path is built |

## Changes to existing code

`peers.go`: the `Sec-Fetch-Site` check currently lives inside `handleAction`'s
closure. The four capture routes need the same guard, so it moves out to a
helper both call. Left in place it would be copy-pasted three more times, and
one copy would eventually drift — which on these routes means an
unauthenticated firewall mutation.

`peers.html`: the banner, and a note that the capture covers the address the
page is for.

`web.nix`:

- `CAP_NET_RAW` added to `AmbientCapabilities` and `CapabilityBoundingSet`.
  tcpdump inherits router-web's ambient set, so no setuid helper is needed.
- `pkgs.tcpdump` added to the service `path`. `DynamicUser` services build
  their PATH solely from that list.
- `StateDirectory = "router-web"`, with `ROUTER_CAPTURE_DIR` pointing at it.

No new package and no change to `tools.nix`.

## Testing

`capture_test.go`, in the style of the existing tests in this package. The
`start` seam means none of these open a real interface.

- `pcapCopy` cuts at the last whole record under the limit, and the output
  re-parses as valid pcap.
- Both byte orders, and both the microsecond and nanosecond magics.
- A stream truncated mid-record ends at the last complete record.
- A first record larger than the limit produces a header-only file, not a
  corrupt one.
- Starting twice for one device is refused; starts for two devices both run.
- Stop, download, discard round-trip; downloading a running or absent capture
  is refused.
- Restart recovery: a `.pcap` on disk with an empty `active` map reads as ready
  with the correct size and time.
- The duration backstop, via a millisecond `maxAge`.
- The retention sweep skips files belonging to running captures.
- A device outside the LAN prefix gets `404` on every capture route.
