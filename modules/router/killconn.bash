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
	delete -s "$from" -d "$peer"
	a="$deleted"
	delete -s "$peer" -d "$from"
	b="$deleted"
else
	delete -d "$peer"
	a="$deleted"
	delete -s "$peer"
	b="$deleted"
fi

total=$((a + b))
scope="$peer${from:+ from $from}"
if [ "$total" -eq 0 ]; then
	echo "no live flows: $scope"
else
	echo "killed $total flow(s): $scope"
fi
