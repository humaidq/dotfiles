# Per-host imo policy: block on bongo, alternating on bingo

## Problem

`custom-imo-list.txt` is applied identically on both routers: every address in
it is marked 0x3 and steered into the 384kbit tc class, lossy on a time-of-day
schedule. That was the right answer when the alternative was an outright block
that kept losing to re-homing (see the throttle-tier work of 2026-08-08), but it
has two problems now.

The first is that the two sites want different things. bongo should refuse imo
outright, at all hours, with no negotiation. bingo should not — but it should
not be permanently open either.

The second is that shaping an address list does not reach an imo call that has
gone peer-to-peer. The estate carries the signalling and the relayed media, and
throttling it degrades those, but once two handsets have exchanged candidates
and are talking directly the packets never touch a listed address and the tc
class never sees them. A rate cap on the estate is therefore a cap on call
setup, not on calls.

## Policy

A new per-host option, `sifr.router.imoPolicy`:

| value | behaviour |
| --- | --- |
| `throttle` | today's behaviour: the estate is marked 0x3 and shaped. The module default, so a router that says nothing is unchanged. |
| `block` | the estate is dropped, every hour of every day. No shaping machinery is built at all. |
| `alternate` | odd day of month → `block`, even day → `throttle`. |

`bongo` sets `block`. `bingo` sets `alternate`.

Day-of-month parity rather than strict alternation from an epoch, chosen for
legibility: you can look at a calendar and know which mode the network is in.
The cost is accepted and documented — the 31st and the 1st are both odd, so
seven times a year there are two consecutive block days.

Only the IP tier alternates. imo's hostnames stay sinkholed in
`custom-blocklist.txt` and its tunnel ports stay dropped in
`custom-port-blocklist.txt`, on both hosts, on every day. That is deliberate
rather than an omission: those lists are global, the port list is shared with
the IPsec and Bright VPN entries, and imo reaches its backend from hardcoded
addresses regardless of what DNS answers — so unsinkholing the names on even
days would buy the app nothing it does not already have.

### Even-day throttle values

Flat 3% loss at 384kbit, all day. The `baseLoss` / `peakLoss` / `peakWindows`
schedule is removed rather than retuned: with bongo blocking outright and bingo
flat, no host was left that used it, and a half-hourly timer maintaining a value
nothing reads is machinery that only breaks. Git history holds it if the
call-window shape is ever wanted back.

## Mechanism

nftables has `meta day` (day of week) and `meta hour`, but nothing that
expresses day-of-month parity, so the flip needs a timer regardless. Given that,
the toggle is carried in set membership rather than in rules, which is how every
other list in this module already works — the feeds, `tempblock` and
`tempthrottle` all mutate sets and never rules.

- **Sets.** `imo_block4` / `imo_block6` join the existing `imo4` / `imo6`,
  generated from the same `custom-imo-list.txt` by the same build-time
  generator, differing only in target set names.
- **Rules.** Log and drop rules for the new sets sit in `forward_blocklists`
  next to the local and feed pairs, at priority -10, under the log prefix
  `nft-block-imo `. Because that chain runs before `forward_throttle` at
  priority 0, a block day needs no ordering games with the 0x3 marks: the packet
  is gone before the mark rules are reached. `daddr` only and forward hook only,
  matching `local_block4` — the router itself can still reach imo for
  diagnostics.
- **State.** Exactly one of the two pairs is populated at any time. Each state
  is a single generated `.nft` file that fills one pair and flushes the other,
  applied with one `nft -f` — a single transaction, so the estate is never in
  both pairs at once nor briefly in neither.
- **Decision.** `imo-policy-today` prints `block` or `throttle`, taking an
  optional day-of-month argument so the schedule can be interrogated for any
  date (`imo-policy-today 12`) instead of only for now. Same shape, and the same
  reason, as the `imo-loss-for` helper it replaces.
- **Application.** `imo-policy.service` runs the helper and applies the matching
  file.

### Surviving reboots and ruleset reloads

The policy is kernel state, re-derived rather than persisted, and there are
three ways it could be lost:

- **Boot.** The unit is `wantedBy = multi-user.target` and ordered after
  `nftables.service`, so it runs on every boot.
- **`nftables.service` restart**, which recreates the table with empty sets. The
  unit is `wantedBy` and `after` `nft-blocklists-local.service`, which is
  already `partOf nftables.service` — so a table reload restarts that unit,
  which pulls this one with it. Same wiring `imo-throttle-schedule` uses against
  `cake-sqm.service`.
- **Missed midnight**, on a router that was off. The timer is
  `OnCalendar = *-*-* 00:00:00` with `Persistent = true`, so a missed firing
  runs at boot.

`RemainAfterExit` is deliberately false: systemd treats `start` on an
already-active oneshot as a no-op, so leaving it active would silently stop the
timer from ever re-running it — the failure mode `nft-blocklists-update` is
commented against in the same file.

Both routers run `Asia/Dubai` (from `personal.base`), and systemd `OnCalendar`
and `date +%d` are both local time, so the flip is local midnight. A call in
progress at 23:59 on an even day dies at 00:00.

`nft -f ${imoList}` moves out of `nft-blocklists-local.service` into this unit,
so each set has exactly one writer.

## Consequences elsewhere

- **qos.nix.** The `1:30` class, its netem qdisc and the `handle 0x3 fw` filter
  are built only when `imoPolicy != "block"`, as are the four imo mark rules in
  `forward_throttle`. bongo builds no imo shaping at all. `imo-loss-for`,
  `imo-throttle-schedule.service` and its half-hourly timer are deleted.
- **router-web.** `imo_block4` / `imo_block6` join `shapingSets` as
  `shapeBlocked`. Without this a bingo peer on an odd day would read "imo tier"
  on the peers page while its packets were being dropped.
- **qos-metrics.** No change needed. `collect_classes` skips a `1:30` that is
  not there and `collect_rules` reports whatever rules exist, so bongo simply
  publishes fewer series.

## Testing

- `nix flake check` builds both routers.
- `go test ./...` in `modules/router/web`, with a case covering an address in
  `imo_block4` reporting `blocked` rather than `imo`.
- `imo-policy-today 11` → `block`, `imo-policy-today 12` → `throttle` on bingo;
  both → `block` on bongo.
