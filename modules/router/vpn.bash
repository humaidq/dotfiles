#!/usr/bin/env bash
# routervpn — bring the on-demand WireGuard tunnel to whatever the switch says.
#
# The whole feature is two files in $VPN_STATE_DIR:
#
#   desired        one word, "on" or "off". The switch. Written by router-web
#                  (which is in the state group and can write nothing else) or
#                  by `routervpn on|off` here. This file is the persistence:
#                  it is what makes the tunnel come back after a reboot.
#   observed.json  what this script last managed to do — the public key, the
#                  ephemeral name, the address it points at, and any note.
#                  Written only here, read by router-web to render the page.
#
# Splitting desired from observed is what lets the web UI say "enabling…"
# honestly instead of claiming success the moment a button is pressed. One
# writer each, so neither can clobber the other.
#
# `apply` is run at boot, by a path unit when the switch changes, and by a timer
# every minute. It is idempotent by construction: every step checks the world
# before changing it, which is also what makes the timer a repair pass — it
# re-points the DNS record after the daily redial and closes the port gate again
# after a ruleset reload.
#
# Failure policy: the tunnel comes first. A DNS step that fails is recorded in
# observed.json and retried on the next tick; it never tears down a working
# tunnel. Anything fatal aborts, is left in the journal, and the timer tries
# again in a minute.
set -euo pipefail
# ERR traps are not inherited by functions without this, and without inheritance
# a failure inside one of them would exit with nothing written to observed.json
# — leaving the page reporting the state from before the failure as though it
# were current.
set -E

readonly DESIRED="$VPN_STATE_DIR/desired"
readonly OBSERVED="$VPN_STATE_DIR/observed.json"
readonly PRIVATE_KEY="$VPN_STATE_DIR/private.key"
readonly PUBLIC_KEY="$VPN_STATE_DIR/public.key"
readonly LOCK="$VPN_STATE_DIR/.lock"

# Secrets are assembled here, never in the state directory: systemd gives the
# service a private tmpfs directory, so the API key and the peer list — which
# carries the server private key — are gone at reboot and were never written to
# the disk this router boots from.
RUNDIR="${RUNTIME_DIRECTORY:-}"

# What write_observed reports. Filled in as the reconcile learns it, so a pass
# that fails half way still writes what it did establish.
LABEL=""
FQDN=""
RECORD_ID=""
PUBLIC_ADDR=""
PEER_COUNT=0
NOTE=""
# Status of the last Vultr call. A global rather than a return value because
# every caller needs both it and the response body, and a function can only
# hand back one of the two.
API_STATUS=""

log() {
	echo "routervpn: $*" >&2
}

die() {
	log "$*"
	exit 1
}

usage() {
	cat <<-'USAGE'
		routervpn — the on-demand WireGuard tunnel

		  routervpn on       switch the tunnel on and reconcile now
		  routervpn off      switch it off, delete the ephemeral name
		  routervpn status   what the switch says and what was last done
		  routervpn apply    reconcile with the switch (systemd runs this)

		The switch persists across reboots. Turning it off and on again takes a
		new random name in the zone; a reboot keeps the one it has.
	USAGE
	exit "${1:-0}"
}

need_root() {
	[ "$(id -u)" -eq 0 ] || die "must be root"
}

# A directory for the two secret-bearing temporary files. Under systemd this is
# the unit's RuntimeDirectory; run by hand it is a fresh tmpfs directory that
# goes away with the process.
ensure_rundir() {
	if [ -n "$RUNDIR" ] && [ -d "$RUNDIR" ]; then
		return
	fi
	RUNDIR=$(mktemp -d /run/routervpn.XXXXXX)
	chmod 0700 "$RUNDIR"
	trap 'rm -rf "$RUNDIR"' EXIT
}

