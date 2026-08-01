# netwatch — periodic capture, deterministic analysis

## Problem

Checking what a device on the LAN is actually reaching is currently done by
hand: open an SSH session to the router, start a capture, wait, pull byte
rankings, correlate against the resolver log, read certificates. Every step of
that gathering is mechanical, and every step has been done inconsistently.

Three concrete failures motivated this:

- A capture taken at a truncated snaplen lost the TLS ClientHello, so the
  endpoint could not be named and the whole window had to be recaptured.
- Peers were called "unexplained by DNS" after checking only a few hours of
  resolver log, when the resolver caches for 6–24 hours with prefetching. The
  addresses had been resolved earlier and the conclusion was wrong.
- Analysis keyed on IPv4 alone missed roughly half of one device's DNS, which
  arrived over its IPv6 link-local address, and merged two devices that had
  held the same DHCP lease at different times.

None of these are judgement calls. They are all fixed by writing the procedure
down once, correctly, and running it the same way every time.

## Goals

Replace the manual loop with a scheduled job that captures a sample, analyses
it locally, and appends to a report the operator reads when they choose.

The tool produces evidence, not conclusions. It reduces hours of traffic to a
short, ranked set of observations — which peer dominated, which addresses no
lookup explains, which domains are new, what a certificate claims — each of
which is a threshold or a set membership and can be recomputed and checked.

Deciding what those observations mean is a separate step and deliberately
outside the tool. Whether a dominant peer is a VPN or a video call, whether a
cluster of new domains is one operator rotating or a CDN adding edges, is
judgement, and encoding judgement as a fixed pattern only ever matches what was
already known.

Two detection paths, because neither alone is sufficient. DNS-side checks see a
service reached by name but not a tunnel dialled by hardcoded IP. Packet-side
checks see that tunnel but say nothing about a site loaded over ordinary
HTTPS. Both have produced findings the other missed.

Non-goals: alerting, dashboards, blocking, classification. Acting on a finding
stays manual, because every block added so far needed a collateral judgement —
several candidates were discarded precisely because a shared address or a
legitimate co-tenant made them unsafe.

## Architecture

Five units. The split exists so the analyser can be tested without a network.

| Unit | Runs on | Responsibility |
|---|---|---|
| `capture` | router | Resolve MACs to current addresses, run one capture, exit |
| `pull` | laptop | Invoke capture over SSH, retrieve artifacts, delete remote copies |
| `analyse` | laptop | pcap + resolver data in, observations out. No network, no SSH |
| `store` | laptop | Append observations to the durable SQLite store |
| `report` | laptop | Render this run's observations, append to a dated report |

`analyse` is pure by construction: it takes file paths and returns
observations. That makes it testable against a fixture pcap with known
contents, which is where the confidence in this tool has to come from.

`store` and `report` are separate because they answer different questions and
have different lifetimes. The report is this run; the store is the history that
makes rotation visible.

### Authentication

The router requires a hardware-token SSH key. An unattended job cannot produce
a physical tap, so the operator opens one multiplexed master and leaves it:

```bash
ssh -M -o ControlMaster=yes -o ControlPersist=168h -fN <router>
```

The tool **never opens a master**. It runs `ssh -O check` first:

- socket present → proceed
- socket absent → exit non-zero, append `RUN SKIPPED: no ssh socket` to the
  report, prompt for nothing

This matters more than it looks. A monitoring job that silently stops after a
reboot is worse than no monitoring, because an empty report reads as "nothing
found" rather than "did not run". Every run records whether it captured, and
the tool never writes a clean report it did not earn.

### Device identity

Devices are identified by MAC, resolved to a current address at run time from
the router's DHCP lease file.

Never by IP. A single address has been held by two different devices at
different times, and any IP-keyed history merges them silently. The MAC is the
stable identity; the address is a lookup result with a lifetime.

Where the resolver log is consulted, a device's IPv6 link-local address counts
as the same device. Where that address is derived from the MAC (EUI-64) the
tool computes it. Where the device uses a stable-privacy address (RFC 7217)
it cannot be derived, and the tool records that the device's IPv6 queries are
unattributable rather than pretending coverage is complete.

