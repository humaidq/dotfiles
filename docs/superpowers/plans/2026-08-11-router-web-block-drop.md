# Router block/drop Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the peers page's block button stop traffic in both directions and tear down the live connection; add a per-peer drop button that tears down the connection without blocking; and add a device-wide "drop all" button that ends every connection the device holds so its apps reconnect.

**Architecture:** A new `killconn` shell tool owns all conntrack interaction, in three forms — one peer, one peer scoped to a device, and a whole device. `tempblock` installs a drop rule per direction and calls `killconn` once its rules are in. `router-web` gains an action table driving four buttons, plus a status column that can see tempblock's rules and is invalidated when a button changes them.

**Tech Stack:** NixOS module (`modules/router/`), bash via `pkgs.writeShellApplication` (shellcheck runs at build time), Go 1.22+ `net/http` with `ServeMux` path patterns, `html/template`, nftables, conntrack-tools.

Design spec: `docs/superpowers/specs/2026-08-11-router-web-block-drop-design.md`.

## Global Constraints

- Format the tree with `nix fmt` before every commit. It runs nixfmt, deadnix, statix and shellcheck via treefmt.
- `nix flake check` is the real gate and must pass locally before pushing. CI only runs `nix flake show`.
- Commit with `git commit --no-gpg-sign`. The signing key is a hardware key that cannot be touched from an agent session.
- Default branch is `master`. Keep commit messages concise and descriptive.
- Go tests run from `modules/router/web/` with `go test ./...`. There is no Go toolchain assumption beyond what `buildGoModule` provides; if `go` is not on PATH, use `nix develop -c go test ./...` or `nix build .#nixosConfigurations.bongo.config.system.build.toplevel` to exercise the build.
- Bash scripts are `set -euo pipefail` and start with `PATH="/run/wrappers/bin:$PATH"` so the setuid sudo wrapper is reachable — `writeShellApplication` does not put it on the runtime PATH.
- Comments in this repo explain *why*, at length, and record what was tried and rejected. Match that density; do not write comments that restate the code.
- Do not add `output` or `input` hook chains, and do not use `reject`. Both were considered and declined in the spec.

---

## File Structure

| File | Responsibility |
|---|---|
| `modules/router/killconn.bash` | **New.** Delete live conntrack entries: for one peer, for one peer scoped to a device, or for a whole device. Touches no firewall state. |
| `modules/router/tempblock.bash` | Two drop rules per address (one per direction); aggregate `list`; call `killconn` after `add`. |
| `modules/router/tools.nix` | Package `killconn`; put it on `systemPackages`, on `router-web`'s systemd path, and on `tempblock`'s `runtimeInputs`. |
| `modules/router/web/shaping.go` | Read tempblock's chain so the status column sees it; `invalidate()` on the cache. |
| `modules/router/web/peers.go` | Action table replacing the hardcoded `add`; `POST /peers/{device}/drop` and `/drop-all`; a `logAction` that tolerates a peerless action. |
| `modules/router/web/peers.html` | Third per-row button, a device-wide button above the table, and two explanatory notes. |
| `modules/router/web/shaping_test.go` | Tests for the tempblock chain parser and the cache. |
| `modules/router/web/peers_test.go` | Tests for the drop route, argv construction and invalidation. |

No host files change: `hosts/bingo` and `hosts/bongo` already grant NOPASSWD `conntrack` in both path forms.

---

### Task 1: `killconn`

**Files:**
- Create: `modules/router/killconn.bash`
- Modify: `modules/router/tools.nix`

**Interfaces:**
- Consumes: nothing.
- Produces: a `killconn` executable on `PATH` with three forms:

  | Invocation | Kills |
  |---|---|
  | `killconn <peer>` | every LAN client's flows with that peer |
  | `killconn <peer> from <lan-ip>` | only that device's flows with that peer |
  | `killconn from <lan-ip>` | every flow that device has, any peer |

  Task 2 calls `killconn "$ip"`. Task 4 has `router-web` run `killconn <peer> from <device>` for the per-row drop button and `killconn from <device>` for the page-level "drop all" button. Exit status is 0 whenever the arguments parsed, including when zero flows matched; a conntrack that genuinely failed to run exits non-zero with its stderr surfaced.

- [ ] **Step 1: Write the script**

Create `modules/router/killconn.bash`:

