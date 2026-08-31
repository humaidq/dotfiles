#!/usr/bin/env bash
# tempthrottle — add ad-hoc, non-persistent throttles on a router.
#
# The counterpart to tempblock, and temporary in the same sense: entries go into
# the throttle4/throttle6 sets in the router-blocklists table, which
# nft-blocklists-local flushes and repopulates from custom-throttle-list.txt on
# every rebuild. So a `nixos-rebuild switch` discards whatever was added here,
# and anything worth keeping belongs in that file.
#
# Unlike tempblock this adds set elements rather than rules, because the sets
# already exist and the marking rules that consume them are part of the ruleset.
# That means there is no per-address counter to show — hits are visible in
# aggregate on the forward_throttle chain, which `tempthrottle status` prints.
#
# What a throttled address gets is defined in qos.nix: a rate cap plus added
# latency, jitter and random loss, in both directions. The intent is a
# connection that works badly rather than one that fails, since a tunnel client
# that fails cleanly simply moves to another node.
set -euo pipefail

# The setuid sudo wrapper is not on writeShellApplication's runtime PATH; add it
# so the non-root path below can find sudo.
PATH="/run/wrappers/bin:$PATH"

readonly TABLE_FAMILY="inet"
readonly TABLE_NAME="router-blocklists"
readonly SET4="throttle4"
readonly SET6="throttle6"

# Same indirection as tempblock: direct when root, otherwise through the
# fully-qualified nft that the router's sudo rules whitelist NOPASSWD.
nft() {
	if [ "$(id -u)" -eq 0 ] || command nft list tables >/dev/null 2>&1; then
		command nft "$@"
	else
		sudo -n /run/current-system/sw/bin/nft "$@"
	fi
}

die() {
	echo "tempthrottle: $*" >&2
	exit 1
}

set_of() {
	case "$1" in
	*:*) echo "$SET6" ;;
	*) echo "$SET4" ;;
	esac
}

validate() {
	case "$1" in
	*[!0-9a-fA-F:./]*) die "not an IP or CIDR: $1" ;;
	*[.:]*) : ;;
	*) die "not an IP or CIDR: $1" ;;
	esac
}

# The sets are declared in the ruleset, so their absence means the router has
# not been rebuilt since the throttle was added — worth saying plainly rather
# than failing with nft's own message.
require_sets() {
	nft list set "$TABLE_FAMILY" "$TABLE_NAME" "$SET4" >/dev/null 2>&1 ||
		die "set $SET4 does not exist — rebuild the router first"
}