# The directory and the switch file, enforced here rather than declared with
# tmpfiles.
#
# tmpfiles was the obvious home for this and it silently lost. On an impermanent
# host the directory is a bind mount from /persist, and that mount is
# established after systemd-tmpfiles-setup has run: tmpfiles dressed a directory
# that was then covered over, so what router-web actually saw was impermanence's
# own 0755 root:root with no switch file in it, and every write failed with
# EACCES. Run from here it is applied as root in multi-user, after every mount
# that could hide it, on every pass.
#
# 0750 on the directory and 0660 on the file is the whole of router-web's
# privilege: it can rewrite this one file and create nothing, which is why the
# file has to exist before it is ever asked to.
ensure_state_dir() {
	[ -d "$VPN_STATE_DIR" ] || mkdir -p "$VPN_STATE_DIR"
	chgrp "$VPN_STATE_GROUP" "$VPN_STATE_DIR"
	chmod 0750 "$VPN_STATE_DIR"

	# Created off. A router that has never been told otherwise must not come up
	# with a port open to the internet.
	[ -e "$DESIRED" ] || printf 'off\n' >"$DESIRED"
	chgrp "$VPN_STATE_GROUP" "$DESIRED"
	chmod 0660 "$DESIRED"
}

read_desired() {
	local raw=""
	if [ -r "$DESIRED" ]; then
		raw=$(tr -d '[:space:]' <"$DESIRED")
	fi
	case "$raw" in
	on) echo "on" ;;
	# Anything that is not exactly "on" is off: an empty file, a half-written
	# one, a typo. The switch opens a port to the internet, so the unreadable
	# case has to land on the closed side.
	*) echo "off" ;;
	esac
}

# ---------------------------------------------------------------- observed

# One field of the last report, or "" if there is no report or no such field.
# Written out the long way rather than with `// ""` because that alternative
# treats `false` as absent, and `enabled` is exactly the field where the
# difference matters.
observed_field() {
	[ -r "$OBSERVED" ] || return 0
	jq -r --arg key "$1" '.[$key] | if . == null then "" else tostring end' \
		"$OBSERVED" 2>/dev/null || true
}

# Written through a temporary file and renamed, so router-web can never read a
# half-written report. Renaming is safe here precisely because nothing watches
# this file — the path unit watches `desired`, which is why that one is
# rewritten in place instead.
write_observed() {
	local enabled="$1"
	local tmp
	tmp=$(mktemp "$VPN_STATE_DIR/.observed.XXXXXX")
	jq -n \
		--argjson enabled "$enabled" \
		--arg interface "$VPN_IFACE" \
		--argjson port "$VPN_PORT" \
		--arg address "$VPN_ADDRESS" \
		--arg publicKey "$(cat "$PUBLIC_KEY" 2>/dev/null || true)" \
		--argjson peers "$PEER_COUNT" \
		--arg label "$LABEL" \
		--arg fqdn "$FQDN" \
		--arg recordId "$RECORD_ID" \
		--arg publicAddress "$PUBLIC_ADDR" \
		--arg updated "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
		--arg note "$NOTE" \
		'{enabled: $enabled, interface: $interface, port: $port, address: $address,
		  publicKey: $publicKey, peers: $peers, label: $label, fqdn: $fqdn,
		  recordId: $recordId, publicAddress: $publicAddress, updated: $updated,
		  note: $note}' >"$tmp"
	chgrp "$VPN_STATE_GROUP" "$tmp"
	chmod 0640 "$tmp"
	mv "$tmp" "$OBSERVED"
}

# The ERR trap. Records that the pass did not finish without inventing a state
# for the tunnel: whatever `enabled` said before stays, with a note pointing at
# the journal. Disarms itself first, or a failure inside it would recurse.
report_failure() {
	trap - ERR
	local was
	was=$(observed_field enabled)
	[ "$was" = "true" ] || was="false"
	NOTE="the last reconcile did not finish; see journalctl -u router-vpn"
	write_observed "$was" || true
}

# ---------------------------------------------------------------- wireguard

ensure_key() {
	if [ -s "$PRIVATE_KEY" ]; then
		return
	fi
	# Generated here rather than handed in as a secret, so the tunnel can be
	# stood up without a rebuild. It never leaves the router: 0600 root, in a
	# directory router-web can only traverse.
	log "generating a server key"
	(
		umask 077
		wg genkey >"$PRIVATE_KEY"
	)
	wg pubkey <"$PRIVATE_KEY" >"$PUBLIC_KEY"
	chmod 0644 "$PUBLIC_KEY"
}

ensure_link() {
	if ! ip link show "$VPN_IFACE" >/dev/null 2>&1; then
		ip link add "$VPN_IFACE" type wireguard
	fi
	# Flushed and re-added only when it does not already match, because this
	# runs every minute and flushing the address every time would drop the
	# connected route — and with it every client's return path — once a minute
	# for as long as the tunnel is up.
	if ! ip -o address show dev "$VPN_IFACE" | grep -qF " $VPN_ADDRESS "; then
		ip address flush dev "$VPN_IFACE"
		ip address add "$VPN_ADDRESS" dev "$VPN_IFACE"
	fi
	wg set "$VPN_IFACE" listen-port "$VPN_PORT" private-key "$PRIVATE_KEY"
	ip link set "$VPN_IFACE" up
}