```bash
#!/usr/bin/env bash
# killconn — tear down live connections to an address without blocking it.
#
# The counterpart to tempblock's firewall rules: this changes no persistent
# state at all. It deletes conntrack entries and stops, so the app is free to
# reconnect immediately. That is the point — "end this conversation now" is a
# different question from "stop this address being reachable", and the only
# lever that existed before was the second one.
#
# tempblock calls this after installing its rules, which is why the logic lives
# here rather than inline there: one owner for the tuple filters, the exit-code
# handling and the privilege decision below.
set -euo pipefail

# The setuid sudo wrapper is not on writeShellApplication's runtime PATH; add it
# so the non-root path below can find sudo.
PATH="/run/wrappers/bin:$PATH"

die() {
	echo "killconn: $*" >&2
	exit 1
}

# CAP_NET_ADMIN is capability bit 12. Deciding on the capability rather than on
# the uid is what makes this work for all three callers:
#
#   * root at a shell — has every capability, takes the direct path;
#   * the operator's unprivileged shell — has none, goes through the NOPASSWD
#     sudo rule the routers already grant for conntrack;
#   * router-web — a DynamicUser, so neither root nor able to sudo, but it
#     holds ambient CAP_NET_ADMIN and must take the direct path.
#
# A uid test would send that last one to sudo and fail every block from the web
# UI. Probing by running conntrack is no better: `conntrack -D` exits 1 both
# when it is not permitted and when it simply matched nothing, and a `-L` probe
# costs a full table walk on every invocation.
has_net_admin() {
	local effective
	effective="$(awk '/^CapEff:/ { print $2 }' /proc/self/status)"
	[ -n "$effective" ] && (( 0x$effective & (1 << 12) ))
}

if has_net_admin; then
	ct() { command conntrack "$@"; }
else
	ct() { sudo -n /run/current-system/sw/bin/conntrack "$@"; }
fi

# Same validation as tempblock: catch a typo with a friendly message rather
# than conntrack's.
validate() {
	case "$1" in
	*[!0-9a-fA-F:./]*) die "not an IP or CIDR: $1" ;;
	*[.:]*) : ;;
	*) die "not an IP or CIDR: $1" ;;
	esac
}

# Run one deletion and set `deleted` to how many entries went.
#
# A global rather than a value on stdout because this has to be able to abort
# the script on a real failure, and `die` inside a $(...) command substitution
# only kills the subshell.
#
# conntrack -D writes the deleted entries to stdout and a summary to stderr,
# and exits 1 when it deleted nothing. Zero is the normal answer for an idle
# peer, not a failure — but keying on the exit status alone would also swallow
# a genuine one, and an operator whose NOPASSWD grant had drifted would be told
# "no live flows" instead of "permission denied". So the summary line is what
# separates them: conntrack prints it whenever it actually ran, on both the
# zero and non-zero paths, and does not print it when it failed to run.
#
# The count is located by scanning for the words "flow entries" rather than by
# field position, because the summary carries a version banner —
# "conntrack v1.4.6 (conntrack-tools): 3 flow entries have been deleted." — so
# $1 is the string "conntrack", which would then feed the arithmetic below and
# abort the script under set -e on the *success* path.
#
# 2>&1 >/dev/null in that order: stderr goes to the capture, then stdout is
# discarded. Reversed, both would be discarded.
deleted=0
delete() {
	local output status count
	status=0
	output="$(ct -D "$@" 2>&1 >/dev/null)" || status=$?
	if [[ "$output" != *"flow entries have been deleted"* ]]; then
		die "conntrack -D failed: ${output:-exit status $status}"
	fi
	count="$(printf '%s\n' "$output" | awk '{
		for (i = 2; i <= NF; i++)
			if ($i == "flow" && $(i + 1) == "entries") { print $(i - 1); exit }
	}')"
	case "$count" in
	'' | *[!0-9]*) die "cannot read a count from conntrack: $output" ;;
	esac
	deleted="$count"
}

usage() {
	cat >&2 <<'USAGE'
killconn — tear down live connections, without blocking anything

  killconn <peer>                      kill every LAN client's flows with <peer>
  killconn <peer> from <lan-ip>        kill only that device's flows with <peer>
  killconn from <lan-ip>               kill every flow that device has

Changes no firewall state, so the app may reconnect at once. To stop it coming
back, use `tempblock add <peer>` — which calls this itself.
USAGE
	exit "${1:-0}"
}

case "${1:-}" in
-h | --help | help | "") usage 0 ;;
esac

# `from` in first position is the device-wide form: no peer at all, kill
# everything that device is holding. The other two forms lead with the peer, so
# one look at $1 separates them.
peer=""
from=""
if [ "$1" = "from" ]; then
	shift
	[ "$#" -eq 1 ] || die "'from' takes exactly one address"
	from="$1"
	validate "$from"
else
	peer="$1"
	shift
	validate "$peer"
	if [ "$#" -gt 0 ]; then
		[ "$1" = "from" ] || die "unexpected argument: $1"
		shift
		[ "$#" -eq 1 ] || die "'from' takes exactly one address"
		from="$1"
		validate "$from"
	fi
fi

# Two deletions in every case, because conntrack's -s and -d filter the
# *original* tuple. A LAN-initiated NATed flow has original src=<lan>
# dst=<peer>; an inbound-initiated one has them the other way round. One call
# catches one of those, not both.
if [ -z "$peer" ]; then
	delete -s "$from"
	a="$deleted"
	delete -d "$from"
	b="$deleted"
	scope="everything from $from"
elif [ -n "$from" ]; then
	delete -s "$from" -d "$peer"
	a="$deleted"
	delete -s "$peer" -d "$from"
	b="$deleted"
	scope="$peer from $from"
else
	delete -d "$peer"
	a="$deleted"
	delete -s "$peer"
	b="$deleted"
	scope="$peer"
fi

total=$((a + b))
if [ "$total" -eq 0 ]; then
	echo "no live flows: $scope"
else
	echo "killed $total flow(s): $scope"
fi
```

- [ ] **Step 2: Package it**

In `modules/router/tools.nix`, add a `killconn` binding to the `let` block, next to `tempblock`:

```nix
  killconn = pkgs.writeShellApplication {
    name = "killconn";
    runtimeInputs = with pkgs; [
      coreutils
      gawk
      conntrack-tools
    ];
    text = builtins.readFile ./killconn.bash;
  };
```

Add it to `environment.systemPackages`:

```nix
    environment.systemPackages = [
      clients
      killconn
      tempblock
      tempthrottle
    ];
```

and to `router-web`'s path, keeping the existing comment above it:

```nix
    systemd.services.router-web.path = [
      killconn
      tempblock
      tempthrottle
    ];
```

- [ ] **Step 3: Verify it builds and passes shellcheck**

Run: `nix build .#nixosConfigurations.bongo.config.system.build.toplevel`
Expected: builds. `writeShellApplication` runs shellcheck, so a quoting or SC2086 problem fails here rather than on the router.

If shellcheck objects to `(( 0x$effective & (1 << 12) ))` returning non-zero as the last statement of `has_net_admin`, note that the `[ -n ... ] && (( ... ))` form already guards it and the function is only ever used as an `if` condition — that is intended and is not an error to suppress.

- [ ] **Step 4: Format**

Run: `nix fmt`

- [ ] **Step 5: Commit**

```bash
git add modules/router/killconn.bash modules/router/tools.nix
git commit --no-gpg-sign -m "router: add killconn, which tears down live flows without blocking"
```

---

### Task 2: `tempblock` blocks both directions and kills the flows

**Files:**
- Modify: `modules/router/tempblock.bash`
- Modify: `modules/router/tools.nix`

**Interfaces:**
- Consumes: `killconn <peer>` from Task 1.
- Produces: two nftables rules per blocked address, both carrying the comment `tempblock:<ip>`. Task 3's Go parser reads exactly that comment format, so it must not change.

- [ ] **Step 1: Put `killconn` on tempblock's PATH**

In `modules/router/tools.nix`, change `tempblock`'s `runtimeInputs`. Note this drops the `with pkgs;` form — `killconn` is a `let` binding, and leaving it bare inside `with pkgs;` reads as though it came from nixpkgs:

```nix
  tempblock = pkgs.writeShellApplication {
    name = "tempblock";
    runtimeInputs = [
      killconn
      pkgs.coreutils
      pkgs.gawk
      pkgs.nftables
    ];
    text = builtins.readFile ./tempblock.bash;
  };
```

- [ ] **Step 2: Update the header comment**

In `modules/router/tempblock.bash`, replace the paragraph beginning "Each address is its own rule with its own counter" (currently lines 20-22) with:

```bash
# Each address gets two rules, one per direction, each with its own counter, so
# `list` shows not just which target is being hit but which way. The usual
# reason to set a temp block is to watch whether a just-blocked app keeps
# hammering the address, and "still trying" and "still receiving" are different
# answers: an address whose from-peer counter is stuck at zero while to-peer
# climbs is a working block against an app that has not given up.
#
# `add` also calls killconn, because a rule alone leaves the conversation
# already in the connection table running.
```

