# CDN volume quota for low-trust devices

Date: 2026-08-14
Status: approved, not yet implemented

## Problem

A tunnel client on the LAN moves bulk data through CDN edges using domain
fronting. Capture `192.168.50.219-20260812-1324.pcap` shows it plainly:

- 2,462 × `POST /` with `Host: www.shoppeninegreen.com` to `95.100.170.59`
  and `.57`, the genuine Akamai edge
- every response `200`, `Content-Type: application/octet-stream`, no
  `User-Agent`
- **45.46 MB down / 3.01 MB up in 427 s on 2 TCP streams — 0.85 Mbit/s
  sustained**

`www.shoppeninegreen.com` resolves nowhere and appears in no DNS answer in any
capture. The Host header is pure cover; the edge address is shared with
everything legitimate the house reaches.

That last point is why the existing instruments do not fit:

- **The address cannot be blocked or throttled outright.** `95.100.170.0/24`
  serves the whole house. It is on the `lowTrustNeverCover` tripwire list for
  exactly this reason.
- **The name cannot be blocked.** It is never resolved, so no DNS-layer rule
  ever sees it.

What distinguishes the abuse from ordinary CDN use is neither address nor name.
It is **volume**. Measured across all captures from 2026-08-12 to 14:

| | downstream | streams |
|---|---|---|
| Fronted (cover names) | 46.0 MB | 258 |
| — of which `www.shoppeninegreen.com` on port 80 | **45.5 MB (99%)** | 2 |
| — all other cover names combined | 0.5 MB | 256 |
| Genuine Akamai / app hostnames | 9.4 MB | 70 |

Genuine CDN traffic is 9.4 MB spread over two and a half days, largest single
stream 5.3 MB. The fronting is 45.5 MB in seven minutes. A volume threshold
separates them by more than an order of magnitude.

## Goal

For low-trust pool devices only, allow ordinary CDN use at full speed and shape
sustained bulk transfer to CDN space down to the existing 100 kbit/s tier.
No other device on the LAN is affected by any rule in this design.

## Non-goals

- Blocking or dropping CDN traffic. The consequence is always shaping.
- Affecting devices outside the low-trust pool.
- Catching the fronting by name or by address. Both were ruled out above.

## Design

### Mechanism

#### Why this cannot live in `lowtrust_policy`

The obvious placement is the existing `lowtrust_policy` chain. It is wrong, for
the reason commit b39ff9c already records against a different rule:

> The pool rules matched `ether saddr @lowtrust_macs`, which only matches
> upload — a download's source MAC is the ISP's.

`lowtrust_policy` is entered from `forward_lowtrust` on `ether saddr
@lowtrust_macs`, so it sees **upload only**. Every existing rule in it is a
drop, and dropping the outbound packet is sufficient to stop a conversation, so
the one-directional match has never mattered there.

It matters here. The traffic this quota exists to shape is **download**:
45.5 MB down against 3.0 MB up. A rule placed in `lowtrust_policy` would meter
and shape the 3 MB and never see the 45 MB.

#### The sentinel conntrack mark

`sifr.router.qos.lowTrustMark` (default 9) is already stamped on every pool
device's conversation, and `default.nix` already relies on it crossing both
directions:

> Matches in both directions, unlike everything above it: this is the rule that
> catches the download half, which carries the sentinel on its conntrack entry
> but no LAN MAC to match on.

That is exactly the property this design needs, so it reuses it rather than
inventing a parallel mechanism or introducing a pool-device IP set.

#### The rules

A new chain entered from `forward_lowtrust` on the sentinel rather than on MAC:

```
# in forward_lowtrust, alongside the two existing MAC jumps:
ct mark ${toString cfg.qos.lowTrustMark} jump lowtrust_cdn_quota

chain lowtrust_cdn_quota {
  # upload: device -> CDN. Bucket keyed on the device (ip saddr).
  oifname "${cfg.ppp}" ip daddr @cdn_quota4 \
    update @cdn_over4 { ip saddr limit rate over 5825 bytes/second burst 50 mbytes } \
    counter meta mark set 0x2 comment "cdn volume quota exceeded (upload, IPv4)"

  # download: CDN -> device. Bucket keyed on the device (ip daddr).
  oifname "${cfg.lan0}" ip saddr @cdn_quota4 \
    update @cdn_over4 { ip daddr limit rate over 5825 bytes/second burst 50 mbytes } \
    counter meta mark set 0x2 comment "cdn volume quota exceeded (download, IPv4)"

  # ... and the IPv6 twins against @cdn_quota6 / @cdn_over6
}
```

Both directions key the bucket on **the LAN device's own address** — `ip saddr`
on the way out, `ip daddr` on the way in — so both update the same element and
the budget is one figure per device covering CDN traffic in either direction,
not two independent allowances.

`meta mark set 0x2` is the **existing** throttle mark. It steers into the HTB
class already defined in `qos.nix` at `sifr.router.throttle`; download is shaped
on `lan0` egress and upload on `ppp` egress, which is the same arrangement
`forward_throttle` already relies on. This design adds no tc classes and no new
marks.

#### Ordering

The sentinel is stamped in `qos-mark` on the upload path by MAC. A download
packet can only exist after an upload packet created the conntrack entry, so by
the time the download rule runs the mark is always present. There is no
first-packet race in the direction that matters.

### Supporting sets

```
set cdn_over4 { type ipv4_addr;  flags dynamic, timeout; timeout 2h; size 1024; }
set cdn_over6 { type ipv6_addr;  flags dynamic, timeout; timeout 2h; size 1024; }
```

The kernel keeps one token bucket per source address in these sets. Membership
is created and refreshed by the `update` statement; the 2 h timeout reaps
devices that have gone quiet.

### The arithmetic

- **`burst 50 mbytes`** — the free allowance. A pool device pulls its first
  50 MB from CDN space at full link speed, untouched.
- **`5825 bytes/second`** — the refill, equal to 20.97 MB/hour sustained.
- Once the bucket is empty every further packet matches, is marked `0x2`, and
  lands in the 100 kbit/s class.
- 100 kbit/s is 12.5 KB/s, which is **above** the 5825 B/s refill. A client that
  keeps pulling therefore stays tripped instead of oscillating in and out of the
  throttled class. This is deliberate: it is what makes the rule stable without
  any hysteresis logic.
- Stop pulling for roughly an hour and the bucket refills. Full speed returns
  with no intervention, no timer and no reset job. The rolling window is a
  property of the token bucket, not something this design maintains.

Against the measured traffic: the fronting burns 50 MB in about eight minutes
and crawls after that. Genuine CDN use never approaches the threshold.

### Why the rate is written per-second

`limit rate over 20 mbytes/hour` is the natural expression and **the kernel
rejects it**:

```
Error: Could not process rule: Value too large for defined data type
```

Verified on kernel 6.18.43 by loading candidate rulesets in a private network
namespace (`unshare -rn nft -f`). `/hour` overflows the kernel's internal rate
conversion for byte-unit limits. `/second` and `/minute` are accepted. 20 MB/hour
= 20971520 / 3600 = 5825 bytes/second.

Burst values of 20, 50, 100 and 500 mbytes were all accepted and echoed back
unchanged by `nft list chain`, so 50 mbytes is comfortably within range.

### Address set generation

New file `modules/router/custom-cdn-quota-asns.txt`, one AS number per line,
expanded at build time from the `ip2asn-combined.tsv` already in the repo into
`cdn_quota4` and `cdn_quota6`.

