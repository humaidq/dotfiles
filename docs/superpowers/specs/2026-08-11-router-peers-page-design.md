# Router peers page

Status: design, approved. Nothing below is built yet.

## Why

Finding a tunnel on these networks has so far meant a packet capture, a whois,
and a shell. The dashboard now shows *that* a device looks wrong — top-peer
share, STUN discovery, blocked control-plane names — but it cannot show *who*
the device is talking to, and it cannot act.

It cannot show peers because a Prometheus metric labelled by peer address is
unbounded: a phone browsing normally touches hundreds of CDN addresses an hour
and each becomes a permanent series. That is why
`2026-08-11-per-host-flow-accounting-design.md` exports only derived figures.

The gap this closes is the last two steps of the loop that has been run by hand
all day: given a suspicious device, list what it is talking to right now with
enough context to judge it, and shape the peer that deserves it.

## Scope

A page at `/peers/{lanIP}` on each router, served over the mesh only, listing
the device's current peers with ASN attribution and a throttle and block button
per peer. Live only — no history, no storage, no time range. Anything
historical is the dashboard's job.

## Architecture

One service. The routes go into the existing `router-web` rather than a new
daemon, which was a deliberate choice between two options:

- **Separate mesh-bound service** holding the capability, leaving `router-web`
  unprivileged. Smallest privileged surface.
- **Extend `router-web`** — chosen. One service, one binary, one unit.

The cost of the chosen option is stated plainly so a later reader is not
surprised by it: the process that serves an unauthenticated landing page to the
whole LAN also holds `CAP_NET_ADMIN` and can rewrite the firewall. That is
accepted, and the mitigation below is what keeps it from being reachable.

### Two listeners, not one wildcard

`router-web` currently binds `0.0.0.0:80`. It will instead open two listeners in
the one process:

| Listener | Serves |
|---|---|
| `${lanAddress}:80` | the existing landing page mux, unchanged |
| `${meshAddress}:80` | a second mux carrying only the peers routes |

`lanAddress` already exists and carries a prefix (`10.20.0.1/16`), so the
address is taken for binding and the network is kept for the `{lanIP}` guard
below — one option serving both, with no chance of the two disagreeing.

`meshAddress` does **not** exist and has to be added as
`sifr.router.meshAddress`, nullable and unset by default. The mesh is `sifr0`
on `10.10.0.0/24` today, but it appears nowhere in the router module — only as
static DNS mappings in `blocky-common.nix`. When the option is null the second
listener is never opened and the peers routes are not registered, so the
feature is opt-in per host and a router that has not been given a mesh address
behaves exactly as it does now.

Explicit option rather than resolving `sifr0`'s address at startup: the
interface may not be up when `router-web` starts, and a service that sometimes
fails to bind depending on start order is worse than one that is configured.

Separation is a property of **which socket a route is registered on**, not of a
check inside a handler. A route added carelessly to the LAN mux later cannot
become mesh-only by accident, and — the case that matters — a peers route
cannot become LAN-reachable by someone forgetting an `if`. Binding by address
also means the kernel refuses the connection rather than the application
refusing the request.

The behaviour change: `router-web` stops answering on the mesh address for the
landing page. It is a LAN convenience and nothing links to it from the mesh.

## Routes

| Method | Path | Effect |
|---|---|---|
| `GET` | `/peers/{lanIP}` | render the page |
| `POST` | `/peers/{lanIP}/throttle` | `tempthrottle add <peer>` |
| `POST` | `/peers/{lanIP}/block` | `tempblock add <peer>` |

Both mutations take `peer` as a form value and redirect back to the page on
completion. POST-only and never GET: a mutation reachable by GET is one browser
prefetch, one crawler, or one refresh away from firing on its own.

Both buttons rather than only throttle, because the lever depends on the
finding and the file that records them already says so: tunnel endpoints are
throttled, since a dropped node is replaced within a minute and a slow one is
not; BIGO and imo control-plane hosts are blocked by address. Offering only
throttle would mean dropping to a shell for half the cases.

## Peer listing

