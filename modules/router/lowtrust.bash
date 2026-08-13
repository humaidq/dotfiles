#!/usr/bin/env bash
# lowtrust — add or remove a device from the low-trust pool at runtime.
#
# Writes only to lowtrust_macs_temp. The permanent set comes from a sops secret
# and is loaded by nft-lowtrust-macs.service; this tool cannot touch it, which
# is what makes "remove" safe — a button press can never silently undo a device
# that was deliberately put in the permanent list.
#
# "Temporary" means until the next rebuild reloads the ruleset, or until `del`.
# Unlike tempblock, which keeps its own table and therefore survives rebuilds,
# this writes to a set declared by networking.nftables.tables, so a rebuild
# genuinely does clear it.
#
# Accepts a device IP as well as a MAC, because the peers page is per-device-IP
# and the pool is keyed on MAC. Resolution is via the neighbour table.
set -euo pipefail

PATH="/run/wrappers/bin:$PATH"

# Both tables. The sets are declared in each because nftables scopes a set to
# its table and offers no way to share one: router-blocklists holds the drop
# chains, router-filter holds qos-mark. Writing only the first leaves a device
# blocked but still eligible for the voice tin, which is the half of the policy
# that is hardest to notice missing.
readonly TABLES=("inet router-blocklists" "inet router-filter")
readonly SET="lowtrust_macs_temp"
readonly PERM_SET="lowtrust_macs"

nft() {
	if [ "$(id -u)" -eq 0 ] || command nft list tables >/dev/null 2>&1; then
		command nft "$@"
	else
		sudo -n /run/current-system/sw/bin/nft "$@"
	fi
}

die() {
	echo "lowtrust: $*" >&2
	exit 1
}

usage() {
	cat <<-'USAGE'
		lowtrust — runtime membership of the low-trust device pool

		  lowtrust add <ip|mac>   put a device in the pool now
		  lowtrust del <ip|mac>   take it out again
		  lowtrust list           show temporary and permanent membership
		  lowtrust status         rule counters for the pool policy

		Temporary membership is cleared by the next rebuild. Permanent members
		live in a sops secret and cannot be changed from here.
	USAGE
	exit "${1:-0}"
}

# A MAC is six colon-separated hex pairs. Anything else is treated as an IP and
# looked up in the neighbour table.
is_mac() {
	printf '%s' "$1" | grep -qiE '^([0-9a-f]{2}:){5}[0-9a-f]{2}$'
}

resolve_mac() {
	local target="$1" mac
	if is_mac "$target"; then
		printf '%s' "$target" | tr 'A-F' 'a-f'
		return 0
	fi

	mac=$(ip neigh show "$target" 2>/dev/null | awk '/lladdr/ {print $5; exit}')
	[ -n "$mac" ] || die "no neighbour entry for $target — the device must have talked to the router recently"
	printf '%s' "$mac" | tr 'A-F' 'a-f'
}

# Refuses a device that is already permanent. Adding it to the temp set as well
# would work, but `del` would then appear to succeed while the device stayed in
# the pool — a button that reports success and changes nothing.
in_permanent() {
	# shellcheck disable=SC2086 # TABLES[0] is two words on purpose: "inet <table>"
	nft list set ${TABLES[0]} $PERM_SET 2>/dev/null | grep -qiF "$1"
}

# True if $2 is currently an element of $SET on table $1. Unlike `add`,
# `nft delete element` on a MAC that is not present errors rather than
# no-opping, so cmd_del must check per table before it deletes — see there
# for why that check has to be per table and not just once.
in_temp_set() {
	local t="$1" mac="$2"
	# shellcheck disable=SC2086 # $t is two words on purpose: "inet <table>"
	nft list set $t $SET 2>/dev/null | grep -qiF "$mac"
}

cmd_add() {
	local mac
	mac=$(resolve_mac "$1")
	if in_permanent "$mac"; then
		die "already a permanent member; remove it from the sops secret instead"
	fi
	for t in "${TABLES[@]}"; do
		# shellcheck disable=SC2086 # $t is two words on purpose: "inet <table>"
		nft add element $t $SET "{ $mac }"
	done
	echo "lowtrust: added $mac"
}

cmd_del() {
	local mac t found=0 missing=0
	mac=$(resolve_mac "$1")
	if in_permanent "$mac"; then
		die "permanent member; remove it from the sops secret instead"
	fi
	# `del` is the button Task 6 wires a web page to, and web buttons get
	# double-pressed: a second click, or a stale IP whose MAC already left the
	# pool, calls this with a MAC that is not in $SET. `delete element` is not
	# like `add element` — it errors on a missing element instead of no-opping
	# — and the two tables are updated independently, so under set -e a naive
	# loop can delete cleanly from the first table and then hard-crash on the
	# second, aborting with an nft traceback and no record of what changed.
	# So each table is checked before its delete, and "not there" is a normal
	# outcome, not a failure: the state the caller wants (mac not in the pool)
	# already holds.
	for t in "${TABLES[@]}"; do
		if in_temp_set "$t" "$mac"; then
			found=1
			# shellcheck disable=SC2086 # $t is two words on purpose: "inet <table>"
			nft delete element $t $SET "{ $mac }"
		else
			missing=1
		fi
	done
	if [ "$found" -eq 0 ]; then
		# Already the desired end state — exit 0, not die(), for the same
		# reason tempblock's cmd_del prints "not blocked: $ip" instead of
		# failing: a repeat of an already-applied action is not an error.
		echo "lowtrust: not in the pool: $mac"
		return 0
	fi
	if [ "$missing" -eq 1 ]; then
		# Present in one table but not the other is not a normal state to
		# reach — add/del write both tables every time — so it means an
		# earlier operation was interrupted partway through. Worth a word on
		# stderr even though the fix (delete where it exists) is silent and
		# automatic, so the gap doesn't get normalised away without a trace.
		echo "lowtrust: $mac was only in one of the two tables (leftover from an" \
			"earlier partial failure) — removed there; the other table already" \
			"had no entry to remove" >&2
	fi
	echo "lowtrust: removed $mac"
}

cmd_list() {
	echo "temporary:"
	# shellcheck disable=SC2086 # TABLES[0] is two words on purpose: "inet <table>"
	nft list set ${TABLES[0]} $SET
	echo
	echo "permanent:"
	# shellcheck disable=SC2086 # TABLES[0] is two words on purpose: "inet <table>"
	nft list set ${TABLES[0]} $PERM_SET
}

cmd_status() {
	# shellcheck disable=SC2086 # TABLES[0] is two words on purpose: "inet <table>"
	nft list chain ${TABLES[0]} lowtrust_policy
}

sub="${1:-}"
shift || true
case "$sub" in
add) [ $# -ge 1 ] || usage 1; cmd_add "$1" ;;
del) [ $# -ge 1 ] || usage 1; cmd_del "$1" ;;
list) cmd_list ;;
status) cmd_status ;;
-h | --help | "") usage 0 ;;
*) die "unknown subcommand: $sub" ;;
esac