- [ ] **Step 3: Return every handle, not the first**

Replace `rule_handle` (currently lines 80-89) with:

```bash
# Print every rule handle for an address, one per line, or nothing if it is not
# blocked. index() rather than a regex match so the dots in an address are
# literal.
#
# Every, not the first: two rules carry each address now, and a function
# returning one handle would leave half of every block in place on del — the
# download direction surviving an "unblocked" message.
rule_handles() {
	nft -a list chain "$TABLE_FAMILY" "$TABLE_NAME" "$CHAIN" 2>/dev/null |
		awk -v needle="comment \"tempblock:$1\"" '
			index($0, needle) {
				for (i = 1; i <= NF; i++)
					if ($i == "handle") { print $(i + 1) }
			}'
}
```

- [ ] **Step 4: Add both rules, then kill the flows**

Replace the body of `cmd_add` (currently lines 91-109) with:

```bash
cmd_add() {
	[ "$#" -ge 1 ] || die "add needs at least one IP or CIDR"
	ensure
	for ip in "$@"; do
		validate "$ip"
		if [ -n "$(rule_handles "$ip")" ]; then
			echo "already blocked: $ip"
			continue
		fi
		fam="$(fam_of "$ip")"
		# One rule per direction rather than a combined match, for the reason
		# forward_throttle gives for doing the same thing: separate counters
		# show which way the traffic is actually flowing.
		#
		# saddr matters as much as daddr. With daddr alone the return stream
		# from the peer was still forwarded, so a download stalled only once TCP
		# gave up and a UDP media stream did not stop at all — a block that
		# looked applied and was half applied.
		#
		# The comment is passed with literal double quotes inside the argument.
		# nft joins its argv back into one string and re-lexes it, so the shell's
		# own quotes are long gone by then and a bare tempblock:1.2.3.4 makes its
		# parser stop at the colon ("unexpected colon"), so every add aborted on
		# the first address and no rule was ever installed.
		nft add rule "$TABLE_FAMILY" "$TABLE_NAME" "$CHAIN" \
			"$fam" daddr "$ip" counter drop comment "\"tempblock:$ip\""
		nft add rule "$TABLE_FAMILY" "$TABLE_NAME" "$CHAIN" \
			"$fam" saddr "$ip" counter drop comment "\"tempblock:$ip\""
		echo "blocked: $ip"
		# After the rules, never before. A packet in flight between a flush and
		# the rules landing recreates the conntrack entry, and the block then
		# looks broken to whoever is watching the peers page.
		killconn "$ip"
	done
}
```

- [ ] **Step 5: Delete every handle**

Replace the loop body in `cmd_del` (currently lines 117-125) with:

```bash
	for ip in "$@"; do
		handles="$(rule_handles "$ip")"
		if [ -z "$handles" ]; then
			echo "not blocked: $ip"
			continue
		fi
		while read -r handle; do
			nft delete rule "$TABLE_FAMILY" "$TABLE_NAME" "$CHAIN" handle "$handle"
		done <<<"$handles"
		echo "unblocked: $ip"
	done
```

`del` deliberately does not call `killconn`: removing a block is not a reason to tear down whatever talks to the address next. Neither does `flush`.

- [ ] **Step 6: Fold the pair into one line in `list`**

Replace `cmd_list` (currently lines 128-144) with:

```bash
# One line per address, not per rule. Two rules now carry each address, and a
# raw dump would list every target twice with no indication of which line was
# which direction.
cmd_list() {
	if ! table_exists; then
		echo "no temp blocks set"
		return 0
	fi
	nft -a list chain "$TABLE_FAMILY" "$TABLE_NAME" "$CHAIN" |
		awk '
			/tempblock:/ {
				ip = ""; dir = ""; pk = 0; by = 0
				for (i = 1; i <= NF; i++) {
					if ($i == "daddr")   { ip = $(i + 1); dir = "out" }
					if ($i == "saddr")   { ip = $(i + 1); dir = "in" }
					if ($i == "packets") pk = $(i + 1)
					if ($i == "bytes")   by = $(i + 1)
				}
				if (ip == "") next
				if (!(ip in seen)) { seen[ip] = 1; order[++n] = ip }
				if (dir == "out") { outpk[ip] = pk; outby[ip] = by }
				else              { inpk[ip] = pk;  inby[ip] = by }
			}
			END {
				for (i = 1; i <= n; i++) {
					ip = order[i]
					printf "  %-22s to-peer packets=%s bytes=%s   from-peer packets=%s bytes=%s\n",
						ip, outpk[ip] + 0, outby[ip] + 0, inpk[ip] + 0, inby[ip] + 0
				}
			}'
}
```

- [ ] **Step 7: Update the usage text**

In `usage()`, change the `add` line and add a closing note:

```bash
  tempblock add   <ip|cidr> [more...]   block both directions now, and kill
                                        any flows already open to it
```

and after the "Persistent blocks belong in..." line:

```bash
To end a conversation without blocking the address, use `killconn <ip>`.
```

- [ ] **Step 8: Verify it builds**

Run: `nix build .#nixosConfigurations.bongo.config.system.build.toplevel`
Expected: builds. Shellcheck runs here; `<<<"$handles"` and the `while read` loop avoid the SC2086 word-splitting warning an unquoted `for handle in $handles` would produce.

- [ ] **Step 9: Format and commit**

```bash
nix fmt
git add modules/router/tempblock.bash modules/router/tools.nix
git commit --no-gpg-sign -m "router: tempblock drops both directions and tears down live flows"
```

---

### Task 3: the status column can see tempblock

**Files:**
- Modify: `modules/router/web/shaping.go`
- Test: `modules/router/web/shaping_test.go`

**Interfaces:**
- Consumes: the `tempblock:<ip>` rule comment format from Task 2.
- Produces: `(*shapeIndex).addTempblockRules(raw []byte)`, `readTempblockChain(ctx context.Context) ([]byte, error)`, a `readTempblock func(context.Context) ([]byte, error)` field on `shapeCache`, and `(*shapeCache).invalidate()`. Task 4 calls `invalidate()`.

- [ ] **Step 1: Write the failing tests**

Append to `modules/router/web/shaping_test.go`:

```go
// ruleDoc builds the shape of `nft -j list chain inet router_tempblock block`.
func ruleDoc(comments ...string) []byte {
	parts := make([]string, 0, len(comments))
	for _, c := range comments {
		if c == "" {
			parts = append(parts, `{"rule":{"handle":1}}`)
			continue
		}
		parts = append(parts, `{"rule":{"handle":1,"comment":"`+c+`"}}`)
	}
	return []byte(`{"nftables":[` + strings.Join(parts, ",") + `]}`)
}

func TestTempblockRulesClassifyAsBlocked(t *testing.T) {
	index := parseShapingSets(nil)
	// tempblock writes two rules per address, one per direction, both carrying
	// the same comment. They must collapse to one entry.
	index.addTempblockRules(ruleDoc(
		"tempblock:203.0.113.50", "tempblock:203.0.113.50",
		"tempblock:2001:db8::9",
		"tempblock:198.51.100.0/24",
		"tempblock:not-an-address",
		"unrelated comment",
		"",
	))

	cases := []struct{ addr, want string }{
		{"203.0.113.50", shapeBlocked},
		{"2001:db8::9", shapeBlocked},
		{"198.51.100.7", shapeBlocked}, // inside the blocked prefix
		{"198.51.101.7", shapeNone},    // just outside it
		{"203.0.113.99", shapeNone},    // never blocked
	}
	for _, tc := range cases {
		t.Run(tc.addr, func(t *testing.T) {
			if got := index.classify(netip.MustParseAddr(tc.addr)); got != tc.want {
				t.Fatalf("classify(%s) = %q, want %q", tc.addr, got, tc.want)
			}
		})
	}
}

func TestTempblockRulesSurviveMalformedDocument(t *testing.T) {
	index := parseShapingSets(nil)
	index.addTempblockRules([]byte("not json"))
	if got := index.classify(netip.MustParseAddr("203.0.113.50")); got != shapeNone {
		t.Fatalf("classify = %q, want %q", got, shapeNone)
	}
}

func TestTempblockRulesOutrankAThrottle(t *testing.T) {
	// An address in throttle4 that is then temp-blocked must read as blocked:
	// that is what actually happens to its packets.
	index := parseShapingSets(map[string][]byte{"throttle4": setDoc(`"203.0.113.50"`)})
	index.addTempblockRules(ruleDoc("tempblock:203.0.113.50"))
	if got := index.classify(netip.MustParseAddr("203.0.113.50")); got != shapeBlocked {
		t.Fatalf("classify = %q, want %q", got, shapeBlocked)
	}
}

func TestShapeCacheFoldsInTempblock(t *testing.T) {
	cache := &shapeCache{
		ttl:  time.Hour,
		read: func(context.Context, string) ([]byte, error) { return nil, errors.New("absent") },
		readTempblock: func(context.Context) ([]byte, error) {
			return ruleDoc("tempblock:203.0.113.50"), nil
		},
	}
	if got := cache.get(context.Background()).classify(netip.MustParseAddr("203.0.113.50")); got != shapeBlocked {
		t.Fatalf("classify = %q, want %q", got, shapeBlocked)
	}
}

func TestShapeCacheSurvivesAbsentTempblockTable(t *testing.T) {
	// The common case: a router with no temp blocks set has no such table, and
	// nft exits non-zero. That must not cost the sets their entries.
	cache := &shapeCache{
		ttl: time.Hour,
		read: func(_ context.Context, set string) ([]byte, error) {
			if set == "throttle4" {
				return setDoc(`"203.0.113.10"`), nil
			}
			return nil, errors.New("absent")
		},
		readTempblock: func(context.Context) ([]byte, error) {
			return nil, errors.New("No such file or directory")
		},
	}
	if got := cache.get(context.Background()).classify(netip.MustParseAddr("203.0.113.10")); got != shapeThrottled {
		t.Fatalf("classify = %q, want %q", got, shapeThrottled)
	}
}

func TestShapeCacheInvalidateForcesAReread(t *testing.T) {
	calls := 0
	cache := &shapeCache{
		ttl: time.Hour,
		read: func(context.Context, string) ([]byte, error) {
			calls++
			return setDoc(`"203.0.113.10"`), nil
		},
	}
	cache.get(context.Background())
	first := calls
	cache.get(context.Background())
	if calls != first {
		t.Fatalf("cache re-read without being invalidated: %d then %d", first, calls)
	}
	cache.invalidate()
	cache.get(context.Background())
	if calls != first*2 {
		t.Fatalf("read %d times after invalidate, want %d", calls, first*2)
	}
}
```

Add `"strings"` to that file's import block.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd modules/router/web && go test ./... -run 'Tempblock|Invalidate|FoldsIn'`
Expected: FAIL — `index.addTempblockRules undefined`, `unknown field readTempblock`, `cache.invalidate undefined`.

- [ ] **Step 3: Implement**

In `modules/router/web/shaping.go`, add `"strings"` to the imports, then after the `shapingSets` var block add:

```go
// tempblock keeps its rules in a table of its own rather than in the sets
// above, so the sweep over shapingSets cannot see it and a peer blocked from
// the page's own button showed no status at all.
//
// That is worse than cosmetic. conntrack tracks at prerouting priority -200,
// well ahead of the block chain at -20, so a dropped packet still creates an
// entry: a blocked app that keeps retrying reappears on the peers page showing
// traffic out and nothing back. Without a badge that reads as a block that
// failed rather than one that is working.
const (
	tempblockTable         = "router_tempblock"
	tempblockChain         = "block"
	tempblockCommentPrefix = "tempblock:"
)

func readTempblockChain(ctx context.Context) ([]byte, error) {
	return exec.CommandContext(ctx, "nft", "-j", "list", "chain",
		"inet", tempblockTable, tempblockChain).Output()
}

// addTempblockRules folds the addresses tempblock is dropping into the index.
//
// The address comes from each rule's comment rather than from its match
// expression, which buys two things: the parser touches one field instead of
// walking nft's expression tree, and the two rules per address — one for each
// direction — carry the same comment and so collapse to one entry for free.
func (i *shapeIndex) addTempblockRules(raw []byte) {
	var doc struct {
		Nftables []struct {
			Rule *struct {
				Comment string `json:"comment"`
			} `json:"rule"`
		} `json:"nftables"`
	}
	if err := json.Unmarshal(raw, &doc); err != nil {
		return
	}
	for _, obj := range doc.Nftables {
		if obj.Rule == nil {
			continue
		}
		text, found := strings.CutPrefix(obj.Rule.Comment, tempblockCommentPrefix)
		if !found {
			continue
		}
		if addr, err := netip.ParseAddr(text); err == nil {
			addr = addr.Unmap()
			if shapeRank[shapeBlocked] > shapeRank[i.exact[addr]] {
				i.exact[addr] = shapeBlocked
			}
			continue
		}
		if prefix, err := netip.ParsePrefix(text); err == nil {
			i.prefixes = append(i.prefixes, shapePrefix{prefix.Masked(), shapeBlocked})
		}
	}
}
```