`conntrack -L -o extended` gives every live flow with its byte counters, which
requires `net.netfilter.nf_conntrack_acct = 1` — already set by the host-flow
accounting work.

Flows are grouped by peer for the requested address, summing both directions,
and sorted by bytes descending. Share is the top peer's bytes over the device's
total. This is deliberately the same reduction the `host-flow-textfile`
collector performs, including how it decides which end of a tuple is the
device, so the number on the page and the number on the dashboard cannot
disagree.

Live only, and the page should say so: a peer that has stopped is absent, and a
device idle at that moment has an empty table. The dashboard is where history
lives.

## ASN attribution

`ip2asn-combined.tsv` — 688k rows, ~15 MB, covering v4 and v6 as
`start, end, asn, country, description`. Vendored into the flake and read from
its Nix store path at startup, parsed into sorted range slices and binary
searched per lookup.

The approach is lifted from `pdb/src/routes/ip2asn_lookup.go`, minus the HTTP
client-IP helpers, which this does not need. Same language, same data file, and
the code is already the author's own under Apache-2.0.

Read from a store path rather than `go:embed`, unlike `pdb`: embedding would put
15 MB into every `router-web` closure for a service whose whole job is otherwise
a landing page.

A local table rather than whois or a DNS-based lookup service. Whois is slow
and rate-limited per address and the page needs a dozen at once; a DNS lookup
service would hand every peer address the household talks to to a third party,
which is the opposite of the point.

Displayed per peer: AS number, organisation name, country code.

## Guards

- `{lanIP}` must parse and fall within the prefix carried by `lanAddress`,
  else 404.
- A peer must be a **public** address: RFC1918, loopback, link-local,
  multicast and unspecified are refused. Without this, a crafted POST could
  throttle the router itself or another device on the LAN.

The mesh needs no rule of its own — `10.10.0.0/24` is inside `10.0.0.0/8` and
is already refused as RFC1918. Worth stating rather than leaving to be
rediscovered, because "block the mesh range too" looks like a missing case.

The second guard is the one that matters. The page is reachable only over the
mesh, so it assumes a trusted caller — but a trusted caller can still make a
mistake, and shaping your own gateway is a mistake that is hard to undo from
the far side of it.

## Journal

The service runs under systemd, so stdout is already journald. Each mutation
emits one line with a stable prefix:

```
peer-action action=throttle peer=203.0.113.10 asn=64496 org="Example Hosting" cc=NL device=192.168.0.10 share=0.94 result=ok
```

`journalctl -u router-web | grep peer-action` then yields the collectable list.
The ASN, share and originating device are included deliberately: an address on
its own ages badly, and the reason for a block is exactly what is wanted months
later when deciding whether it still belongs in a list.

Failures log the same line with `result=` carrying the error, so a block that
did not happen is not silently indistinguishable from one that did.

## Errors

- A failing `tempthrottle` or `tempblock` surfaces its stderr on the page.
  Reporting success for a block that did not happen is the worst available
  outcome, because it is invisible until someone checks the firewall.
- A missing or unparseable TSV degrades to "ASN unknown" and still renders the
  peers. Attribution is the nice-to-have; the peer list is the point.
- An unreadable conntrack table is an error page, not an empty one — an empty
  table means "this device is idle", and the two must not look alike.

## Testing

Go unit tests, table-driven, in the existing package:

- conntrack aggregation against fixtures in the real `-o extended` format,
  including a router-originated flow that must be skipped and a flow between
  two LAN addresses that must not appear
- ASN lookup against known ranges at boundaries, plus an address in no range
- the public-address guard, against RFC1918, loopback, link-local, the mesh
  range and a public address
- one asserting the peers routes are **not** registered on the LAN mux

## Out of scope

- History of any kind. The dashboard covers it.
- Authentication. Mesh reachability is the trust boundary, matching ssh.
- Un-throttling from the page. `tempthrottle del` exists and removing something
  is not the operation that wants to be one click away.
- Any write to the tracked list files. `tempthrottle` is not persistent by
  design; committing an address remains a considered act.
