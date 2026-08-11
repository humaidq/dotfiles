# Blocking that actually blocks, and a drop button

Status: implemented. Built across `3531b82..b299ffc`.

## Why

The peers page has a block button. It runs `tempblock add <peer>`, which
installs exactly one rule:

```
ip daddr <peer> counter drop
```

in `inet router_tempblock`, chain `block`, forward hook priority -20. That is
half a block, applied to a connection nothing tears down, reported nowhere.
Four separate gaps, all of which show up the moment the button is used against
something live:

1. **Return traffic still flows.** Only `daddr` is matched, so packets *from*
   the peer back to the device are forwarded normally. A download or a call in
   progress keeps receiving. The upload side dies, which is enough to make a
   TCP transfer stall eventually, and not enough to stop a UDP media stream at
   all.
2. **Existing flows survive.** Nothing removes the conntrack entries, so the
   conversation stays in the connection table and on the page, byte counts
   climbing, long after the rule is in.
3. **Nothing reflects it.** `shaping.go` builds its status column from sets in
   `router-blocklists`. `tempblock` writes rules in a table of its own, so a
   just-blocked peer shows `—` in the Status column — indistinguishable from
   one nobody has touched. `tempthrottle` does not have this problem: it adds
   to the shared `throttle4`/`throttle6` sets, which `shaping.go` already
   reads.
4. **There is no way to just cut a connection.** The only lever is a
   persistent-until-reboot firewall rule. Ending one conversation without
   committing to blocking the address is not expressible.

## Scope

Both routers, both interfaces. `tempblock` is the shared implementation, so
fixing it fixes the CLI and the button together; the drop button needs a new
tool, which gets the same treatment.

Out of scope: the router's own traffic to a blocked peer, and rejecting rather
than dropping. Both were considered and declined — see "Decisions taken"
below.

## Architecture

Three units, each with one job:

| Unit | Job |
|---|---|
| `killconn` | Remove live conntrack entries for an address. Touches no firewall state. |
| `tempblock` | Install and remove the drop rules. Calls `killconn` once the rules are in. |
| `router-web` | Present the buttons (throttle, block, drop, drop all); run one of the tools; report what happened. |

`killconn` exists as its own tool rather than as a `tempblock` subcommand for
two reasons. It is genuinely a different operation — it changes nothing
persistent, so it belongs to neither "block" nor "throttle" — and making it the
single owner of conntrack interaction means the sudo indirection, the exit-code
handling and the tuple filters are written once. `tempblock add` becomes a
caller.

Naming: not `tempblock kill`, which reads like "remove the block" and would be
a live footgun on a router.

### `killconn`

```
killconn <peer>                 every LAN client's flows with that peer
killconn <peer> from <lan-ip>   only that device's flows with that peer
killconn from <lan-ip>          every flow that device has, any peer
```

```
# killconn 185.60.216.35
conntrack -D -d 185.60.216.35
conntrack -D -s 185.60.216.35

# killconn 185.60.216.35 from 10.20.1.42
conntrack -D -s 10.20.1.42 -d 185.60.216.35
conntrack -D -s 185.60.216.35 -d 10.20.1.42

# killconn from 10.20.1.42
conntrack -D -s 10.20.1.42
conntrack -D -d 10.20.1.42
```

The third form is what the page's "drop all" button runs. It is the same
operation as the second widened to every peer at once: an app whose session
survives one endpoint dying gets no such luck when the whole device's table
goes, which is what "make it reconnect" actually requires.

Two calls in each case because `conntrack`'s `-s`/`-d` filter the **original**
tuple. A LAN-initiated, NATed flow has original `src=<lan> dst=<peer>`; an
inbound-initiated one has them the other way round. One call catches one of
those, not both.

`conntrack -D` exits 1 when it matched nothing. Each call is therefore
guarded — unguarded, `set -e` turns "there was nothing to kill" into a script
failure, which is the *normal* outcome for an idle peer and would surface in
the web UI as a red error. Deleting zero entries is a success and is reported
as such. The number deleted is echoed, because "killed 4 flows" and "killed 0
flows" are the two answers worth having and they look identical otherwise.

Root/sudo indirection follows `nft()` in `tempblock.bash` — run directly when
that works, otherwise `sudo -n` the fully-qualified binary that both routers
already whitelist NOPASSWD — but it cannot use the same probe. `nft()` decides
by running a harmless `nft list tables`; the equivalent for conntrack is a
`-D` whose exit code cannot distinguish "not permitted" from "nothing matched",
and a full `-L` dump costs a table walk per invocation. A uid test will not do
either: `router-web` is a `DynamicUser`, so it is neither root nor able to
sudo, yet it holds ambient `CAP_NET_ADMIN` and must take the direct path.

