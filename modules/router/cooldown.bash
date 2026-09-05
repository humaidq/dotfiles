#!/usr/bin/env bash
# cooldown — take one LAN device off the internet for a fixed period.
#
# The device stays associated to its access point, keeps its DHCP lease, keeps
# resolving names through this router, and keeps answering its own
# captive-portal probe. Everything else it sends or receives through the WAN is
# dropped. See modules/router/cooldown.nix for the chain, and for what the
# captive-portal carve-out costs.
#
# THE DEADLINE IS THE nftables ELEMENT TIMEOUT, not a timer, not a state file
# and not an at(1) job. That is the whole reason this is short: nothing has to
# survive in order to lift the cooldown, because there is nothing to lift — the
# element deletes itself. A router that reboots or reloads its ruleset
# mid-cooldown releases the device, which is the direction this should fail in.
#
# A device is a MAC, and the MAC is what the drop is really keyed on: an IPv4
# address comes from a lease, but a phone's IPv6 addresses are formed by the
# phone, there are usually several, and it may form another one ten minutes into
# the cooldown. The address sets exist for the return direction, where the
# device's MAC is not on the packet, and for a device the neighbour table has
# forgotten.
set -euo pipefail

# The setuid sudo wrapper is not on writeShellApplication's runtime PATH; add it
# so the non-root path below can find sudo.
PATH="/run/wrappers/bin:$PATH"

# Two words on purpose — "inet router-cooldown" — so every nft invocation below
# passes it UNQUOTED and lets the shell split it. Same idiom lowtrust.bash uses
# for its table list, down to the SC2086 exemption each such call carries.
readonly TABLE="inet router-cooldown"
readonly MAC_SET="cooldown_macs"
readonly SET4="cooldown4"
readonly SET6="cooldown6"
readonly ALLOW4="cooldown_allow4"
readonly ALLOW6="cooldown_allow6"

# All set by cooldown.nix. The defaults are only for running this by hand on a
# router that predates that wiring.
LEASE_FILE="${LEASE_FILE:-/var/lib/dnsmasq/dnsmasq.leases}"
LAN_INTERFACE="${LAN_INTERFACE:-}"
ALLOW_DOMAINS="${COOLDOWN_ALLOW_DOMAINS:-}"
MAX_SECONDS="${COOLDOWN_MAX_SECONDS:-86400}"
readonly LEASE_FILE LAN_INTERFACE ALLOW_DOMAINS MAX_SECONDS

# When already root, or holding CAP_NET_ADMIN as router-web does, run nft
# directly; otherwise go through the NOPASSWD sudo rule the routers grant for
# the fully-qualified path. Same wrapper as tempblock and lowtrust — see
# killconn.bash for why router-web cannot take the sudo path.
nft() {
	if [ "$(id -u)" -eq 0 ] || command nft list tables >/dev/null 2>&1; then
		command nft "$@"
	else
		sudo -n /run/current-system/sw/bin/nft "$@"
	fi
}

die() {
	echo "cooldown: $*" >&2
	exit 1
}

is_mac() {
	printf '%s' "$1" | grep -qiE '^([0-9a-f]{2}:){5}[0-9a-f]{2}$'
}

neigh() {
	if [ -n "$LAN_INTERFACE" ]; then
		ip neigh show dev "$LAN_INTERFACE" 2>/dev/null
	else
		ip neigh show 2>/dev/null
	fi
}