# Rewrites the peer list from the secret every pass, so adding a client is a
# sops edit and a `systemctl start router-vpn` rather than a rebuild.
#
# syncconf rather than addconf: it removes peers that are no longer in the file,
# which is what makes deleting a line from the secret actually revoke a device.
sync_peers() {
	local conf="$RUNDIR/wg.conf"
	local -a allowed_all=()
	PEER_COUNT=0

	(
		umask 077
		{
			echo "[Interface]"
			echo "PrivateKey = $(cat "$PRIVATE_KEY")"
			echo "ListenPort = $VPN_PORT"
		} >"$conf"
	)

	if [ -n "$VPN_PEERS_FILE" ] && [ -r "$VPN_PEERS_FILE" ]; then
		local key allowed
		while read -r key allowed _ || [ -n "$key" ]; do
			case "$key" in
			'') continue ;;
			esac
			if [ -z "$allowed" ]; then
				log "peer line for ${key:0:8}… has no allowed IPs; skipped"
				continue
			fi
			# A key that is not a key makes wg reject the whole file, and with
			# it every good peer beside it. Checked here so one bad line costs
			# one client rather than all of them.
			if ! [[ "$key" =~ ^[A-Za-z0-9+/]{43}=$ ]]; then
				log "peer line does not begin with a WireGuard public key; skipped"
				continue
			fi
			{
				echo "[Peer]"
				echo "PublicKey = $key"
				echo "AllowedIPs = $allowed"
			} >>"$conf"
			allowed_all+=("$allowed")
			PEER_COUNT=$((PEER_COUNT + 1))
		done < <(sed 's/#.*//' "$VPN_PEERS_FILE")
	fi

	wg syncconf "$VPN_IFACE" "$conf"
	rm -f "$conf"
	route_peers "${allowed_all[@]}"
}

# A route per allowed prefix, which is what makes a travel router work rather
# than just a laptop.
#
# wg(8) adds no routes — that is wg-quick's job, and this does not use it. A
# client whose allowed IPs are a single address inside the tunnel prefix needs
# none: the connected route from the interface address already covers it. A
# travel router announcing the LAN behind it does, in both directions:
#
#   - without a route, replies to that LAN have nowhere to go;
#   - and the firewall's strict reverse-path check drops its packets on
#     arrival, because a source it has no route back to is exactly what that
#     check exists to refuse.
#
# Skipped when this device already routes the prefix, which is not just an
# optimisation. A peer whose allowed IPs are the tunnel network itself — one
# travel router given the whole range — is already covered by the connected
# route the interface address created, and `replace` would overwrite that
# kernel route with a static one that has lost its preferred-source hint.
# Checking first leaves the kernel's own route alone and adds only what is
# genuinely missing.
#
# Nothing removes these: a peer deleted from the secret is already refused by
# WireGuard itself, the route left behind leads to an interface with no peer to
# carry it, and the whole set goes when the tunnel is switched off and the
# interface is destroyed.
route_peers() {
	local entry cidr
	local -a cidrs
	for entry in "$@"; do
		IFS=',' read -ra cidrs <<<"$entry"
		for cidr in "${cidrs[@]}"; do
			cidr="${cidr//[[:space:]]/}"
			[ -n "$cidr" ] || continue
			if [ -n "$(ip route show "$cidr" dev "$VPN_IFACE" 2>/dev/null)" ]; then
				continue
			fi
			if ! ip route add "$cidr" dev "$VPN_IFACE" 2>/dev/null; then
				log "cannot route $cidr via $VPN_IFACE; that client's network will not be reachable"
			fi
		done
	done
}

# ---------------------------------------------------------------- port gate
#
# The gate is a drop, not an accept: see the long comment in vpn.nix for why
# netfilter leaves no other option. An element in the set means the port is
# refused on the WAN; no element means the firewall's own accept stands.