# Spend a pair's grace allowance up front, so the throttle marks the very next
# packet instead of letting graceBytes through at line rate first.
#
# WHY THIS EXISTS. The tier gives every device-and-peer pair an allowance before
# it engages, and that is deliberate — see the throttle_grace4 note in
# ip-blocklist.nix for the node-ranking argument it is there to defeat. But that
# argument is about an address a client is PROBING, not about a conversation an
# operator is watching. Throttling a peer that has been streaming for an hour
# and then watching it move another two megabytes at full speed reads as the
# button having failed, and it very nearly is: the allowance is the same size
# whether the pair is new or an hour old.
#
# So the allowance is skipped for the one pair named here and kept for every
# other. A client rotating to a fresh node still measures it fast, which is the
# whole point of the tier; the flow already on screen stops now.
#
# The element carries `used` equal to the allowance rather than above it —
# nftables rejects a used figure larger than its quota — which is exactly the
# state the rule's own `update` leaves behind on a pair that has spent it.
seed_spent_grace() {
	local peer="$1" device="$2" grace="$3" set
	# A CIDR has no place in a pair set, whose key is two exact addresses. Not
	# an error: throttling a whole range from the page is still a throttle, it
	# just cannot have its grace pre-spent.
	case "$peer" in
	*/*) return 1 ;;
	esac
	# The pair sets are per family, and a device page can list peers of both —
	# its URL address is IPv4 while a row beside it is IPv6. A mismatch is that
	# row, not a mistake, so it seeds nothing and says nothing.
	case "$peer" in
	*:*)
		case "$device" in
		*:*) set="throttle_grace6" ;;
		*) return 1 ;;
		esac
		;;
	*)
		case "$device" in
		*:*) return 1 ;;
		*) set="throttle_grace4" ;;
		esac
		;;
	esac
	# Delete first because `add` refuses an element that already exists, and the
	# one already there is the half-spent allowance being replaced.
	nft delete element "$TABLE_FAMILY" "$TABLE_NAME" "$set" "{ $device . $peer }" 2>/dev/null || true
	nft add element "$TABLE_FAMILY" "$TABLE_NAME" "$set" \
		"{ $device . $peer quota over $grace used $grace }" 2>/dev/null
}

cmd_add() {
	# `for <device>` names the LAN address whose conversation with these peers
	# should be throttled without waiting out the grace allowance. Optional, and
	# trailing: the peers page passes it, and the bare CLI form is unchanged.
	local device=""
	local -a targets=()
	while [ "$#" -gt 0 ]; do
		if [ "$1" = "for" ]; then
			[ "$#" -eq 2 ] || die "for takes exactly one device address"
			device="$2"
			validate "$device"
			break
		fi
		targets+=("$1")
		shift
	done

	[ "${#targets[@]}" -ge 1 ] || die "add needs at least one IP or CIDR"
	require_sets
	for ip in "${targets[@]}"; do
		validate "$ip"
		# Interval sets reject an element overlapping one already present, which
		# is how re-adding the same address surfaces. Treat that as success.
		if nft add element "$TABLE_FAMILY" "$TABLE_NAME" "$(set_of "$ip")" "{ $ip }" 2>/dev/null; then
			echo "throttled: $ip"
		else
			echo "already throttled (or overlapping an existing entry): $ip"
		fi
		# After the set add, not instead of it: the pair seed only decides when
		# the marking starts, and a failure to seed must not leave the address
		# unthrottled. Silent on failure for the same reason — the throttle is
		# in place either way, and the worst case is the allowance the tier
		# would have given anyway.
		if [ -n "$device" ]; then
			if seed_spent_grace "$ip" "$device" "$GRACE_BYTES"; then
				echo "  grace spent up front for $device"
			fi
		fi
	done
}

cmd_del() {
	[ "$#" -ge 1 ] || die "del needs at least one IP or CIDR"
	require_sets
	for ip in "$@"; do
		validate "$ip"
		if nft delete element "$TABLE_FAMILY" "$TABLE_NAME" "$(set_of "$ip")" "{ $ip }" 2>/dev/null; then
			echo "unthrottled: $ip"
		else
			echo "not throttled: $ip"
		fi
	done
}

cmd_list() {
	require_sets
	for s in "$SET4" "$SET6"; do
		echo "$s:"
		nft list set "$TABLE_FAMILY" "$TABLE_NAME" "$s" |
			awk '/elements = \{/,/\}/' |
			tr -d '{}' |
			sed 's/elements =//' |
			tr ',' '\n' |
			awk 'NF { print "  " $1 }'
	done
}

# Aggregate hit counters plus the live tc classes, which together answer "is
# anything actually being shaped" — the set having elements does not prove the
# marking or the qdisc are in place.
cmd_status() {
	echo "== marking counters (forward_throttle) =="
	nft list chain "$TABLE_FAMILY" "$TABLE_NAME" forward_throttle 2>/dev/null |
		awk '/comment "throttle/ { print "  " $0 }' || echo "  chain not present"
	echo "== throttled class on each shaped interface =="
	for dev in $(tc qdisc show 2>/dev/null | awk '$2 == "htb" { print $5 }' | sort -u); do
		echo "  $dev:"
		tc -s class show dev "$dev" classid 1:20 2>/dev/null | sed 's/^/    /'
	done
}

usage() {
	cat >&2 <<'USAGE'
tempthrottle — temporary, non-persistent IP throttles (cleared on the next rebuild)

  tempthrottle add  <ip|cidr> [more...] [for <device>]
                                         shape this address now; with `for`,
                                         spend that device's grace allowance up
                                         front so the cap bites immediately
  tempthrottle del  <ip|cidr> [more...]  stop shaping it
  tempthrottle list                      show throttled addresses
  tempthrottle status                    marking counters and the tc classes

Throttled traffic is rate capped in both directions and nothing else — no added
latency, jitter or loss, so the node still measures healthy to a client picking
between candidates. See sifr.router.throttle for the number. Persistent entries
belong in modules/router/custom-throttle-list.txt + a rebuild.
USAGE
	exit "${1:-0}"
}

sub="${1:-}"
shift || true
case "$sub" in
add) cmd_add "$@" ;;
del | rm) cmd_del "$@" ;;
list | ls) cmd_list ;;
status) cmd_status ;;
-h | --help | help | "") usage 0 ;;
*) usage 1 ;;
esac