So the decision is made by testing CAP_NET_ADMIN — bit 12 of `CapEff` in
`/proc/self/status`. That is true for root as well, so it is one predicate
covering all three callers: root at a shell, the operator's unprivileged
shell, and `router-web`.

Address validation reuses `tempblock`'s `validate` — a friendly message on a
typo beats conntrack's.

### `tempblock`: two rules per address

`cmd_add` installs both directions, carrying the same comment:

```
ip daddr <ip> counter drop comment "tempblock:<ip>"   # device -> peer
ip saddr <ip> counter drop comment "tempblock:<ip>"   # peer -> device
```

One rule per direction rather than a combined match, for the reason
`forward_throttle` already gives for doing the same thing: separate counters
show which way the traffic is actually flowing. Watching a just-blocked app
hammer an address is the usual reason to set a temp block at all, and a single
merged counter would not distinguish "still trying" from "still receiving".

The shared comment means `rule_handle` must become `rule_handles`, returning
every matching handle rather than the first. `cmd_del` deletes each; `cmd_add`
treats any existing handle as already-blocked.

`cmd_list` folds the pair back into one line per address:

```
  185.60.216.35        to-peer packets=142 bytes=9012   from-peer packets=0 bytes=0
```

An address whose `from-peer` counter is stuck at zero while `to-peer` climbs is
a working block against an app that has not given up — which is exactly the
question `list` is opened to answer.

Then, and only then, `cmd_add` calls `killconn <ip>` — unscoped, matching the
rule's own scope, since the rules block every LAN client.

**Ordering is load-bearing.** Rules first, `killconn` second. Reversed, a
packet in flight recreates the conntrack entry between the flush and the rule
landing, and the block looks broken to whoever is watching the page.

`del` and `flush` do not call `killconn`. Removing a block is not a reason to
tear down whatever is talking to the address afterwards.

### `router-web`: an action table

`handleAction(action, tool string)` hardcodes `add` as the subcommand, which
does not fit `killconn`. It is replaced by a table, so the CSRF check, the LAN
membership check, the public-address guard and the journal line all stay
written once:

| Button | Tool | argv | Peer | Invalidates cache |
|---|---|---|---|---|
| throttle | `tempthrottle` | `add <peer>` | required | yes |
| block | `tempblock` | `add <peer>` | required | yes |
| drop | `killconn` | `<peer> from <device>` | required | no |
| drop all | `killconn` | `from <device>` | none | no |

argv is built by a per-action function taking `(peer, device netip.Addr)`, so
an action that needs the device address can have it without the others
carrying an unused parameter.

The per-row actions keep the `isPublicAddr` guard. It is a weaker requirement
for drop — killing a flow to the gateway is recoverable in a way that
firewalling it is not — but the guard costs nothing and an inconsistent rule
between three adjacent buttons is worse than a strict one.

"Drop all" is the one action with no peer at all, so it carries a `peerless`
flag: the form field is not read, the address guard has nothing to guard, and
`argv` receives the zero `netip.Addr`. `logAction` prints `peer="-"` and skips
the ASN lookup rather than emitting a journal line claiming an invalid
address. The device guard still applies — the `{device}` must be a LAN
address, which is what stops the route being pointed at anything else.

Routes: `POST /peers/{device}/drop` and `POST /peers/{device}/drop-all`.

No confirmation dialog, matching the per-row buttons. Nothing here is
destructive in a lasting way: the flows re-establish, which is the point of
the button.

### `router-web`: a status column that is true and current

Two independent problems, both visible on the same column.

**`shaping.go` cannot see tempblock.** It reads named sets in
`router-blocklists`; tempblock's state is rules in `router_tempblock`. Fix: a
second reader on `shapeCache`, running

```
nft -j list chain inet router_tempblock block
```

and taking the addresses out of the rules' `tempblock:<ip>` comments, folded in
as `shapeBlocked`. Reading comments rather than decoding the match expressions
keeps the parser to one field and makes the two rules per address collapse to
one entry for free. A missing table is skipped silently, exactly as a missing
set already is — a router with no temp blocks set is the common case, not an
error.