gate() {
	case "$1" in
	open)
		# Already absent on every pass after the first, which nft reports as an
		# error. Not one worth failing a working tunnel over.
		nft delete element inet "$VPN_GATE_TABLE" "$VPN_GATE_SET" "{ $VPN_PORT }" 2>/dev/null || true
		;;
	close)
		if ! nft add element inet "$VPN_GATE_TABLE" "$VPN_GATE_SET" "{ $VPN_PORT }" 2>/dev/null; then
			# The table is declared by the module, so this only happens in the
			# window where a rebuild has the ruleset torn down. The next tick
			# closes it.
			log "cannot close the port gate; the $VPN_GATE_TABLE table is not loaded"
		fi
		;;
	esac
}

# ---------------------------------------------------------------- ddns

ddns_configured() {
	[ -n "$VPN_DNS_ZONE" ] && [ -n "$VPN_DNS_KEY_FILE" ] && [ -r "$VPN_DNS_KEY_FILE" ]
}

# The key goes in a curl config file rather than on the command line, where it
# would be readable by anyone who can list /proc while the request is in flight.
ensure_api_config() {
	local rc="$RUNDIR/curlrc"
	if [ ! -s "$rc" ]; then
		(
			umask 077
			printf 'header = "Authorization: Bearer %s"\n' "$(cat "$VPN_DNS_KEY_FILE")" >"$rc"
		)
	fi
	echo "$rc"
}

# api METHOD PATH [BODY] — leaves the status in API_STATUS and the response body
# in $RUNDIR/api.body. Neither is returned on stdout: a caller that needed both
# would have to run this in a command substitution, and the subshell would take
# the status assignment with it.
#
# Never fails the script on an HTTP error. Every caller decides for itself what
# a given status means, and for the delete path a 404 is a success.
api() {
	local method="$1" path="$2" body="${3:-}"
	local rc
	rc=$(ensure_api_config)
	local args=(
		--silent --show-error --max-time 20
		--config "$rc"
		--request "$method"
		--header "Content-Type: application/json"
		--output "$RUNDIR/api.body"
		--write-out '%{http_code}'
		"https://api.vultr.com/v2$path"
	)
	if [ -n "$body" ]; then
		args+=(--data "$body")
	fi
	if ! API_STATUS=$(curl "${args[@]}" 2>"$RUNDIR/api.err"); then
		API_STATUS="000"
		log "Vultr API $method $path failed: $(tr -d '\n' <"$RUNDIR/api.err")"
		return 0
	fi
	case "$API_STATUS" in
	2* | 404) ;;
	*)
		# The status alone is not diagnosable — a 401 is "wrong key" and
		# "your address is not on the API's allow list" alike, and those have
		# nothing in common to do about them. The body says which. Logged here
		# so the journal answers it, and lifted into the report by api_error so
		# the web page does too.
		log "Vultr API $method $path -> $API_STATUS: $(api_error)"
		;;
	esac
}

api_body() {
	cat "$RUNDIR/api.body" 2>/dev/null || true
}

# The reason out of an error response, as one line of plain text. Truncated
# because it is remote-controlled text on its way into a journal and a web page,
# and empty rather than noisy when the body is not the JSON we expect. It never
# carries the API key: this is the response, not the request.
api_error() {
	local reason
	reason=$(api_body | jq -r 'if type == "object" then (.error // "") else "" end' 2>/dev/null || true)
	if [ -z "$reason" ]; then
		reason=$(api_body | tr -d '\n')
	fi
	printf '%.200s' "$reason"
}

random_label() {
	# A fixed block filtered down, rather than /dev/urandom piped into head:
	# closing that pipe kills the reader with SIGPIPE, which pipefail turns
	# into a failed script. 512 bytes yields around 70 usable characters.
	local raw
	raw=$(head -c 512 /dev/urandom | LC_ALL=C tr -dc 'a-z0-9')
	[ "${#raw}" -ge "$VPN_DNS_LABEL_LENGTH" ] ||
		die "not enough entropy for a $VPN_DNS_LABEL_LENGTH character label"
	echo "${raw:0:VPN_DNS_LABEL_LENGTH}"
}

# The address the record should point at: the PPP interface's own IPv4. Taken
# with awk rather than a pipeline ending in head, for the SIGPIPE reason above.
public_address() {
	ip -4 -o address show dev "$VPN_PPP_IFACE" 2>/dev/null |
		awk 'NR == 1 { split($4, parts, "/"); print parts[1] }'
}

