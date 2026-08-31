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
	nft() { command nft "$@"; }
else
	ct() { sudo -n /run/current-system/sw/bin/conntrack "$@"; }
	nft() { sudo -n /run/current-system/sw/bin/nft "$@"; }
fi

# ip6 addresses are the ones with a colon, same test tempblock uses.
fam_of() {
	case "$1" in
	*:*) echo "ipv6" ;;
	*) echo "ipv4" ;;
	esac
}

# Every LAN address the device holding <addr> also holds, <addr> included.
#
# WHY THIS IS NEEDED AT ALL. A device has one DHCP lease and one or more SLAAC
# addresses, and conntrack filters match an address, not a machine. `killconn
# from <v4>` therefore swept exactly the IPv4 half of a dual-stack device and
# silently left every IPv6 flow running — the peers page's "drop all
# connections" button reporting success over a device that had not stopped
# talking. The page itself has always known better: render() folds a device's
# addresses together by MAC before it counts conversations, so the button was
# the only place the two views disagreed.
#
# Resolved here rather than passed in by router-web so that the CLI and the
# button behave identically, and so peers.go keeps handing this tool a single
# address exactly as it does today.
#
# Falls back to the address as given when the neighbour table has no MAC for
# it — a device that is merely asleep should still get the old behaviour
# rather than an error.
siblings() {
	local mac
	mac="$(ip neigh show 2>/dev/null | awk -v a="$1" '
		$1 == a { for (i = 1; i <= NF; i++) if ($i == "lladdr") { print $(i + 1); exit } }')"
	if [ -z "$mac" ]; then
		printf '%s\n' "$1"
		return 0
	fi
	{
		printf '%s\n' "$1"
		ip neigh show 2>/dev/null | awk -v m="$mac" '
			{
				lladdr = ""
				for (i = 1; i <= NF; i++) if ($i == "lladdr") lladdr = $(i + 1)
				if (lladdr == m) print $1
			}'
	} | awk '!seen[$0]++'
}

# Same validation as tempblock: catch a typo with a friendly message rather
# than conntrack's.
validate() {
	case "$1" in
	*[!0-9a-fA-F:./]*) die "not an IP or CIDR: $1" ;;
	*[.:]*) : ;;
	*) die "not an IP or CIDR: $1" ;;
	esac
}

# delete() reports its count through this global rather than on stdout.
# It used to be `count="$(delete ...)"`, but a `die` called from inside a
# command substitution only kills that subshell — the parent script would
# have sailed on with an empty string standing in for the count, and
# `total=$((a + b))` either explodes or, worse, quietly does the wrong
# arithmetic. Routing the result through a variable the caller reads after
# the call means `die` below actually stops the script.
deleted=0

# Run one deletion and set $deleted to how many entries went.
#
# conntrack's own summary line, written to stderr, looks like one of:
#
#   conntrack v1.4.6 (conntrack-tools): 3 flow entries have been deleted.
#   conntrack v1.4.6 (conntrack-tools): 0 flow entries have been deleted.
#
# and appears on BOTH of `-D`'s exit paths (0 when something matched, 1 when
# nothing did) — it's only missing when conntrack never got to report at
# all, e.g. sudo rejects the call or netlink returns EPERM. The count is not
# $1: the version banner shifts every field over, so field position is read
# relative to the fixed words "flow entries" instead, which survives a
# conntrack-tools version that rewords the banner around them.
#
# That gives two ways to read the outcome, and only one of them is a real
# failure:
#   * the summary is present            -> legitimate result, take the count
#     (this covers zero matched, which is the normal answer for an idle peer,
#     not a failure — a caller should see "0", not a script that died);
#   * the summary is absent             -> conntrack didn't run to
#     completion, so whatever text came back (a sudo password prompt, a
#     permission error) is a real fault, not a report, and gets surfaced
#     instead of silently counted as zero.
# Exit status alone can't stand in for this: it's 1 on the ordinary "nothing
# matched" case too, so treating "nonzero exit" as failure would turn every
# idle peer into a false alarm.
#
# 2>&1 >/dev/null in that order: stderr goes to the capture, then stdout is
# discarded. Reversed, both would be discarded.
delete() {
	local output status count
	status=0
	output="$(ct -D "$@" 2>&1 >/dev/null)" || status=$?

	if [[ "$output" == *"flow entries have been deleted"* ]]; then
		count="$(printf '%s\n' "$output" | awk '
			{
				for (i = 1; i <= NF; i++)
					if ($i == "flow" && $(i + 1) == "entries") { print $(i - 1); exit }
			}')"
		# Belt and braces: if the banner ever changes shape enough that the
		# positional read above misses, fail loudly rather than hand back a
		# non-numeric value that breaks the arithmetic at the call site.
		case "$count" in
		'' | *[!0-9]*) die "could not parse conntrack's summary: $output" ;;
		esac
		deleted="$count"
		return 0
	fi

	die "conntrack -D failed: ${output:-exit status $status}"
}