Add the field to `shapeCache`, after `read`:

```go
	// Read separately from the sets above because tempblock's state is rules in
	// another table, which is a different nft call rather than another set
	// name. Nil in tests that do not care.
	readTempblock func(ctx context.Context) ([]byte, error)
```

Set it in `newShapeCache`:

```go
func newShapeCache() *shapeCache {
	return &shapeCache{ttl: 30 * time.Second, read: readShapingSet, readTempblock: readTempblockChain}
}
```

In `get`, after `c.index = parseShapingSets(docs)`:

```go
	if c.readTempblock != nil {
		// A router with no temp blocks set has no such table and nft exits
		// non-zero. That is the common case, not an error worth losing the
		// sets over.
		if raw, err := c.readTempblock(ctx); err == nil {
			c.index.addTempblockRules(raw)
		}
	}
```

And add, next to `get`:

```go
// invalidate drops the cached index so the next read is current.
//
// Called after a button changes what the sets and rules say. Without it the
// page the action redirects to is served from an index up to a TTL old, so a
// peer that was just blocked can still render as untouched — which reads as
// the block having failed.
func (c *shapeCache) invalidate() {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.index = nil
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd modules/router/web && go test ./...`
Expected: PASS, including the pre-existing `TestShapeCacheReadsOncePerTTL` and `TestShapeCacheSurvivesUnreadableSets`, which construct a `shapeCache` without `readTempblock` and rely on the nil guard.

- [ ] **Step 5: Commit**

```bash
nix fmt
git add modules/router/web/shaping.go modules/router/web/shaping_test.go
git commit --no-gpg-sign -m "router-web: show temp-blocked peers in the status column"
```

---

### Task 4: the drop button

**Files:**
- Modify: `modules/router/web/peers.go:185-194` (`mux`), `modules/router/web/peers.go:279-323` (`handleAction`)
- Test: `modules/router/web/peers_test.go`

**Interfaces:**
- Consumes: `(*shapeCache).invalidate()` from Task 3; the `killconn <peer> from <lan-ip>` and `killconn from <lan-ip>` CLI forms from Task 1.
- Produces: `POST /peers/{device}/drop` and `POST /peers/{device}/drop-all`, and a `peerAction` struct with fields `name string`, `tool string`, `argv func(peer, device netip.Addr) []string`, `invalidate bool`, `peerless bool`. Task 5's template posts to both routes.

- [ ] **Step 1: Write the failing tests**

Append to `modules/router/web/peers_test.go`:

```go
func TestActionDropsPeerScopedToTheDevice(t *testing.T) {
	server := testPeersServer(t)
	var gotName string
	var gotArgs []string
	server.runTool = func(name string, args ...string) (string, error) {
		gotName, gotArgs = name, args
		return "killed 3 flow(s): 203.0.113.10 from 192.168.0.10", nil
	}

	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodPost, "/peers/192.168.0.10/drop",
		strings.NewReader("peer=203.0.113.10"))
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	server.mux().ServeHTTP(rec, req)

	if rec.Code != http.StatusSeeOther {
		t.Fatalf("status = %d, want 303", rec.Code)
	}
	want := []string{"203.0.113.10", "from", "192.168.0.10"}
	if gotName != "killconn" || !slices.Equal(gotArgs, want) {
		t.Fatalf("ran %s %v, want killconn %v", gotName, gotArgs, want)
	}
}

func TestActionDropRefusesNonPublicPeer(t *testing.T) {
	server := testPeersServer(t)
	called := false
	server.runTool = func(string, ...string) (string, error) { called = true; return "", nil }
	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodPost, "/peers/192.168.0.10/drop",
		strings.NewReader("peer=192.168.0.1"))
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	server.mux().ServeHTTP(rec, req)
	if rec.Code != http.StatusBadRequest {
		t.Fatalf("status = %d, want 400", rec.Code)
	}
	if called {
		t.Fatal("killconn was run against a non-public address")
	}
}

func TestActionDropRefusesCrossSiteRequest(t *testing.T) {
	server := testPeersServer(t)
	called := false
	server.runTool = func(string, ...string) (string, error) { called = true; return "", nil }
	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodPost, "/peers/192.168.0.10/drop",
		strings.NewReader("peer=203.0.113.10"))
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	req.Header.Set("Sec-Fetch-Site", "cross-site")
	server.mux().ServeHTTP(rec, req)
	if rec.Code != http.StatusForbidden {
		t.Fatalf("status = %d, want 403", rec.Code)
	}
	if called {
		t.Fatal("killconn was run for a cross-site POST")
	}
}

func TestActionDropsEveryFlowForTheDevice(t *testing.T) {
	server := testPeersServer(t)
	var gotName string
	var gotArgs []string
	server.runTool = func(name string, args ...string) (string, error) {
		gotName, gotArgs = name, args
		return "killed 12 flow(s): everything from 192.168.0.10", nil
	}

	rec := httptest.NewRecorder()
	// No peer field at all: this action is about the device.
	req := httptest.NewRequest(http.MethodPost, "/peers/192.168.0.10/drop-all", nil)
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	server.mux().ServeHTTP(rec, req)

	if rec.Code != http.StatusSeeOther {
		t.Fatalf("status = %d, want 303", rec.Code)
	}
	want := []string{"from", "192.168.0.10"}
	if gotName != "killconn" || !slices.Equal(gotArgs, want) {
		t.Fatalf("ran %s %v, want killconn %v", gotName, gotArgs, want)
	}
}

func TestActionDropAllIgnoresASubmittedPeer(t *testing.T) {
	// The route is device-wide by construction. A peer field posted to it — by
	// a stale form or by hand — must not narrow or redirect the action, or the
	// button would silently do something other than what it says.
	server := testPeersServer(t)
	var gotArgs []string
	server.runTool = func(_ string, args ...string) (string, error) {
		gotArgs = args
		return "", nil
	}
	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodPost, "/peers/192.168.0.10/drop-all",
		strings.NewReader("peer=203.0.113.10"))
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	server.mux().ServeHTTP(rec, req)
	if !slices.Equal(gotArgs, []string{"from", "192.168.0.10"}) {
		t.Fatalf("ran killconn %v, want [from 192.168.0.10]", gotArgs)
	}
}

func TestActionDropAllRefusesANonLANDevice(t *testing.T) {
	// The peer guard does not apply to this route, so the device guard is the
	// only thing standing between it and an arbitrary address.
	server := testPeersServer(t)
	called := false
	server.runTool = func(string, ...string) (string, error) { called = true; return "", nil }
	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodPost, "/peers/203.0.113.10/drop-all", nil)
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	server.mux().ServeHTTP(rec, req)
	if rec.Code != http.StatusNotFound {
		t.Fatalf("status = %d, want 404", rec.Code)
	}
	if called {
		t.Fatal("killconn was run against an address outside the LAN")
	}
}

func TestActionDropAllRefusesCrossSiteRequest(t *testing.T) {
	server := testPeersServer(t)
	called := false
	server.runTool = func(string, ...string) (string, error) { called = true; return "", nil }
	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodPost, "/peers/192.168.0.10/drop-all", nil)
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	req.Header.Set("Sec-Fetch-Site", "cross-site")
	server.mux().ServeHTTP(rec, req)
	if rec.Code != http.StatusForbidden {
		t.Fatalf("status = %d, want 403", rec.Code)
	}
	if called {
		t.Fatal("killconn was run for a cross-site POST")
	}
}

func TestActionDropAllLogsWithoutAPeer(t *testing.T) {
	var buf bytes.Buffer
	log.SetOutput(&buf)
	defer log.SetOutput(os.Stderr)

	server := testPeersServer(t)
	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodPost, "/peers/192.168.0.10/drop-all", nil)
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	server.mux().ServeHTTP(rec, req)

	line := buf.String()
	for _, want := range []string{`action=drop-all`, `peer="-"`, `device="192.168.0.10"`, `result="ok"`} {
		if !strings.Contains(line, want) {
			t.Fatalf("journal line is missing %s: %q", want, line)
		}
	}
	if strings.Contains(line, "invalid IP") {
		t.Fatalf("zero address leaked into the journal: %q", line)
	}
}

func TestActionInvalidatesTheShapeCacheOnlyWhenItChangedSomething(t *testing.T) {
	// killconn touches no firewall state, so invalidating for it would force a
	// needless re-read of feeds running to tens of thousands of elements.
	for _, tc := range []struct {
		path string
		want int
	}{
		{"/peers/192.168.0.10/block", 2},
		{"/peers/192.168.0.10/throttle", 2},
		{"/peers/192.168.0.10/drop", 1},
	} {
		t.Run(tc.path, func(t *testing.T) {
			reads := 0
			server := testPeersServer(t)
			server.shapes = &shapeCache{
				ttl: time.Hour,
				read: func(_ context.Context, set string) ([]byte, error) {
					if set == "throttle4" {
						reads++
					}
					return nil, errors.New("absent")
				},
			}
			// Prime the cache so the count below measures re-reads.
			server.shapes.get(context.Background())

			rec := httptest.NewRecorder()
			req := httptest.NewRequest(http.MethodPost, tc.path,
				strings.NewReader("peer=203.0.113.10"))
			req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
			server.mux().ServeHTTP(rec, req)
			if rec.Code != http.StatusSeeOther {
				t.Fatalf("status = %d, want 303", rec.Code)
			}

			server.shapes.get(context.Background())
			if reads != tc.want {
				t.Fatalf("throttle4 read %d times, want %d", reads, tc.want)
			}
		})
	}
}
```