# Address to MAC, via the neighbour table and then the lease file. Copied in
# shape from lowtrust.bash, which explains why both sources are needed: the
# kernel evicts a neighbour entry within minutes of a device going quiet, and a
# sleeping device is exactly the one someone is about to act on. Prints nothing
# when neither source knows the address, which the callers handle rather than
# treating as fatal.
resolve_mac() {
	local target="$1" mac
	if is_mac "$target"; then
		printf '%s' "$target" | tr 'A-F' 'a-f'
		return 0
	fi
	mac=$(neigh | awk -v want="$target" '
		$1 == want { for (i = 1; i <= NF; i++) if ($i == "lladdr") { print $(i + 1); exit } }')
	if [ -z "$mac" ] && [ -r "$LEASE_FILE" ]; then
		# Lease line is: <expiry> <mac> <addr> <name> <clientid>. Last match
		# wins, matching how router-web reads the same file.
		mac=$(awk -v want="$target" '$3 == want { found = $2 } END { if (found != "") print found }' "$LEASE_FILE")
	fi
	printf '%s' "$mac" | tr 'A-F' 'a-f'
}

# Every address this device holds. Link-local is skipped: it is never forwarded,
# so an element for it could only ever be a rule that matches nothing and a line
# in `cooldown list` that means nothing.
device_addrs() {
	local mac="$1" target="$2"
	{
		if [ -n "$mac" ]; then
			neigh | awk -v want="$mac" '
				{ for (i = 1; i <= NF; i++) if ($i == "lladdr" && tolower($(i + 1)) == want) print $1 }'
			if [ -r "$LEASE_FILE" ]; then
				awk -v want="$mac" 'tolower($2) == want { print $3 }' "$LEASE_FILE"
			fi
		fi
		# The address that was asked about, even when neither source knows it:
		# on a statically-addressed device it is the only handle there is.
		is_mac "$target" || printf '%s\n' "$target"
	} | grep -vi '^fe80:' | sort -u
}

# Go's duration syntax, restricted to whole hours, minutes and seconds — which
# covers every duration anyone types into the box on the peers page. A bare
# number is read as seconds. Prints the total in seconds.
#
# 10# on every arithmetic use, because "08m" is an ordinary thing to type and
# bash reads a leading zero as octal and fails the whole command.
parse_duration() {
	local text="$1" total=0 num unit rest
	[ -n "$text" ] || return 1
	case "$text" in
	*[!0-9]*) : ;;
	*)
		printf '%s' "$((10#$text))"
		return 0
		;;
	esac
	rest="$text"
	while [ -n "$rest" ]; do
		num="${rest%%[!0-9]*}"
		[ -n "$num" ] || return 1
		rest="${rest#"$num"}"
		unit="${rest%%[0-9]*}"
		[ -n "$unit" ] || return 1
		rest="${rest#"$unit"}"
		case "$unit" in
		h) total=$((total + 10#$num * 3600)) ;;
		m) total=$((total + 10#$num * 60)) ;;
		s) total=$((total + 10#$num)) ;;
		*) return 1 ;;
		esac
	done
	printf '%s' "$total"
}

fmt_duration() {
	local secs="$1" out=""
	if [ "$secs" -ge 3600 ]; then out="$((secs / 3600))h"; fi
	if [ "$((secs % 3600 / 60))" -gt 0 ]; then out="$out$((secs % 3600 / 60))m"; fi
	if [ "$((secs % 60))" -gt 0 ]; then out="$out$((secs % 60))s"; fi
	printf '%s' "${out:-0s}"
}

# True if $2 is currently an element of set $1.
#
# Needed because nft's `add element` IGNORES an element that is already there,
# timeout and all, so a second cooldown on the same device would silently keep
# the first deadline instead of replacing it. cmd_add therefore deletes before
# it adds — and it may only emit a delete for an element that exists, because a
# delete of a missing element aborts the whole transaction.
#
# Bounded by non-address characters rather than matched as a substring, which is
# not fastidiousness: `grep -F 192.168.0.1` matches the line holding
# 192.168.0.10, and every such false positive turns into a delete of an element
# that is not there, which takes the add down with it and leaves the device
# uncooled while reporting success.
in_set() {
	local escaped="${2//./\\.}"
	# shellcheck disable=SC2086 # TABLE is two words on purpose: "inet <table>"
	nft list set $TABLE "$1" 2>/dev/null |
		grep -qiE "(^|[^0-9A-Fa-f.:])${escaped}([^0-9A-Fa-f.:]|\$)"
}

# Whether any device is in cooldown. Read from the three device sets, not from
# the carve-out, which outlives a cooldown by up to its own timeout.
any_active() {
	local set
	for set in "$MAC_SET" "$SET4" "$SET6"; do
		# shellcheck disable=SC2086 # TABLE is two words on purpose
		if nft list set $TABLE "$set" 2>/dev/null | grep -q 'elements = {'; then
			return 0
		fi
	done
	return 1
}

# Resolve the captive-portal names into the carve-out sets.
#
# Flush and add go in as ONE `nft -f` transaction, and a family that resolved
# nothing keeps its previous contents rather than being emptied — both lessons
# from nft-lowtrust-stun, which learned them the hard way on 2026-08-14: two
# separate calls turned a resolver blip into a flushed set, and an emptiness
# check cannot catch what a malformed element does to an add that follows a
# flush which has already succeeded.
refresh_allow() {
	local name addr v4="" v6=""
	[ -n "$ALLOW_DOMAINS" ] || return 0
	for name in $ALLOW_DOMAINS; do
		for addr in $(dig +short +timeout=3 +tries=2 "$name" A 2>/dev/null || true); do
			# Whole-token validation, not a character search. `dig` prints
			# ";; communications error to 127.0.0.1#53: timed out" on stdout as
			# well as stderr, and word-splitting hands each piece of that here
			# as an "address"; a CNAME in the chain arrives the same way. Both
			# carry a character an address cannot, which is what rejects them.
			case "$addr" in
			*[!0-9.]*) continue ;;
			0.0.0.0) continue ;;
			esac
			v4="$v4$addr, "
		done
		for addr in $(dig +short +timeout=3 +tries=2 "$name" AAAA 2>/dev/null || true); do
			case "$addr" in
			*[!0-9A-Fa-f:]*) continue ;;
			::) continue ;;
			*:*) v6="$v6$addr, " ;;
			esac
		done
	done
	if [ -n "$v4" ]; then
		printf 'flush set %s %s\nadd element %s %s { %s }\n' \
			"$TABLE" "$ALLOW4" "$TABLE" "$ALLOW4" "${v4%, }" | nft -f -
	else
		echo "cooldown: no IPv4 address resolved for any captive-portal name; keeping the previous carve-out" >&2
	fi
	# No matching complaint for v6: a network with no IPv6 answers resolves
	# nothing here every single run, and a warning that is always printed is one
	# nobody reads.
	if [ -n "$v6" ]; then
		printf 'flush set %s %s\nadd element %s %s { %s }\n' \
			"$TABLE" "$ALLOW6" "$TABLE" "$ALLOW6" "${v6%, }" | nft -f -
	fi
}

