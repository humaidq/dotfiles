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

# Run one deletion and print how many entries went.
#
# conntrack -D writes the deleted entries to stdout and an "N flow entries have
# been deleted." summary to stderr, and exits 1 when N is zero. Zero is the
# normal answer for an idle peer, not a failure, so the status is swallowed and
# the count comes from the summary — which also means a caller sees "0" rather
# than a script that died under set -e.
#
# 2>&1 >/dev/null in that order: stderr goes to the capture, then stdout is
# discarded. Reversed, both would be discarded.
delete() {
	local output count
	output="$(ct -D "$@" 2>&1 >/dev/null)" || true
	count="$(printf '%s\n' "$output" |
		awk '/flow entries have been deleted/ { print $1; exit }')"
	printf '%s' "${count:-0}"
}

usage() {
	cat >&2 <<'USAGE'
killconn — tear down live connections to an address, without blocking it

  killconn <peer>                      kill every LAN client's flows with <peer>
  killconn <peer> from <lan-ip>        kill only that device's flows with <peer>

Changes no firewall state, so the app may reconnect at once. To stop it coming
back, use `tempblock add <peer>` — which calls this itself.
USAGE
	exit "${1:-0}"
}

case "${1:-}" in
-h | --help | help | "") usage 0 ;;
esac

peer="$1"
shift
validate "$peer"

from=""
if [ "$#" -gt 0 ]; then
	[ "$1" = "from" ] || die "unexpected argument: $1"
	shift
	[ "$#" -eq 1 ] || die "'from' takes exactly one address"
	from="$1"
	validate "$from"
fi

# Two deletions in either case, because conntrack's -s and -d filter the
# *original* tuple. A LAN-initiated NATed flow has original src=<lan>
# dst=<peer>; an inbound-initiated one has them the other way round. One call
# catches one of those, not both.
if [ -n "$from" ]; then
	a="$(delete -s "$from" -d "$peer")"
	b="$(delete -s "$peer" -d "$from")"
else
	a="$(delete -d "$peer")"
	b="$(delete -s "$peer")"
fi

total=$((a + b))
scope="$peer${from:+ from $from}"
if [ "$total" -eq 0 ]; then
	echo "no live flows: $scope"
else
	echo "killed $total flow(s): $scope"
fi