# Inbound anything is impossible behind carrier NAT, and a public record
# pointing at an address that is not ours is worse than no record. Reported
# rather than fatal: the tunnel is still up, and still reachable by whatever
# address the line does have.
is_globally_routable() {
	case "$1" in
	'' | 0.* | 10.* | 127.* | 169.254.* | 192.168.*) return 1 ;;
	# 100.64.0.0/10, carrier-grade NAT.
	100.6[4-9].* | 100.[7-9][0-9].* | 100.1[01][0-9].* | 100.12[0-7].*) return 1 ;;
	# 172.16.0.0/12.
	172.1[6-9].* | 172.2[0-9].* | 172.3[01].*) return 1 ;;
	esac
	return 0
}

# Finds the record for our label when observed.json has no id for it — after a
# lost state file, or a create whose response never arrived. Without this the
# next pass would add a second record for the same name.
#
# `first(...)` rather than a pipeline into head, so jq is never killed part way
# through writing.
ddns_find_record() {
	api GET "/domains/$VPN_DNS_ZONE/records?per_page=500"
	[ "$API_STATUS" = "200" ] || return 0
	api_body | jq -r --arg name "$LABEL" \
		'first(.records[]? | select(.type == "A" and .name == $name) | .id) // ""'
}

# Points the ephemeral name at the current address, creating it on the first
# pass after the switch goes on.
ddns_sync() {
	NOTE=""

	# Recorded before anything to do with the zone, and whether or not there is
	# one. This is the address a client dials, so it is what the page falls back
	# to when there is no name — on a router configured without a zone that is
	# the only endpoint there will ever be, and on one whose zone is refusing
	# requests it is the difference between a page that can still be acted on
	# and a page full of em dashes.
	local addr
	addr=$(public_address)
	if is_globally_routable "$addr"; then
		PUBLIC_ADDR="$addr"
	fi

	if ! ddns_configured; then
		return 0
	fi

	LABEL=$(observed_field label)
	RECORD_ID=$(observed_field recordId)
	if [ -z "$LABEL" ]; then
		# A fresh name each time the tunnel is switched on, which is the point
		# of an ephemeral record: the previous one was deleted on disable and
		# is not coming back.
		LABEL=$(random_label)
		RECORD_ID=""
		log "ephemeral name for this session: $LABEL.$VPN_DNS_ZONE"
	fi
	# FQDN is set by the branches below, on success only, and never here.
	#
	# It was set at this point once, and that is a claim the page then makes on
	# this script's behalf: the endpoint to point a client at. When the zone
	# refused the record, the page went on offering a name that had never been
	# created — which resolves to whatever a wildcard in the zone says, and
	# reads as the tunnel being broken rather than the record being missing.
	# A name is reported when it exists, or not at all.
	FQDN=""

	if ! is_globally_routable "$addr"; then
		NOTE="the PPP interface has no globally routable IPv4 (${addr:-none}), so the name was not updated; the tunnel cannot be reached from the internet through it"
		log "$NOTE"
		return 0
	fi

	local patch
	patch=$(jq -nc --arg data "$addr" --argjson ttl "$VPN_DNS_TTL" '{data: $data, ttl: $ttl}')

	if [ -n "$RECORD_ID" ]; then
		api PATCH "/domains/$VPN_DNS_ZONE/records/$RECORD_ID" "$patch"
		case "$API_STATUS" in
		2*)
			FQDN="$LABEL.$VPN_DNS_ZONE"
			return 0
			;;
		404)
			# Deleted behind our back. Fall through to a fresh create rather
			# than reporting a name that resolves to nothing.
			log "record $RECORD_ID is gone from the zone; recreating"
			RECORD_ID=""
			;;
		*)
			NOTE="cannot update $LABEL.$VPN_DNS_ZONE — Vultr answered $API_STATUS: $(api_error). The name may still point at an old address."
			log "$NOTE"
			return 0
			;;
		esac
	fi

	RECORD_ID=$(ddns_find_record)
	if [ -n "$RECORD_ID" ]; then
		# Adopted rather than duplicated.
		api PATCH "/domains/$VPN_DNS_ZONE/records/$RECORD_ID" "$patch"
		if [[ "$API_STATUS" == 2* ]]; then
			FQDN="$LABEL.$VPN_DNS_ZONE"
			log "adopted the existing record for $FQDN"
			return 0
		fi
		RECORD_ID=""
	fi

	api POST "/domains/$VPN_DNS_ZONE/records" \
		"$(jq -nc --arg name "$LABEL" --arg data "$addr" --argjson ttl "$VPN_DNS_TTL" \
			'{name: $name, type: "A", data: $data, ttl: $ttl}')"
	case "$API_STATUS" in
	2*)
		RECORD_ID=$(api_body | jq -r '.record.id // ""')
		FQDN="$LABEL.$VPN_DNS_ZONE"
		log "published $FQDN -> $addr"
		;;
	*)
		NOTE="cannot create $LABEL.$VPN_DNS_ZONE — Vultr answered $API_STATUS: $(api_error). The tunnel is up but has no name; reach it at ${addr}:${VPN_PORT} meanwhile."
		log "$NOTE"
		;;
	esac
}