This matters more than a cosmetic badge. A packet dropped in the forward hook
has *already* been tracked: conntrack runs at prerouting priority -200, well
ahead of the -20 block chain. So a blocked app that keeps retrying keeps
creating entries and **reappears on the peers page**, showing traffic out and
nothing back. Without the badge that reads as a block that failed. With it, it
reads as a block that is working and an app that has not noticed.

**The cache is up to 30 seconds stale**, so a fresh block can be invisible on
the page it redirects to. Invalidate after throttle and block. Not after drop:
it changes nothing `shaping.go` reads, and the invalidation forces a re-read of
feeds running to tens of thousands of elements — which is the cost the cache
exists to avoid.

### Page copy

`peers.html` gains the third per-row button and one line separating it from
block, in the style of the notes already there: drop cuts what is open now and
the app is free to reconnect; block also stops it coming back.

Above the table, before any peer is listed, a "drop all" button for the device
as a whole. It sits there rather than in the header row because it is not a
column operation — it applies to everything below it at once, and a button
inside the table would read as belonging to whichever row it landed next to.

## Decisions taken

**Drop, not reject.** Considered: `reject with tcp reset` for TCP and ICMP
admin-prohibited otherwise, so sockets fail instantly instead of hanging.
Declined. A reset tells the app it has been blocked, and an app that rotates
endpoints — which is the whole reason these buttons exist — treats a clean
failure as a signal to try the next node immediately. Silent drop plus a
conntrack flush stops the traffic just as completely and gives it nothing to
act on. It also keeps `tempblock` consistent with every other block chain in
the ruleset.

**Forward hook only.** Considered: adding `output` and `input` chains so the
router itself is cut off too, as `custom-ip-blocklist.txt` does for permanent
entries. Declined, for the reason `forward_blocklists` already records against
the imo sets — the router's own path stays open so a blocked address remains
reachable for diagnostics. Being able to ping, curl and capture an address you
have just blocked is how you confirm the block bit.

**Drop scoped to one device, block global.** The block installs a rule that
applies to every LAN client, so its flush is global to match. Drop is invoked
from a page titled for one device, on a row that is that device's connection,
so it kills that pair and leaves other devices alone. The CLI's unscoped form
remains available for the times the wider hammer is wanted.

## Testing

Go, in the existing table-driven style:

- `shaping_test.go` — tempblock chain parsing: IPv4, IPv6, CIDR comments, a
  malformed comment, a rule with no comment, an absent table, and the two rules
  per address collapsing to one entry.
- `peers_test.go` — the drop route builds `<peer> from <device>`; the cache is
  invalidated for block and throttle and not for drop; drop refuses a
  non-public peer; drop refuses a cross-site POST.

Bash: no test harness exists for `tempblock.bash` or `tempthrottle.bash` and
this change does not add one. `killconn` and the changed `tempblock` are
covered by `nix flake check` building them — `writeShellApplication` runs
shellcheck — and by running both on a router against a live peer.

Manual verification on a router, which is the only place the kernel side can be
checked:

1. `tempblock add <peer>` with a transfer running — the transfer stops in both
   directions, and the peer leaves the connection table at once.
2. `tempblock list` — `from-peer` stays at zero while `to-peer` climbs.
3. The peers page shows `blocked` on the next render, not 30 seconds later.
4. `killconn <peer> from <device>` — that device's flows go, another device's
   flows to the same peer stay.
5. `killconn` against an idle peer — reports zero, exits zero.
6. `tempblock del <peer>` — both rules go; `tempblock list` shows the address
   gone.

## Files

- `modules/router/killconn.bash` — new.
- `modules/router/tempblock.bash` — two rules per address, `rule_handles`,
  aggregated `list`, `killconn` call.
- `modules/router/tools.nix` — `killconn` package; on `systemPackages`, on
  `router-web`'s systemd path, and on `tempblock`'s `runtimeInputs`.
- No host changes. `hosts/bingo` and `hosts/bongo` already grant NOPASSWD
  `conntrack` in both path forms, added for the peers page's own use of the
  flow table. `router-web` needs no sudo at all: it already has
  `conntrack-tools` on its path and ambient `CAP_NET_ADMIN`.
- `modules/router/web/shaping.go` — tempblock chain reader, `invalidate`.
- `modules/router/web/peers.go` — action table, drop route.
- `modules/router/web/peers.html` — third button, one note.
- `modules/router/web/shaping_test.go`, `modules/router/web/peers_test.go`.
