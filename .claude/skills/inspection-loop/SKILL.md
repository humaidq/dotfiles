---
name: inspection-loop
description: Use when a device is tunnelling through rotating endpoints and single blocks keep being outrun — captures on bingo and bongo in rounds, drops each node the device moves to, and records what was taken
---

# Inspection loop

## Overview

Some tunnel clients carry a node pool. Drop the address they are using and they
reconnect somewhere else within seconds — a different provider each time. One
capture and one block cannot settle that; only repetition can, and only
sometimes.

This skill runs that repetition on both routers: capture a window, find the peer
that holds nearly all of one device's traffic, drop it, capture again, drop
where it went. Either the pool runs thin enough that the app gives up, or it
does not — and knowing which took how many rounds is itself the finding.

**The loop is not free.** Every round drops traffic for a real person in the
house. Read [[Findings are about a person]] in `detecting-client-tunnels` before
writing any of it down.

## The two sites

| | bongo | bingo |
|---|---|---|
| ssh | `bongo` | `humaid@10.10.0.18` (nebula only, slow first connect) |
| LAN | `10.20.0.0/16` | `192.168.50.0/24` |
| iface | `enp2s0` | `enp2s0` |
| resolver | blocky, `journalctl -u blocky` (no sudo) | same |

Both have NOPASSWD `tcpdump` and the `tempblock` CLI. Open **one**
ControlMaster per router before starting — see `detecting-client-tunnels`.

## Which lever for which finding

Three files, three different failure modes, and picking the wrong one is how a
finding ends up doing nothing:

| Finding | Goes in | Why that one |
|---|---|---|
| VPN / tunnel endpoints | `custom-throttle-list.txt` — **throttle** | A dropped node is replaced within a minute; a slow one is not, because nothing fails. Blocking these caused ~40 rotations across eight providers in one evening. Throttling produced none. |
| BIGO and its relays / control plane | `custom-ip-blocklist.txt` — **block by IP** | Reached by hardcoded address with no lookup, so a name block cannot touch it, and there is no reason to leave it half-working. |
| imo and its relays / control plane | `custom-imo-list.txt` — **throttle** | Also reached by hardcoded address, but blocking it outright drove the operator onto fresh infrastructure across eleven documented runs; throttling holds it on a slow node instead. See `sifr.router.imoThrottle`. |
| Gambling, adware, tracking, DNS-changers, everything else | `custom-blocklist.txt` — **wildcard host block** | Ordinary apps resolve these normally, so the name is the durable handle and costs no address collateral. Reach for an IP here only when the name is proven bypassed. |

The throttle numbers live in `sifr.router.throttle`. Add live with
`tempthrottle add`, drop live with `tempblock add` — both are cleared only by a
reboot, **not** by a rebuild, so flush deliberately.

## What counts as a node

The discriminator that has held every time: **a tunnel peer holds 70-100% of
one device's bytes; the same device browsing normally sits at 20-35%.** Volume
alone is not it — judge on share, and on the peer being rented space with no
resolver line behind it.

Never drop a peer just because it is dominant:

| Dominant peer | What it is | Action |
|---|---|---|
| Hosting AS — DigitalOcean, OVH, Hetzner, IONOS, Linode, AltusHost, leased "Private Customer" | A phone has no reason to talk to a rented VPS | Drop |
| CDN — Akamai, Google, Fastly, Cloudflare, Meta, Etisalat cache | Streaming or downloads | Leave |
| Residential or mobile carrier subscriber, flow attributable to imo | imo call media going P2P or via a relay | **Drop.** Blocking imo media, relays and control is authorised, and cutting the call is the intended effect |
| Residential or mobile carrier subscriber, anything else | A call on an app that is allowed — Botim relays especially are never to be blocked | **Leave.** Dropping it cuts someone's call |
| Hosting AS, but two LAN devices on paired ports of the same host | A cloud relay session with both legs on the LAN | **Leave.** See below |
| Off-subnet address that never replies | A stale collector, e.g. syslog | Leave |

**The relay trap.** A camera and the phone viewing it both sit at ~97% share on
one rented host with no resolver line, because the relay address is handed out
inside the vendor's protocol rather than looked up. Two LAN devices on the same
foreign host, on *paired* ports that roll together, is a relay session and not
two tunnels — Hik-Connect was seen doing exactly this on ports 6021/7021, then
6023/7023 when the relay moved. Identify it from the quiet device's DNS: a
camera queries one vendor name and nothing else. Blocking it takes out the
household's CCTV, and the failure looks nothing like a blocklist problem.

