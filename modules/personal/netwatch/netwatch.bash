#!/usr/bin/env bash
# Sample traffic for the watched devices, analyse it locally, append a report.
#
# Requires an SSH ControlMaster to the router to already exist. This script
# never creates one: the router key lives on a hardware token, an unattended
# run cannot produce a tap, and a script that silently prompts would hang a
# timer forever. Open one first, and leave it:
#
#   ssh -M -o ControlMaster=yes -o ControlPersist=168h -fN <router>
set -euo pipefail

NETWATCH_DIR="${NETWATCH_DIR:-$PWD/netwatch}"
NETWATCH_HOST="${NETWATCH_HOST:?set NETWATCH_HOST to the router ssh alias}"
NETWATCH_IFACE="${NETWATCH_IFACE:-enp2s0}"
NETWATCH_SECS="${NETWATCH_SECS:-300}"
NETWATCH_KEEP_PCAP_DAYS="${NETWATCH_KEEP_PCAP_DAYS:-3}"
NETWATCH_KEEP_ROWS_DAYS="${NETWATCH_KEEP_ROWS_DAYS:-120}"

devices="$NETWATCH_DIR/devices.conf"
reports="$NETWATCH_DIR/reports"
pcaps="$NETWATCH_DIR/pcaps"
db="$NETWATCH_DIR/store.db"
run_ts="$(date +%s)"
report_file="$reports/$(date +%Y-%m-%d).txt"

mkdir -p "$reports" "$pcaps"
chmod 700 "$NETWATCH_DIR" "$reports" "$pcaps"

skip() {
	printf 'netwatch: %s\n' "$1" >&2
	printf '{"run_ts":%s,"captured":false,"skip_reason":"%s","devices":[]}\n' \
		"$run_ts" "$1" > "$NETWATCH_DIR/observations.json"
	store "$db" "$NETWATCH_DIR/observations.json" \
		"$(( run_ts - NETWATCH_KEEP_ROWS_DAYS * 86400 ))"
	report "$NETWATCH_DIR/observations.json" "$report_file"
	exit 1
}

# Captures hold other people's traffic in the clear; the derived rows do not.
# Runs on every exit path — including every skip — so a broken run (a lapsed
# SSH master is the expected steady state of "broken") cannot let full-payload
# captures accumulate on the laptop just because it never reached the end.
prune_pcaps() {
	find "$pcaps" -name '*.pcap' -mtime "+$NETWATCH_KEEP_PCAP_DAYS" -delete
}
trap prune_pcaps EXIT

[[ -r "$devices" ]] || skip "no devices.conf"

# Never open a master — only ever use one that already exists.
ssh -O check "$NETWATCH_HOST" >/dev/null 2>&1 || skip "no ssh socket"

# Build the capture filter from the watchlist. The `|| [[ -n ... ]]` clause
# keeps the last MAC when devices.conf has no trailing newline: without it,
# `read` discards an unterminated final line, so that device is silently
# dropped from the capture filter while analyse (which reads the same file in
# Python) still lists it in the report, as "0 bytes across 0 peers" — reading
# as "nothing found" when it actually means "never captured".
filter=""
while read -r mac _rest || [[ -n "${mac:-}" ]]; do
	[[ -z "$mac" || "$mac" == \#* ]] && continue
	filter="${filter:+$filter or }ether host $mac"
done < "$devices"
[[ -n "$filter" ]] || skip "devices.conf lists no MACs"

remote_pcap="/tmp/netwatch-$run_ts.pcap"
local_pcap="$pcaps/$run_ts.pcap"

# -s 0 because a truncated capture loses the ClientHello, and a capture cannot
# be re-run retroactively. -G/-W so tcpdump exits by itself: sudo is scoped to
# tcpdump and cannot signal the root process it started.
# Variables are deliberately expanded client-side (shellcheck SC2029): the
# surrounding single quotes are literal characters meant for the remote
# shell, protecting the interpolated values as one token each once there.
# Kept on one physical line, deliberately: a backslash-newline used to wrap
# this would land inside one of those single-quoted segments, where single
# quotes suppress line-continuation and the literal backslash+newline would
# ride along into the capture filter sent to the router.
ssh "$NETWATCH_HOST" \
	'sudo -n tcpdump -i '\'"$NETWATCH_IFACE"\'' -s 0 -G '\'"$NETWATCH_SECS"\'' -W 1 -w '\'"$remote_pcap"\'' '\'"($filter) and not port 53"\' \
	>/dev/null 2>&1 || skip "capture failed"

# The router is always-on and /tmp is not this script's to leave a
# full-payload capture sitting in, whether or not the fetch succeeded.
rm_remote_pcap() {
	ssh "$NETWATCH_HOST" 'rm -f '\'"$remote_pcap"\' || true
}

if ! scp -q "$NETWATCH_HOST:$remote_pcap" "$local_pcap"; then
	rm_remote_pcap
	skip "fetch failed"
fi
rm_remote_pcap
chmod 600 "$local_pcap"

# The lease file is world-readable on the router, no sudo needed. Without it,
# seed has nothing to map an address back to a MAC with and every run dies at
# the resolver-import step below.
scp -q "$NETWATCH_HOST:/var/lib/dnsmasq/dnsmasq.leases" \
	"$NETWATCH_DIR/leases" || skip "lease fetch failed"

# Refresh the DNS indexes from the router's resolver history. dnsmap.tsv and
# baseline.tsv are unioned by seed, not replaced: baseline.tsv is passed again
# as the existing baseline to merge into baseline.tsv.new, so a domain does
# not vanish from the baseline (and reappear as a fabricated "first time ever
# seen" novelty finding) just because its query line rotated out of the
# journal.
ssh "$NETWATCH_HOST" 'journalctl -u blocky --no-pager' 2>/dev/null \
	| seed "$NETWATCH_DIR/leases" \
		"$NETWATCH_DIR/dnsmap.tsv" \
		"$NETWATCH_DIR/dnsq.tsv" \
		"$NETWATCH_DIR/baseline.tsv.new" \
		"$NETWATCH_DIR/baseline.tsv" \
	|| skip "resolver history import failed"

tshark -r "$local_pcap" -T fields \
	-e frame.time_epoch -e eth.src -e eth.dst -e ip.src -e ip.dst \
	-e ip.proto -e tcp.srcport -e tcp.dstport -e udp.srcport \
	-e udp.dstport -e frame.len \
	-e tls.handshake.extensions_server_name \
	> "$NETWATCH_DIR/flows.tsv" 2>/dev/null || skip "tshark failed"

analyse "$NETWATCH_DIR/flows.tsv" "$NETWATCH_DIR/dnsmap.tsv" \
	"$NETWATCH_DIR/dnsq.tsv" "$devices" "$NETWATCH_DIR/baseline.tsv" \
	"$run_ts" > "$NETWATCH_DIR/observations.json"

store "$db" "$NETWATCH_DIR/observations.json" \
	"$(( run_ts - NETWATCH_KEEP_ROWS_DAYS * 86400 ))"
report "$NETWATCH_DIR/observations.json" "$report_file"

# Best-effort: a probe failure must never cost the run its report.
certcheck "$NETWATCH_DIR/observations.json" "$report_file" || true

# The new baseline becomes the comparison point only after this run has been
# analysed against the old one, or nothing would ever look new.
mv -f "$NETWATCH_DIR/baseline.tsv.new" "$NETWATCH_DIR/baseline.tsv"

printf 'netwatch: report appended to %s\n' "$report_file" >&2
