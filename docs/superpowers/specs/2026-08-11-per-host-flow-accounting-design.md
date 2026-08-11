# Per-host flow accounting

Status: design. Nothing below is built yet.

## Why

Every tunnel found on these networks has been found by hand, from a packet
capture, using one discriminator: **a tunnel peer holds 70-100% of one device's
bytes, where the same device browsing normally sits at 20-35%.** A morning of
`inspection-loop.sh` runs on 2026-08-11 turned up six handsets running three
different clients across thirteen addresses, and the share figure identified
every one of them.

None of that is visible from the dashboard, because no per-host traffic data
exists. The routers export exactly two families of traffic metric:

- `node_network_*` — per interface, so the whole LAN as one number.
- `router_qos_*` — labelled `class`, `device`, `instance`. Three classes:
  `default`, `throttle`, `imo`.

Neither can answer "which device is this, and what fraction of its traffic goes
to one peer". The DNS side is rich — blocky logs every query with a client —
but DNS only shows the *names a device asked for*, and the entire point of the
clients being chased here is that they do not ask. A device dialling a rented
VPS by address with the hostname in SNI leaves no DNS trace at all.

So the gap is precise: the dashboard can show suspicious *naming* behaviour and
cannot show suspicious *traffic* behaviour, and the second is the one that
actually identifies a tunnel.

## What to count

Two different questions, which want two different mechanisms. Conflating them
is the main way this design could go wrong.

### Totals per host — nftables set with per-element counters

```
set hosts4 { type ipv4_addr; flags dynamic; counter; }
```

with one rule per direction in a forward chain updating the set from `ip saddr`
and `ip daddr`. Elements appear on first sight, so nothing needs to enumerate
the LAN, and each element carries its own monotonic byte and packet counter.

Exported as:

```
router_host_bytes_total{client, direction}
router_host_packets_total{client, direction}
```

**Why not conntrack for this.** Conntrack counters live and die with the flow.
Summing them gives the bytes of *currently tracked* connections, which drops to
near zero whenever a long download ends — a gauge, not a counter, and
`rate()` over it is meaningless. Making it monotonic would mean the collector
holding a previous snapshot keyed by 5-tuple, diffing it, and persisting an
accumulator across restarts. That is a lot of state to get wrong for a number
nftables will keep correctly for free.

### Share per host — conntrack, with accounting turned on

The share figure needs the per-peer breakdown that set counters deliberately
throw away. Conntrack has it, and only needs a sysctl:

```
net.netfilter.nf_conntrack_acct = 1
```

Currently `0` on both routers, which is why `conntrack -L` prints no byte
figures today.

The collector reads `conntrack -L`, groups by LAN address, and exports **only
the derived figures**, never the raw per-peer rows:

```
router_host_top_peer_share_ratio{client}      0.0-1.0
router_host_peer_count{client}                 distinct peers this sample
router_host_top_peer_info{client, peer, port}  always 1
```

Cardinality is the reason for that shape. A metric labelled by peer address is
unbounded — a phone browsing normally touches hundreds of CDN addresses an hour
and every one becomes a permanent series. Reducing to a share *inside the
collector* keeps it at one series per host per metric.

`top_peer_info` is the exception and is deliberately kept separate: its label
set churns as the peer changes, so it will accumulate stale series between
restarts. It stays because knowing *which* address holds the share is most of
the value of knowing there is one, and a churning info metric with roughly one
live series per host is a cost worth paying. If it turns out not to be, drop it
and read the address from the router.

### Cardinality budget

Roughly 40 devices across the two networks:

| Metric | Series |
|---|---|
| `router_host_bytes_total` | 40 × 2 directions = 80 |
| `router_host_packets_total` | 80 |
| `router_host_top_peer_share_ratio` | 40 |
| `router_host_peer_count` | 40 |
| `router_host_top_peer_info` | ~40 live, churning |

About 280 series, against the 687 metric names already in Prometheus. Not a
concern.

## Where it runs

Modelled directly on `modules/router/qos-metrics.nix`, which already does this
job for tc and nft: a Python writer, a `oneshot` service, and a timer at 15s
against a 60s scrape so no sample is more than a quarter-interval stale. Same
textfile directory, a second file alongside `qos.prom`.

The one departure: conntrack sampling is heavier than reading a qdisc tree. The
table holds thousands of entries and the collector walks all of them. If 15s
proves expensive, this file is the first place to look — the share figure is
useful at 60s in a way the QoS counters would not be.

Include a `router_host_collector_success` gauge, for the same reason
`qos-metrics.nix` has one: a collector that silently stops producing looks
identical to a quiet network.

## What this does not solve

**The unresolved-address ratio.** The strongest single discriminator available
is not share but *"this device sent bytes to an address it never looked up"* —
that is what separates a tunnel from a device streaming video, since a CDN flow
always has a resolver line behind it and a tunnel never does. Building it means
correlating flows against blocky's answers per client: a cache of
(client, resolved address) with a TTL, and a ratio of bytes going to addresses
absent from it.

That is a genuinely different piece of work — it needs blocky's answers in a
queryable form on the router rather than only in Loki, and it needs care about
CDN addresses resolved by one device and connected to by another. Worth doing
second, and worth doing: it is the one metric that would have flagged every
finding of 2026-08-11 without a human reading whois.

**Encrypted ClientHello.** Nothing here inspects SNI, so nothing here degrades
if ECH arrives. Noted only because the companion idea — matching the existing
blocklist against SNI and HTTP Host, which would close the CDN-fronted bypass
that address throttling cannot touch — does depend on SNI staying visible.

## Privacy

This repository is public. The collector exports LAN addresses, which are
private-range and rotate with DHCP, and never hostnames, MAC addresses or
anything naming a person. No sample output, byte total or device name from a
real capture belongs in this file or in a committed dashboard JSON.

## Order of work

1. `net.netfilter.nf_conntrack_acct = 1` on both routers. Prerequisite for
   everything else and independently harmless.
2. The nft set and its two forward rules, plus `router_host_bytes_total`. This
   alone makes "which device is loudest" a dashboard question.
3. The conntrack collector and the share metrics. This is the part that makes a
   tunnel obvious rather than merely visible.
4. The unresolved-address ratio, as its own design.