Contents: Akamai's edge ASNs — AS12222, AS16625, AS17204, AS20940, AS21342,
AS24319, AS26008, AS31108, AS33905, AS34164, AS35994, AS36183 — **excluding
AS63949 (Akamai Connected Cloud / Linode)**, which is rented tenant space
already covered by `custom-lowtrust-asns.txt` and is not an edge. Plus Datacamp
/ CDN77 / BunnyCDN, the other CDNs this client has been observed fronting
through.

### The never-cover tripwire must NOT apply here

`lowTrustASNGen` refuses to build if any generated range contains an address on
`lowTrustNeverCover`. That list holds `95.100.170.42`, `23.44.201.155`,
`185.93.2.251` and `143.244.56.58` — all CDN edges this set is *supposed* to
cover. Reusing that generator verbatim fails the build immediately.

So this needs a sibling generator with the tripwire removed. That removal is
safe **only** because of two properties that must be stated in the file itself,
because they are what the guard was protecting against:

1. The consequence of a match is shaping to 100 kbit/s, never a drop.
2. It applies to low-trust pool devices only, never house-wide.

If either ever stops being true, the guard has to come back.

Everything else about the generator is kept: build-time expansion from the ASN
table, and hard failure on an AS number the table does not know, so a typo
cannot silently produce an empty set.

### Configuration

In `modules/router/default.nix`, under `sifr.router.cdnQuota`:

| option | default | meaning |
|---|---|---|
| `enable` | `false` | whole feature off unless asked for |
| `bytesPerSecond` | `5825` | refill rate; 20.97 MB/hour |
| `burst` | `"50 mbytes"` | free allowance before shaping starts |

### Dependencies, asserted at build time

This feature depends on the sentinel conntrack mark. That mark is stamped
inside a `lib.optionalString cfg.lowTrust.enable` block in `default.nix`, so
`sifr.router.lowTrust.enable` is the real dependency — there is no
`sifr.router.qos.enable`; `qos` is a submodule of settings with no flag of its
own, and the whole router module is already gated on `sifr.router.enable`.

Enabling `cdnQuota` with `lowTrust` off would produce a chain whose entry
condition is a mark nothing ever sets: it would load cleanly, count zero, and
shape nothing. That is the silent fail-open the low-trust design repeatedly
guards against, so it is an assertion rather than a comment:

```
assertion = !cfg.cdnQuota.enable || cfg.lowTrust.enable;
```

`bytesPerSecond` must also be rejected if expressed in a unit the kernel cannot
take — see below. The option is an integer of bytes per second precisely so the
`/hour` form cannot be written by accident.

## Failure modes

**The known collateral, stated plainly: a pool device downloading a single
update larger than 50 MB from a CDN will trip this and then crawl.** This will
happen. It is the first thing to suspect if a pool device reports slow
downloads. The 50 MB burst was chosen over 20 MB specifically to make it rarer.

Everything else degrades rather than fails. A tripped device still has
100 kbit/s to CDN space; nothing is dropped, no connection is reset, and the
device recovers by itself after about an hour of quiet.

If the ASN table is wrong about a prefix — and it is known to be wrong about at
least one, see `custom-lowtrust-subnets.txt` — the effect is that some CDN space
is not covered by the quota. That is a silent gap, not a breakage.

## Verification

- `nft list set inet router-blocklists cdn_over4` — lists precisely which
  devices are currently over budget and how long their entries have left. This
  is the primary debugging surface.
- The rule's `counter` shows how often the quota is firing.
- `nft list set inet router-blocklists cdn_quota4` — confirms the expansion
  produced the expected prefixes.
- Build gate: `nix build .#nixosConfigurations.bingo.config.system.build.toplevel`
  must pass, and the generator must still fail on an unknown AS number.

## Prior art in this repo

- `custom-lowtrust-asns.txt` — the ASN-expansion pattern and its build-time
  validation.
- `forward_throttle` in `ip-blocklist.nix` — the `meta mark set 0x2` convention.
- `qos.nix` — the HTB class this design steers into, and the 2026-08-13 note on
  why the throttle tier is a bare rate cap with no impairment.