cmd_add() {
	local target="$1" secs mac addrs script="" addr set
	secs=$(parse_duration "$2") ||
		die "unparseable duration: $2 — use 5m, 90s or 1h30m"
	[ "$secs" -gt 0 ] || die "duration must be more than zero"
	[ "$secs" -le "$MAX_SECONDS" ] ||
		die "duration $2 is longer than the $(fmt_duration "$MAX_SECONDS") ceiling (sifr.router.cooldown.maxSeconds)"

	mac=$(resolve_mac "$target")
	mapfile -t addrs < <(device_addrs "$mac" "$target")
	if [ -z "$mac" ] && [ "${#addrs[@]}" -eq 0 ]; then
		die "no MAC and no address for $target — nothing to put in cooldown"
	fi
	if [ -z "$mac" ]; then
		# Not fatal: the address rules still cut this device off. Worth saying
		# because the cover is narrower — an IPv6 address the device forms
		# during the cooldown is in no set, so its egress over that address is
		# not dropped.
		echo "cooldown: WARNING: no MAC for $target (not in the neighbour table or the leases)," \
			"so this cooldown covers only the addresses it holds right now, not any it forms later." \
			"Re-run against the MAC once the device is awake to close that." >&2
	fi

	# The carve-out first, so the very first probe after the drop lands has
	# somewhere to go. Best effort: a resolver that is down must not stop a
	# cooldown being applied — it only costs the device its "connected" badge.
	refresh_allow ||
		echo "cooldown: WARNING: could not refresh the captive-portal carve-out; the device will report no internet" >&2

	if [ -n "$mac" ]; then
		if in_set "$MAC_SET" "$mac"; then
			script="delete element $TABLE $MAC_SET { $mac }"$'\n'
		fi
		script="${script}add element $TABLE $MAC_SET { $mac timeout ${secs}s }"$'\n'
	fi
	for addr in "${addrs[@]}"; do
		case "$addr" in
		*:*) set="$SET6" ;;
		*) set="$SET4" ;;
		esac
		if in_set "$set" "$addr"; then
			script="${script}delete element $TABLE $set { $addr }"$'\n'
		fi
		script="${script}add element $TABLE $set { $addr timeout ${secs}s }"$'\n'
	done
	# One transaction for the whole device: a cooldown that reached a phone's
	# IPv4 address and not its IPv6 one is not a cooldown, it is a confusing
	# afternoon.
	printf '%s' "$script" | nft -f -

	echo "cooldown: ${mac:-$target} for $(fmt_duration "$secs") (${#addrs[@]} address(es))"

	# After the rules, never before — a packet in flight between the teardown
	# and the drop landing recreates the conntrack entry, and the cooldown then
	# looks broken to whoever is watching the peers page. One call covers the
	# device: killconn's `from` form expands an address to every address that
	# device holds, both families.
	#
	# A failure is a warning and not an abort, for the reason tempblock's
	# try_killconn gives at length: the rules ARE the cooldown and are already
	# live, so a teardown that failed must not read as a cooldown that failed.
	if [ "${#addrs[@]}" -gt 0 ]; then
		if ! killconn from "${addrs[0]}" >/dev/null; then
			echo "cooldown: WARNING: the cooldown IS in place, but tearing down open flows failed;" \
				"long-lived connections may dribble on until they time out. Re-run to retry." >&2
		fi
	fi
}