# Deleting is the half that must not be skipped: a record left behind points a
# name in a public zone at this line for as long as nobody notices. If it fails
# the id is kept, and every later pass retries it — which is why "off" is
# reconciled repeatedly rather than once.
ddns_delete() {
	LABEL=$(observed_field label)
	RECORD_ID=$(observed_field recordId)
	FQDN=""
	PUBLIC_ADDR=""
	NOTE=""

	if [ -z "$RECORD_ID" ] || ! ddns_configured; then
		LABEL=""
		RECORD_ID=""
		return 0
	fi

	api DELETE "/domains/$VPN_DNS_ZONE/records/$RECORD_ID"
	case "$API_STATUS" in
	# 404 counts as done: the record is not there, which is the whole request.
	2* | 404)
		log "removed $LABEL.$VPN_DNS_ZONE from the zone"
		LABEL=""
		RECORD_ID=""
		;;
	*)
		FQDN="$LABEL.$VPN_DNS_ZONE"
		NOTE="cannot delete $FQDN — Vultr answered $API_STATUS: $(api_error). It still points at this line and will be retried."
		log "$NOTE"
		;;
	esac
}

# ---------------------------------------------------------------- reconcile

bring_up() {
	ensure_key
	ensure_link
	sync_peers
	# After the interface is listening, so the first packet through the opened
	# port has something to answer it.
	gate open
	ddns_sync
	write_observed true
}

tear_down() {
	# Before the interface goes, so a failure here is retried while the tunnel
	# is still the thing that is known to be on.
	ddns_delete
	gate close
	if ip link show "$VPN_IFACE" >/dev/null 2>&1; then
		ip link del "$VPN_IFACE"
	fi
	PEER_COUNT=0
	write_observed false
}

apply() {
	need_root
	ensure_rundir
	trap report_failure ERR

	# Before the lock, which lives in the directory this creates.
	ensure_state_dir

	# The timer, the path unit and a person at the keyboard can all land here at
	# once. Serialised rather than raced: two passes creating the same DNS
	# record is the failure this prevents.
	exec 9>"$LOCK"
	flock -w 30 9 || die "another reconcile is running"

	if [ "$(read_desired)" = "on" ]; then
		bring_up
	else
		tear_down
	fi
}

switch_to() {
	need_root
	# Rewritten in place, never renamed: the path unit watches this file for a
	# close-after-write, and a rename would arrive as a directory event it does
	# not see. router-web writes it the same way for the same reason.
	printf '%s\n' "$1" >"$DESIRED"
	apply
}

status() {
	# read_desired answers "off" for a file it cannot read, which is the right
	# answer for the reconciler — it fails towards the closed port — and the
	# wrong one to show a person, who would read it as a tunnel that is down.
	# Both files are group-readable and the group is router-web's, not a
	# human's, so this is the normal case for someone at the keyboard.
	if [ -e "$DESIRED" ] && [ ! -r "$DESIRED" ]; then
		die "cannot read the switch — run this as root"
	fi
	echo "switch:   $(read_desired)"
	if [ -e "$OBSERVED" ] && [ ! -r "$OBSERVED" ]; then
		die "cannot read the report — run this as root"
	fi
	if [ -r "$OBSERVED" ]; then
		jq . "$OBSERVED"
	else
		echo "observed: nothing recorded yet"
	fi
}

main() {
	case "${1:-}" in
	on) switch_to on ;;
	off) switch_to off ;;
	apply) apply ;;
	status) status ;;
	-h | --help | help) usage 0 ;;
	*) usage 1 ;;
	esac
}

main "$@"