Add `"slices"`, `"bytes"`, `"log"` and `"os"` to that file's import block if not already present — check first, since `TestActionLogsToJournal` already captures the log and may have brought some of them in. `context`, `errors`, `time`, `strings`, `net/http` and `net/http/httptest` are already imported.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd modules/router/web && go test ./... -run 'ActionDrop|ActionInvalidates'`
Expected: FAIL — the drop route 404s, so the status assertions fail.

- [ ] **Step 3: Implement the action table**

In `modules/router/web/peers.go`, replace `mux()` with:

```go
// peerAction is one button on the peers page. Kept as data rather than as three
// near-identical handlers so the CSRF check, the address guards and the journal
// line stay written once — a route that forgot one of them would be an
// unauthenticated firewall mutation.
type peerAction struct {
	// name labels the action in the journal.
	name string
	tool string
	// argv builds the command line. A function rather than a fixed prefix
	// because killconn takes the device as well as the peer, and the other two
	// would otherwise carry a parameter they never use.
	argv func(peer, device netip.Addr) []string
	// invalidate says whether this action changes what shaping.go reads.
	// killconn touches no firewall state, and invalidating for it would force a
	// re-read of feeds running to tens of thousands of elements — the cost the
	// cache exists to avoid.
	invalidate bool
	// peerless marks an action on the device as a whole. The peer form field is
	// not read and argv receives the zero Addr. The public-address guard is
	// skipped because there is no peer to guard — the {device} check is what
	// keeps the route from being pointed anywhere else.
	peerless bool
}

func addPeer(peer, _ netip.Addr) []string { return []string{"add", peer.String()} }

func (s *peersServer) mux() *http.ServeMux {
	mux := http.NewServeMux()
	if s.indexTmpl != nil {
		mux.HandleFunc("GET /{$}", s.handleIndex)
	}
	mux.HandleFunc("GET /peers/{device}", s.handlePage)
	mux.HandleFunc("POST /peers/{device}/throttle", s.handleAction(peerAction{
		name: "throttle", tool: "tempthrottle", argv: addPeer, invalidate: true,
	}))
	mux.HandleFunc("POST /peers/{device}/block", s.handleAction(peerAction{
		name: "block", tool: "tempblock", argv: addPeer, invalidate: true,
	}))
	// Scoped to the device whose page this was posted from: the row is that
	// device's connection, and cutting another device's flows to the same peer
	// is more than the button implies. The unscoped form stays available from
	// the CLI.
	mux.HandleFunc("POST /peers/{device}/drop", s.handleAction(peerAction{
		name: "drop", tool: "killconn",
		argv: func(peer, device netip.Addr) []string {
			return []string{peer.String(), "from", device.String()}
		},
	}))
	// The whole device at once. An app whose session survives one endpoint
	// dying does not survive its entire flow table going, which is what
	// "make it reconnect" actually takes.
	mux.HandleFunc("POST /peers/{device}/drop-all", s.handleAction(peerAction{
		name: "drop-all", tool: "killconn", peerless: true,
		argv: func(_, device netip.Addr) []string {
			return []string{"from", device.String()}
		},
	}))
	return mux
}
```

Then replace `handleAction` entirely. The guards are unchanged in substance — only the parts naming the tool and the action move — but here it is in full so it can be pasted over the existing function:

```go
// handleAction returns a handler that runs one of the router's tools against a
// peer.
func (s *peersServer) handleAction(action peerAction) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		// Browsers send Sec-Fetch-Site on every request; a cross-site form POST
		// carries "cross-site". Non-browser callers (curl over the mesh) send
		// no such header, so absence is allowed and only an explicit
		// cross-origin value is refused. This is the whole CSRF defence: the
		// endpoint is otherwise unauthenticated by design.
		if site := r.Header.Get("Sec-Fetch-Site"); site != "" && site != "same-origin" {
			http.Error(w, "cross-site request refused", http.StatusForbidden)
			return
		}

		device, ok := s.device(r)
		if !ok {
			http.NotFound(w, r)
			return
		}
		// A peerless action operates on the device as a whole, so there is no
		// form field to read and nothing for the address guard below to guard.
		// peer stays the zero Addr, which argv ignores and logAction renders
		// as "-".
		var peer netip.Addr
		if !action.peerless {
			parsed, err := netip.ParseAddr(r.PostFormValue("peer"))
			if err != nil {
				http.Error(w, "unparseable peer address", http.StatusBadRequest)
				return
			}
			peer = parsed.Unmap()
			if !isPublicAddr(peer) {
				// Refused before the tool is invoked: shaping the gateway or
				// another LAN device is hard to undo from the far side of it.
				// Applied to drop as well, where it is a weaker requirement —
				// killing a flow is recoverable in a way firewalling one is not
				// — because an inconsistent rule between adjacent buttons is
				// worse than a strict one.
				s.logAction(action.name, peer, device, "refused: not a public address")
				http.Error(w, "peer must be a public address", http.StatusBadRequest)
				return
			}
		}

		output, runErr := s.runTool(action.tool, action.argv(peer, device)...)
		result := "ok"
		if runErr != nil {
			result = fmt.Sprintf("error: %v: %s", runErr, output)
		}
		s.logAction(action.name, peer, device, result)

		if runErr != nil {
			http.Error(w, fmt.Sprintf("%s failed: %s", action.tool, output), http.StatusInternalServerError)
			return
		}
		// Before the redirect, or the page it lands on is served from an index
		// up to a TTL old and the peer still reads as untouched.
		if action.invalidate && s.shapes != nil {
			s.shapes.invalidate()
		}
		http.Redirect(w, r, "/peers/"+device.String(), http.StatusSeeOther)
	}
}
```

- [ ] **Step 4: Teach `logAction` about a peerless action**

`logAction` currently formats `peer` and looks its ASN up unconditionally. With a zero `netip.Addr` that prints `peer="invalid IP"` — a journal line that reads like a parse failure rather than a device-wide action. `(*ASNTable).Lookup` is safe on a zero address (it misses rather than panicking), so this is about the line being readable, not about a crash. Replace `logAction` with:

```go
// logAction writes the one line that makes blocks collectable later. The ASN,
// share-bearing device and outcome are included deliberately: an address on its
// own ages badly, and the reason is what is wanted months later.
func (s *peersServer) logAction(action string, peer, device netip.Addr, result string) {
	// A device-wide action has no peer. Rendered as "-" rather than left to
	// print the zero Addr's "invalid IP", which reads like a rejected request
	// in a log people grep months later.
	if !peer.IsValid() {
		log.Printf("peer-action action=%s peer=\"-\" device=%q result=%q", action, device, result)
		return
	}
	info, _ := s.asn.Lookup(peer)
	log.Printf("peer-action action=%s peer=%q asn=%d org=%q cc=%s device=%q result=%q",
		action, peer, info.Number, info.Org, info.Country, device, result)
}
```

- [ ] **Step 5: Run the full suite**

Run: `cd modules/router/web && go test ./...`
Expected: PASS. The existing `TestActionThrottlesPeer`, `TestActionBlocksPeer`, `TestActionLogsToJournal` and `TestActionRefusesZonedPeerAndLogsOneLine` must still pass unmodified — the argv for throttle and block is unchanged, and they all pass a valid peer so they take the unchanged `logAction` branch.

- [ ] **Step 6: Commit**

```bash
nix fmt
git add modules/router/web/peers.go modules/router/web/peers_test.go
git commit --no-gpg-sign -m "router-web: add drop and drop-all, which kill flows without blocking"
```

---

### Task 5: the button and the note

**Files:**
- Modify: `modules/router/web/peers.html`
- Test: `modules/router/web/peers_test.go`

**Interfaces:**
- Consumes: `POST /peers/{device}/drop` from Task 4.
- Produces: nothing later tasks depend on.

- [ ] **Step 1: Write the failing test**

Append to `modules/router/web/peers_test.go`:

```go
func TestRealTemplateRendersAllThreeActions(t *testing.T) {
	tmpl, err := template.ParseFiles("peers.html")
	if err != nil {
		t.Fatalf("parse peers.html: %v", err)
	}
	var out strings.Builder
	if err := tmpl.Execute(&out, peersPageData{
		Device: "192.168.0.10",
		Peers:  []peerRow{{Addr: "203.0.113.10", Bytes: "1 kB", SharePct: "100.0"}},
	}); err != nil {
		t.Fatalf("execute peers.html: %v", err)
	}
	body := out.String()
	for _, want := range []string{
		`action="/peers/192.168.0.10/drop"`,
		`action="/peers/192.168.0.10/throttle"`,
		`action="/peers/192.168.0.10/block"`,
		`action="/peers/192.168.0.10/drop-all"`,
	} {
		if !strings.Contains(body, want) {
			t.Fatalf("rendered page is missing %s\n%s", want, body)
		}
	}
	// Each per-row form carries the peer, or the button posts an empty address.
	// drop-all is not among them: it is device-wide and must not carry one.
	if got, want := strings.Count(body, `name="peer" value="203.0.113.10"`), 3; got != want {
		t.Fatalf("%d forms carry the peer address, want %d", got, want)
	}
}

func TestDropAllRendersWithNoPeers(t *testing.T) {
	// The button is the device's, not the table's. An idle device renders "No
	// current peers." and no table at all, and the button has to survive that —
	// a device with nothing listed is exactly when you want to reset it.
	tmpl, err := template.ParseFiles("peers.html")
	if err != nil {
		t.Fatalf("parse peers.html: %v", err)
	}
	var out strings.Builder
	if err := tmpl.Execute(&out, peersPageData{Device: "192.168.0.10"}); err != nil {
		t.Fatalf("execute peers.html: %v", err)
	}
	if !strings.Contains(out.String(), `action="/peers/192.168.0.10/drop-all"`) {
		t.Fatalf("drop-all button absent from an empty page:\n%s", out.String())
	}
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd modules/router/web && go test ./... -run RealTemplateRendersAllThree`
Expected: FAIL — `rendered page is missing action="/peers/192.168.0.10/drop"`.