cmd_del() {
	local target="$1" mac addrs script="" addr set found=0
	mac=$(resolve_mac "$target")
	mapfile -t addrs < <(device_addrs "$mac" "$target")
	if [ -n "$mac" ] && in_set "$MAC_SET" "$mac"; then
		script="delete element $TABLE $MAC_SET { $mac }"$'\n'
		found=1
	fi
	for addr in "${addrs[@]}"; do
		case "$addr" in
		*:*) set="$SET6" ;;
		*) set="$SET4" ;;
		esac
		if in_set "$set" "$addr"; then
			script="${script}delete element $TABLE $set { $addr }"$'\n'
			found=1
		fi
	done
	if [ "$found" -eq 0 ]; then
		# Already the desired end state — exit 0, not die(), for the same reason
		# tempblock prints "not blocked" rather than failing. A repeat of an
		# already-applied action is not an error, and this one is a web button
		# that will get double-pressed.
		echo "cooldown: not in cooldown: $target"
		return 0
	fi
	printf '%s' "$script" | nft -f -
	echo "cooldown: released ${mac:-$target}"
}

# One "<value>\t<seconds left>" line per element of a set. Read from JSON rather
# than nft's own output because the remaining time is what makes this worth
# printing, and it is a field of its own in the JSON and a suffix inside a brace
# list in the text form.
set_elements() {
	# shellcheck disable=SC2086 # TABLE is two words on purpose: "inet <table>"
	nft -j list set $TABLE "$1" 2>/dev/null |
		jq -r '.nftables[]? | select(.set) | .set.elem[]?
			| (if (type == "object" and has("elem")) then .elem else {val: ., expires: 0} end)
			| "\(.val)\t\(.expires // 0)"' 2>/dev/null
}

cmd_list() {
	local set kind val expires any=0
	for set in "$MAC_SET" "$SET4" "$SET6"; do
		case "$set" in
		"$MAC_SET") kind="mac" ;;
		"$SET4") kind="ipv4" ;;
		*) kind="ipv6" ;;
		esac
		while IFS=$'\t' read -r val expires; do
			[ -n "$val" ] || continue
			any=1
			printf '  %-5s %-24s %s left\n' "$kind" "$val" "$(fmt_duration "${expires:-0}")"
		done < <(set_elements "$set")
	done
	[ "$any" -eq 1 ] || echo "nothing is in cooldown"
}

cmd_refresh() {
	if [ "${1:-}" = "--if-active" ] && ! any_active; then
		exit 0
	fi
	refresh_allow
}

usage() {
	cat >&2 <<'USAGE'
cooldown — take a device off the internet for a fixed period

  cooldown add <ip|mac> <duration>   no internet until the duration is up
  cooldown del <ip|mac>              release it now
  cooldown list                      what is in cooldown, and for how much longer
  cooldown refresh [--if-active]     re-resolve the captive-portal carve-out

Durations are Go-style: 5m, 90s, 1h30m. A bare number is seconds.

The device keeps its Wi-Fi association, its DHCP lease, DNS through this
router, everything else on its own LAN segment, and its captive-portal probe,
so the phone does not decide the network is broken and fall back to cellular.
Everything else is dropped, both directions.

The deadline is an nftables element timeout: nothing has to run to lift it, and
a reboot or a ruleset reload ends it early rather than late.
USAGE
	exit "${1:-0}"
}

sub="${1:-}"
shift || true
case "$sub" in
add)
	[ "$#" -ge 2 ] || usage 1
	cmd_add "$1" "$2"
	;;
del | rm | end)
	[ "$#" -ge 1 ] || usage 1
	cmd_del "$1"
	;;
list | ls) cmd_list ;;
refresh) cmd_refresh "${1:-}" ;;
-h | --help | help | "") usage 0 ;;
*) usage 1 ;;
esac