### Configuration and data

The watchlist is household-identifying: MAC addresses and the names of the
people who carry the devices. This repository is public. Therefore:

- the tool in git is generic and contains no device data
- the watchlist lives in `netwatch/devices.conf`, git-ignored
- reports and pcaps live under `netwatch/`, git-ignored, mode 700

`netwatch/devices.conf` is whitespace-separated, `#` for comments:

```
<mac>  <label>
<mac>  <label>
```

The domain baseline used by the novelty check is derived data, not
configuration. It records which domains have been seen before and is rebuildable
from the resolver history, so it lives under `netwatch/` with the reports and is
likewise git-ignored — it is a record of what the household has visited.

### Capture

One capture per run covering every watched MAC, not one per device:

```
tcpdump -i <lan> -s 0 -G <secs> -W 1 -w <file> \
  '(ether host <mac1> or ether host <mac2>) and not port 53'
```

Split by MAC during local analysis.

Rationale for each flag:

- `-s 0` — full payload. The TLS ClientHello carries the SNI that names an
  endpoint, and a capture cannot be re-run retroactively. Truncating to save
  space costs a repeated waiting period.
- `-G <secs> -W 1` — tcpdump exits by itself. Preferred over killing it,
  because a sudo rule scoped to tcpdump cannot signal the root process it
  started.
- `not port 53` — resolver chatter is high-count and low-byte, and would
  distort byte rankings. DNS is analysed separately from the resolver log.

The router copy is deleted once retrieved. Captures of other people's traffic
should not accumulate on a always-on device.

### Analysis

Every check is a threshold or a set membership. No check requires judgement.

**Tunnel shape**

- Top peer's share of total bytes. A tunnel carries approximately all of a
  device's traffic; ordinary use spreads across many peers with the largest
  well under half.
- Presence of UDP 500 or 4500 (IKE/IPsec NAT-T), or IP protocol 47 or 50
  (GRE/ESP). Nothing ordinary on a phone uses these.
- A single high-volume peer on UDP over a non-standard port.

**DNS correlation**

Top peers with no resolver entry pointing at them are candidates for a
hardcoded endpoint.

This check must consult the **full** resolver history, not the capture window.
The resolver caches for hours with prefetching enabled, so an address resolved
this morning and used this afternoon has no lookup inside the window. Scoping
the correlation to the window produces false "no DNS" findings on ordinary
CDN peers — an error already made by hand and worth encoding against.

**Endpoint identification**

For unexplained peers: SNI from the ClientHello, and the certificate's subject,
issuer, serial and validity span. A validity span beyond about two years, a
short hand-assigned serial, or a subject domain registered after the
certificate's `notBefore` each indicate a certificate no public CA issued.

These are indicators, not proof. Ordinary applications do serve hand-made
certificates, because a pinned client has no use for a public CA. The report
states what was observed and does not conclude.

**Novelty**

Deciding whether a domain belongs to a prohibited service is not a
deterministic operation, and the tool does not attempt it. A newly rotated
casino domain is an arbitrary string; nothing in its name, registrar or address
distinguishes it from an unremarkable one. Matching it requires knowing what
the service is, which is judgement, and encoding that judgement as a pattern
file would only match services already known — precisely what the blocklists
already do, and no help at all against the rotation this is meant to catch.

What *is* deterministic is novelty and volume. The tool therefore maintains a
baseline of every domain a device has previously resolved, and reports:

- domains resolved for the first time by this device
- domains resolved for the first time on this network at all
- the busiest domains that returned a normal answer, ranked by query count
- counts of answers that were blocked, reported only as totals

Rotation shows up here without any notion of category: an operator moving to a
fresh registrable domain produces a first-seen entry, and doing it repeatedly
produces a cluster of them. That is a mechanical observation.

The output of this check is a shortlist, not a verdict. Classifying what is on
it — this cluster is one gambling operator rotating, that one is a CDN adding
edge names — is left to a later step, whether a person or a language model
reading the report. Keeping the boundary here is the point: everything the tool
asserts can be recomputed from the same inputs and checked.

### Observation store