The carrier case is the one that bites: an encrypted P2P call is 100% of a
device's bytes to a single unexplained peer, and looks exactly like a tunnel
until you read the whois. Which app it belongs to decides the outcome, so
attribute it before acting — imo is fair game, the rest are not, and the wire
shape alone does not tell them apart. See `imo-signature-and-dns-bypass`.

**A call ends; a tunnel does not.** If a suspicious flow stops on its own while
the device stays up, it was a call. That is the cheapest attribution available
and it costs one more round.

**Attribute from the device's own DNS before dropping anything.** Cloud host,
arbitrary high port, opaque payload, no lookup for the peer, and a jump to a
fresh address when dropped — that describes a tunnel, a call relay, *and* a
live-streaming upload equally well. What separates them is what the handset was
resolving in the same window: `rtcpc-access-*.tiktokv.com` and
`*.byteglb.com` mean TikTok RTC, not a tunnel. Direction settles it too — a
call is roughly symmetric, a broadcast is upload-heavy, a tunnel carrying
browsing is download-heavy. Six addresses were blocked here on the relay-shape
alone and every one was TikTok LIVE.

**A CDN name in the whois does not mean CDN edge.** `172.235.0.0/16` and
`172.236.0.0/16` register as AKAMAI because Akamai bought Linode, but they are
rented compute and nodes have been found in both. Read the netname *and* the
service: edge addresses serve a matching SNI and have a resolver line behind
them; a VPS on an arbitrary port with neither is a node whoever owns the
range. The same caution applies to any hoster later acquired by a CDN.

## Running it

One round at a time. The script gathers; you decide.

```bash
.claude/skills/inspection-loop/inspection-loop.sh bingo 120   # one 2-min round
```

It prints a table — every client by bytes, its dominant peer, that peer's
share, port, whois, origin AS, any SNI, and whether the resolver explains the
address — then exits. Read it, decide what is a node, `tempblock add` or
`tempthrottle add` it per the table above, and append it to the matching file.
Report each round to the user as you go.

**The script must never block on its own, and no version of it should.** Both
failure modes have been seen in practice:

- *Blocking on absence of evidence.* A threshold-plus-whois-regex rule drops
  any dominant peer that fails to look like a CDN. "Not obviously innocent" is
  not evidence that something is a tunnel node.
- *Missing what carries across rounds.* One handset's node sat at 68%, then
  1 kB, then 40% over three consecutive rounds — under any per-round threshold
  — while its origin AS matched a node already blocked from a different site.
  That repetition is the whole signal, and only something with memory of the
  previous rounds can see it.

So the judgement that matters is cumulative: **watch the origin AS across
rounds, not the address within one.** Two nodes from one AS or one /24 means
the operator holds that range, and that is worth raising with the user — a
wider block is theirs to approve.

`tempblock` entries do not survive a rebuild. The blocklist file does, but only
after `nixos-rebuild` — so the file is the record and the tempblock is what is
actually stopping traffic right now.

## When to stop

- **The device gives up.** Top-peer share falls into the 20-35% band and the
  SNIs turn into ordinary services. That is the win condition, and it does
  happen — one handset stopped after nine rounds.
- **Nothing changes after several rounds.** The pool is deeper than your
  patience. Stop and say so rather than looping indefinitely; the honest
  finding is that address blocking does not converge on this app, and the
  remaining levers are a port block, a per-device egress policy, or accepting
  it.
- **Ranges start repeating.** Two addresses from one /24 means the operator
  holds that range. Say so and let the user choose — a /24 is theirs to
  approve, not yours to assume.

## Common mistakes

- **Blocking a call.** Check the whois for a carrier before dropping. See the
  table above.
- **Blocking CDN edge.** A shared address carries collateral for the whole
  house. Name-only for those.
- **Assuming the transport stays put.** This family moves between SSH on 22,
  raw UDP on a random high port, TLS to an SNI proxy, and cleartext HTTP with
  the payload in a Cookie header — sometimes mid-session. A port-based read
  will miss the next round.
- **Writing device names or byte totals into the repo.** The repo is public.
  The address and what it is are maintainable facts; who was using it is not.