# --- resetting TCP before deleting the state entry --------------------------
#
# WHY THIS EXISTS. Deleting a conntrack entry tells neither endpoint anything.
# For UDP that is the whole story — there is no session to end, and the next
# packet simply builds a fresh entry. For TCP it is not: both sockets are still
# open, the next segment re-creates the state entry, and the conversation
# carries on across a "kill" that changed nothing anyone could observe. A flow
# was watched doing exactly that — same four-tuple, same client source port,
# no SYN and no handshake, traffic continuing straight through the deletion.
# "The app may reconnect at once" in the usage text quietly assumed a teardown
# that was never actually sent.
#
# So: reset what can be reset, and fall back to deletion for everything else.
# A RST reaches both sockets, so the app finds the connection genuinely gone
# and redials — which is what every caller of this tool wanted in the first
# place, and what the peers page's two buttons say they do.
#
# THIS IS NOT A BLOCK, and the design is what keeps it from becoming one:
#
#   * The match is the exact four-tuple of a flow that is open RIGHT NOW.
#     A redial draws a fresh source port, so nothing about the new connection
#     can match — the reset cannot outlive the conversation it ended.
#   * Elements carry a timeout and expire on their own. If this script is
#     killed between arming and returning, the ruleset heals itself. That is
#     deliberate: tempblock's header records 99 ad-hoc rules found still in
#     force long after they were meant to be gone, and a tool that runs from a
#     web button must not be able to add to that pile.
#   * SYN is excluded, so the redial's handshake is never what gets reset even
#     inside the timeout window.
#
# BOTH ORIENTATIONS ARE ARMED, so the reset reaches the peer as well as the
# client. In a forward hook the RST goes back toward the source of whatever
# packet matched, carrying the other end's address, so it takes one element per
# direction to close both sockets. The peer-bound half is the weaker of the two
# — behind a CDN it dies at the edge rather than reaching the origin holding
# the real socket — but a half-closed conversation is exactly the state this
# tool exists to avoid leaving behind.
#
# The chain sits at priority -30, ahead of tempblock's -20, so that
# `tempblock add` (which calls this) still gets a clean teardown instead of
# having its own drop rule swallow the packet the reset needed to match.
readonly RST_TABLE="router_killrst"

# Arm the reset for every TCP flow matching a conntrack filter. Takes the same
# -s/-d arguments as delete() so the two always cover the same set of flows.
#
# Best effort by design: a router whose ruleset predates this table, or any
# other reason nft refuses, must still get the deletion below. The old
# behaviour is the floor this sits on, never a thing it can take away.
armed=0
reset_flows() {
	local out elements fam set_name
	armed=0

	# -p tcp because a RST is the only teardown being offered here; UDP and
	# everything else fall through to delete() untouched.
	out="$(ct -L -p tcp "$@" 2>/dev/null)" || true
	[ -n "$out" ] || return 0

	for fam in ipv4 ipv6; do
		case "$fam" in
		ipv4) set_name="killrst4" ;;
		ipv6) set_name="killrst6" ;;
		esac

		# The FIRST src/dst/sport/dport on a line is the original tuple, which
		# for an ordinary LAN-initiated flow is exactly what the forward hook
		# sees: post-DNAT and pre-SNAT, so the client's own address, not the
		# router's public one. The reply tuple is deliberately NOT read — it
		# carries the WAN address and would never match a forwarded packet.
		# The reverse direction is built by swapping the original instead.
		elements="$(printf '%s\n' "$out" | awk -v want="$fam" '
			{
				src = ""; dst = ""; sport = ""; dport = ""
				for (i = 1; i <= NF; i++) {
					if (src   == "" && $i ~ /^src=/)   { sub(/^src=/,   "", $i); src   = $i }
					else if (dst   == "" && $i ~ /^dst=/)   { sub(/^dst=/,   "", $i); dst   = $i }
					else if (sport == "" && $i ~ /^sport=/) { sub(/^sport=/, "", $i); sport = $i }
					else if (dport == "" && $i ~ /^dport=/) { sub(/^dport=/, "", $i); dport = $i }
				}
				if (src == "" || dst == "" || sport == "" || dport == "") next
				# A colon in the address is the only family test needed, and it
				# avoids depending on conntrack -L printing a family column.
				is6 = (index(src, ":") > 0)
				if ((want == "ipv6") != is6) next
				printf "%s . %s . %s . %s, %s . %s . %s . %s, ", \
					src, sport, dst, dport, dst, dport, src, sport
			}')"
		elements="${elements%, }"
		[ -n "$elements" ] || continue

		if nft add element inet "$RST_TABLE" "$set_name" "{ $elements }" 2>/dev/null; then
			armed=1
		else
			echo "killconn: could not arm reset (${set_name}); deleting state only" >&2
		fi
	done
}

