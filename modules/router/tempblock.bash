#!/usr/bin/env bash
# tempblock — add ad-hoc, non-persistent IP drops on a router.
#
# Blocks live in their own nftables table (inet router_tempblock) with a
# forward-hook chain at priority -20, so they take effect immediately and sit
# ahead of the blocklist chains.
#
# "Temporary" means a reboot, NOT a rebuild. This comment used to claim that
# `nixos-rebuild switch` cleared them, and it does not: networking.nftables.tables
# manages named tables individually rather than flushing the whole ruleset, so a
# table created here is invisible to it and survives every rebuild. 99 blocks
# added over one session were found still in force afterwards, silently dropping
# traffic that had since been moved to custom-throttle-list.txt to be shaped
# instead — the block won, and the new policy never applied.
#
# So `tempblock flush` is a step you have to take deliberately. Check `list`
# before assuming a rebuild cleaned up after you, and remember the same is true
# of any other ad-hoc table (imo_temp, adware_temp) left behind by hand.
#
# Each address is its own rule with its own counter, so `list` shows exactly
# which target is being hit and how hard — the usual reason to set a temp block
# is to watch whether a just-blocked app keeps hammering the address.
set -euo pipefail

# The setuid sudo wrapper is not on writeShellApplication's runtime PATH; add it
# so the non-root path below can find sudo.
PATH="/run/wrappers/bin:$PATH"

readonly TABLE_FAMILY="inet"
readonly TABLE_NAME="router_tempblock"
readonly CHAIN="block"

# All nft calls funnel through here. When already root, run nft directly. When
# not, go through sudo to the fully-qualified nft that the router's sudo rules
# whitelist NOPASSWD (see hosts/<router>/default.nix) — the absolute path is
# used rather than a bare `nft` so the grant matches regardless of secure_path.
nft() {
	if [ "$(id -u)" -eq 0 ] || command nft list tables >/dev/null 2>&1; then
		command nft "$@"
	else
		sudo -n /run/current-system/sw/bin/nft "$@"
	fi
}

die() {
	echo "tempblock: $*" >&2
	exit 1
}

# ip6 addresses are the ones with a colon; everything else is treated as ip.
fam_of() {
	case "$1" in
	*:*) echo "ip6" ;;
	*) echo "ip" ;;
	esac
}

# Catch typos early with a friendly message. nft would reject them too, but only
# after set -e aborted the rest of the batch.
validate() {
	case "$1" in
	*[!0-9a-fA-F:./]*) die "not an IP or CIDR: $1" ;;
	*[.:]*) : ;;
	*) die "not an IP or CIDR: $1" ;;
	esac
}

table_exists() {
	nft list table "$TABLE_FAMILY" "$TABLE_NAME" >/dev/null 2>&1
}

# Idempotent setup: `add` is a no-op when the object already exists, so this is
# safe to call before every mutation.
ensure() {
	nft add table "$TABLE_FAMILY" "$TABLE_NAME"
	nft add chain "$TABLE_FAMILY" "$TABLE_NAME" "$CHAIN" \
		'{ type filter hook forward priority -20 ; policy accept ; }'
}

# Print the rule handle for an address, or nothing if it is not blocked. index()
# rather than a regex match so the dots in an address are literal.
rule_handle() {
	nft -a list chain "$TABLE_FAMILY" "$TABLE_NAME" "$CHAIN" 2>/dev/null |
		awk -v needle="comment \"tempblock:$1\"" '
			index($0, needle) {
				for (i = 1; i <= NF; i++)
					if ($i == "handle") { print $(i + 1); exit }
			}'
}

cmd_add() {
	[ "$#" -ge 1 ] || die "add needs at least one IP or CIDR"
	ensure
	for ip in "$@"; do
		validate "$ip"
		if [ -n "$(rule_handle "$ip")" ]; then
			echo "already blocked: $ip"
			continue
		fi
		# The comment is passed with literal double quotes inside the argument.
		# nft joins its argv back into one string and re-lexes it, so the shell's
		# own quotes are long gone by then and a bare tempblock:1.2.3.4 makes its
		# parser stop at the colon ("unexpected colon"), so every add aborted on
		# the first address and no rule was ever installed.
		nft add rule "$TABLE_FAMILY" "$TABLE_NAME" "$CHAIN" \
			"$(fam_of "$ip")" daddr "$ip" counter drop comment "\"tempblock:$ip\""
		echo "blocked: $ip"
	done
}

cmd_del() {
	[ "$#" -ge 1 ] || die "del needs at least one IP or CIDR"
	if ! table_exists; then
		echo "no temp blocks set"
		return 0
	fi
	for ip in "$@"; do
		handle="$(rule_handle "$ip")"
		if [ -z "$handle" ]; then
			echo "not blocked: $ip"
			continue
		fi
		nft delete rule "$TABLE_FAMILY" "$TABLE_NAME" "$CHAIN" handle "$handle"
		echo "unblocked: $ip"
	done
}

cmd_list() {
	if ! table_exists; then
		echo "no temp blocks set"
		return 0
	fi
	nft -a list chain "$TABLE_FAMILY" "$TABLE_NAME" "$CHAIN" |
		awk '
			/tempblock:/ {
				ip = ""; pk = 0; by = 0
				for (i = 1; i <= NF; i++) {
					if ($i == "daddr")   ip = $(i + 1)
					if ($i == "packets") pk = $(i + 1)
					if ($i == "bytes")   by = $(i + 1)
				}
				printf "  %-22s packets=%s bytes=%s\n", ip, pk, by
			}'
}

cmd_flush() {
	if ! table_exists; then
		echo "no temp blocks set"
		return 0
	fi
	nft delete table "$TABLE_FAMILY" "$TABLE_NAME"
	echo "cleared all temp blocks"
}

usage() {
	cat >&2 <<'USAGE'
tempblock — temporary, non-persistent IP drops (cleared on the next rebuild)

  tempblock add   <ip|cidr> [more...]   block now; one counter per address
  tempblock del   <ip|cidr> [more...]   remove a block
  tempblock list                        show blocks and their hit counters
  tempblock flush                       remove every temp block

Persistent blocks belong in modules/router/custom-ip-blocklist.txt + a rebuild.
USAGE
	exit "${1:-0}"
}

sub="${1:-}"
shift || true
case "$sub" in
add) cmd_add "$@" ;;
del | rm) cmd_del "$@" ;;
list | ls) cmd_list ;;
flush | clear) cmd_flush ;;
-h | --help | help | "") usage 0 ;;
*) usage 1 ;;
esac