- [ ] **Step 3: Add the button and the note**

In `modules/router/web/peers.html`, add a third form as the **first** of the three in the Actions cell — the order runs from least to most lasting:

```html
<td>
<form method="post" action="/peers/{{$.Device}}/drop" style="display:inline">
<input type="hidden" name="peer" value="{{.Addr}}">
<button type="submit">drop</button>
</form>
<form method="post" action="/peers/{{$.Device}}/throttle" style="display:inline">
<input type="hidden" name="peer" value="{{.Addr}}">
<button type="submit">throttle</button>
</form>
<form method="post" action="/peers/{{$.Device}}/block" style="display:inline">
<input type="hidden" name="peer" value="{{.Addr}}">
<button type="submit">block</button>
</form>
</td>
```

Add one note after the existing `<p class="note">` about the Traffic column:

```html
<p class="note"><strong>drop</strong> ends this device&rsquo;s current connections to the peer and nothing more &mdash; the app may reconnect at once. <strong>block</strong> also stops it coming back, in both directions, for every device, until the router reboots.</p>
```

Then add the device-wide button between that note block and the `{{if .Peers}}` that opens the table, so it renders whether or not there are peers to list — an idle device is exactly when you want to reset it. It goes **after** `{{if .Error}}...{{end}}` so an error notice stays directly under the notes:

```html
<form method="post" action="/peers/{{.Device}}/drop-all" style="margin: 0 0 1rem">
<button type="submit">drop all connections</button>
</form>
<p class="note">Ends every connection this device has, to every peer at once, and blocks nothing. Its apps reconnect from scratch.</p>
```

Note this form uses `{{.Device}}`, not `{{$.Device}}` — it sits outside the `{{range .Peers}}` loop, so the dot is already the page data. Inside the loop the dot is the row, which is why the per-row forms need `$`.

Add a style rule for it alongside the existing `button` rule, so it does not read as a third per-row button that has drifted out of the table:

```css
form.device button { background: #fff0f0; border: 1px solid #d33; color: #a00; font-weight: 600; }
```

and give the form that class: `<form class="device" method="post" ...>`.

- [ ] **Step 4: Run the full suite**

Run: `cd modules/router/web && go test ./...`
Expected: PASS. `TestRealTemplateRendersTrafficColumn` asserts every row has 9 `<td>`s; adding a form inside the existing Actions cell does not change that count, so it must still pass untouched.

- [ ] **Step 5: Commit**

```bash
nix fmt
git add modules/router/web/peers.html modules/router/web/peers_test.go
git commit --no-gpg-sign -m "router-web: drop button and a note on how it differs from block"
```

---

### Task 6: verify the whole thing

**Files:** none — verification only.

- [ ] **Step 1: Full flake check**

Run: `nix flake check`
Expected: passes. This builds every host, including both routers, and is the real gate.

- [ ] **Step 2: Deploy to a router**

Run on the router: `sudo nixos-rebuild switch --flake .#bongo`

Note that a rebuild does **not** clear `router_tempblock`: `networking.nftables.tables` manages named tables individually, so a table created by `tempblock` is invisible to it and survives. Run `tempblock list` first and `tempblock flush` if anything is left from an earlier session, or old single-direction rules will sit alongside the new pairs.

- [ ] **Step 3: Verify the block, against something live**

With a transfer running to a peer:

```bash
tempblock add <peer>
```

Expected: `blocked: <peer>` followed by `killed N flow(s): <peer>`. The transfer stops in both directions, and the peer leaves the connection table immediately (`conntrack -L -d <peer>` is empty).

- [ ] **Step 4: Verify the counters**

```bash
tempblock list
```

Expected: one line for the address. If the app is retrying, `to-peer` climbs while `from-peer` stays at zero — the shape of a working block.

- [ ] **Step 5: Verify the status column is immediate**

Load `http://<mesh-address>/peers/<device>` over the mesh. Expected: the blocked peer, if it reappears at all, shows the red `blocked` badge on the first render — not after a 30-second wait.

- [ ] **Step 6: Verify drop is scoped**

With two devices talking to the same peer:

```bash
killconn <peer> from <device-a>
```

Expected: `killed N flow(s)`. `conntrack -L -d <peer>` still shows device B's flows.

- [ ] **Step 7: Verify the empty case is not an error**

```bash
killconn <some-idle-peer>; echo "exit=$?"
```

Expected: `no live flows: <peer>` and `exit=0`.

- [ ] **Step 8: Verify unblock removes both rules**

```bash
tempblock del <peer> && tempblock list
```

Expected: `unblocked: <peer>`, and the address is gone from `list` — not left showing one direction.

- [ ] **Step 9: Verify drop-all from the CLI**

With a device holding several conversations:

```bash
conntrack -L -s <device> | wc -l   # before
killconn from <device>
conntrack -L -s <device> | wc -l   # after
```

Expected: `killed N flow(s): everything from <device>`, and the count drops to roughly zero. "Roughly" because the device reconnects immediately — that is the intended behaviour, not a failed kill.

- [ ] **Step 10: Verify both buttons from the web UI**

Click drop on a live row. Expected: 303 back to the peers page, the row's byte counts reset or the row is gone, and `journalctl -u router-web` carries one `peer-action action=drop ... result="ok"` line.

Then click "drop all connections" above the table. Expected: 303 back, the table comes back much shorter or empty, and the journal carries `peer-action action=drop-all peer="-" device="<device>" result="ok"` — with `peer="-"`, not `peer="invalid IP"`.

- [ ] **Step 11: Verify drop-all on an idle device**

Open the peers page for a device with no current peers. Expected: "No current peers." and the drop-all button still rendered. Click it: 303 back, `no live flows` in the journal's result, no error page.

---

## Notes for the implementer

**Do not change the `tempblock:<ip>` comment format.** Task 3's Go parser reads it, and Task 2's `rule_handles` matches on it with `index()`. A change to either without the other silently half-breaks `del`.

**`nft` and `conntrack` are not available on the development machine.** Everything kernel-side is verified in Task 6 on a router; the Go tests all run against fixtures.

**If a Go test needs the real `nft` JSON shape**, the two documents this code reads are:

```
$ nft -j list set inet router-blocklists throttle4
{"nftables":[{"set":{"name":"throttle4","elem":["203.0.113.10"]}}]}

$ nft -j list chain inet router_tempblock block
{"nftables":[{"rule":{"handle":4,"comment":"tempblock:203.0.113.10", ...}}]}
```

The real documents carry more fields (a `metainfo` object, `family`, `table`, `expr`); both parsers ignore everything they do not name, so the fixtures above are faithful for their purposes.