Reports answer "what happened in this run". They cannot answer "has this device
been reaching a rotating set of addresses for the last two months", and that is
the question that matters against an operator who rents a new address every
round.

The prior attempts at this by hand are the evidence: one messaging app was
chased across three prefixes at one cloud provider and five at another over
eight rounds, and **no single address ever repeated**. Any record keyed on the
address alone shows eight unrelated peers. The pattern only appears when the
addresses are grouped by the network that owns them and compared across time.

So each run appends to a durable store, one row per device-peer pair:

| Field | Purpose |
|---|---|
| run timestamp, device MAC | when and who |
| peer address, port, protocol | the endpoint |
| bytes each direction, packet count | volume and direction |
| enclosing /24 and /16 | the rotation key |
| SNI, if a ClientHello was seen | endpoint name without DNS |
| resolved name, or null | whether any lookup explained it |

The /24 and /16 columns are the point. They are computed arithmetically with no
external data, and they turn "eight unrelated addresses" into "eight addresses
in two networks". Where an offline address-to-ASN table is available the ASN is
recorded too, since a provider's prefixes span many /16s; without one, the /16
grouping still catches rotation within a range.

The store is SQLite — a single file, no server, and the forensic questions are
naturally queries:

- addresses this device contacted that no lookup explains, grouped by /24,
  ordered by distinct-address count
- /24s first seen in the last month, with the devices that reached them
- everything ever seen on a given port or protocol

**Retention splits by sensitivity.** Captures hold other people's traffic in
the clear and are pruned aggressively — days. The derived rows hold no payload
and are what forensics actually needs, so they are retained for months. Keeping
the metadata long and the payload briefly is the whole reason the store is
separate from the pcaps.

### Report

Appended per run, newest last, one file per day. Contents:

- run metadata: time, duration, whether the capture succeeded
- per device: total bytes, peer count, top peers with byte share
- observations, most notable first, each naming the check that produced it
- explicit `RUN SKIPPED` lines when a run could not capture

Observations are described, never concluded. "Top peer holds 100% of bytes on
UDP 4500" is the observation; naming the service, and deciding whether it is
one the household agreed to, is a later step and not the tool's call.

The report is written to be read by something else — a person, or a model given
the day's file. That is why it states counts, shares and certificate fields
rather than adjectives: the next stage needs the evidence, and anything the
tool guessed would have to be un-guessed before it could be trusted.

## Deliberate limits

**Sampling misses short activity.** A session that matters outlasts the gap
between samples; a burst that fits entirely between two runs is invisible. This
is the accepted cost of not recording the household continuously.

**Certificate checks touch the endpoint.** Retrieving a certificate means
connecting to it from the laptop. This is a normal TLS connection and reveals
only that the address was probed.

**IPv6 attribution is incomplete** where devices use stable-privacy link-local
addresses, as described above. The report says so rather than implying full
coverage.

## Forensic use

The store exists to be queried later, when a suspicion arises that no single
run would have raised. The intended workflow is retrospective: something looks
wrong, and the question becomes whether it has been happening for weeks.

Queries the schema is shaped to answer:

- which /24s has this device reached that no lookup ever explained, ranked by
  how many distinct addresses within them were used
- which of those /24s were first seen recently, and which have been present all
  along
- which addresses appeared exactly once, since an operator renting a fresh
  address per session produces precisely that
- what SNI, if any, was ever observed against a given /24

The last is the bridge back to naming an endpoint. An operator that rotates
addresses freely usually does not rotate its certificate or its SNI as often,
so a single observed name against a range of otherwise anonymous addresses is
frequently what identifies the whole range.

None of these queries classify anything. They narrow hundreds of addresses to a
handful of networks worth looking at, which is the step that was previously
done by hand across several rounds.

## Testing

`analyse` is tested against fixture pcaps committed to the repository —
synthetic, generated for the purpose, containing no real traffic. Cases: a
single-peer tunnel, ordinary multi-peer browsing, a capture containing GRE, and
an empty capture. Each asserts the exact findings produced.

`pull` is tested by asserting it refuses to run and reports a skip when no
socket is present.