usage() {
	cat >&2 <<'USAGE'
killconn — tear down live connections, without blocking anything

  killconn <peer>                      kill every LAN client's flows with <peer>
  killconn <peer> from <lan-ip>        kill only that device's flows with <peer>
  killconn from <lan-ip>               kill every flow that device has

TCP flows are reset at both ends; anything else has its state entry deleted.
Either way the address stays reachable and the app is free to reconnect at
once — to stop it coming back, use `tempblock add <peer>`, which calls this
itself. A device address covers every address that device holds, both families.
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
# catches one of those, not both — for flows that originate on the LAN side,
# which is every ordinary outbound conversation.
#
# It is NOT complete coverage of every possible flow direction. A
# port-forwarded inbound connection is NATed the other way: its original
# tuple has dst=<router's public address>, not dst=<lan-ip>, so neither of
# these two calls (nor the peer-scoped pair above, nor the two in
# `killconn <peer>`) will match it — `-d <lan-ip>` and `-s <lan-ip>` are both
# blind to a flow whose original destination was never the LAN address in the
# first place. Catching that case would need a third call filtered on the
# router's own external address per forwarded port, which nothing here does.
# Believed harmless on these routers today because neither runs a port
# forward, but that is a fact about current configuration, not something this
# tool enforces or checks.
total=0
any_armed=0

# One conntrack filter, reset then deleted.
#
# Reset first and delete second, never the other way round: once the state
# entry is gone the flow's four-tuple has to be read from somewhere, and
# conntrack is the only place it was ever written down.
#
# `if` rather than `[ x ] && y` for the armed check — as the last statement of
# a function a failed test becomes the return status, and under `set -e` that
# ends the script on the ordinary "nothing was armed" path.
sweep() {
	reset_flows "$@"
	if [ "$armed" -eq 1 ]; then
		any_armed=1
	fi
	delete "$@"
	total=$((total + deleted))
}

# EVERY FILTER PAIRS LIKE WITH LIKE. conntrack refuses a call whose -s and -d
# are different families outright — "mismatched address family", which is what
# the peers page returned for any conversation over IPv6, because the peer came
# from the row and the device came from the URL and nothing checked that the
# two agreed. Selecting the device address in the peer's family fixes that
# case and the dual-stack sweep below at the same time.
if [ -n "$from" ]; then
	mapfile -t addrs < <(siblings "$from")
else
	addrs=()
fi

if [ -z "$peer" ]; then
	scope="everything from $from"
	for addr in "${addrs[@]}"; do
		sweep -s "$addr"
		sweep -d "$addr"
	done
elif [ -n "$from" ]; then
	scope="$peer from $from"
	peer_fam="$(fam_of "$peer")"
	matched=0
	for addr in "${addrs[@]}"; do
		[ "$(fam_of "$addr")" = "$peer_fam" ] || continue
		matched=1
		sweep -s "$addr" -d "$peer"
		sweep -s "$peer" -d "$addr"
	done
	if [ "$matched" -eq 0 ]; then
		die "$from holds no $peer_fam address, so it cannot have flows with $peer"
	fi
else
	scope="$peer"
	sweep -d "$peer"
	sweep -s "$peer"
fi

if [ "$total" -eq 0 ]; then
	echo "no live flows: $scope"
elif [ "$any_armed" -eq 1 ]; then
	echo "killed $total flow(s): $scope (TCP reset)"
else
	echo "killed $total flow(s): $scope"
fi
