#!/usr/bin/env bash
# Print the hosts contacted in a packet capture.
#
#   pcap-domains.sh <capture.pcap>
#
# Needs tshark:
#   nix shell nixpkgs#wireshark-cli
#
# Bare hostnames on stdout for check-domains.sh; an annotated table on stderr
# showing how each one was seen:
#
#   SNI    the app opened a TLS connection here — the strongest signal there is
#   DNS    looked up but never connected: a backup pool member, or blocked
#   HTTP   cleartext Host header, frequently the rotation or config service
#   IP     connected to an address no DNS answer mentioned — a hardcoded
#          resolver or origin, invisible to every other method
#
# Zones on the shared noise list are annotated, never dropped. An app's escape
# hatches live in exactly those zones.
set -euo pipefail

cap="${1:?usage: pcap-domains.sh <capture.pcap>}"
# The list is an alternation of brand substrings, so it must only match at a
# label boundary. Unanchored, live.com matched connect-social-live.com and
# tagged Chatta's live backend as Microsoft — the operator's own zone,
# presented to the reader as somebody else's noise.
noise="(^|\.)($(cat "$(dirname "$0")/noise-zones.txt"))"

# tshark emits comma-separated values when a packet carries several; split
# them, drop reverse-lookup and link-local chatter, and normalise case.
fields() {
	tshark -r "$cap" -Y "$1" -T fields -e "$2" 2>/dev/null |
		tr ',' '\n' | tr -d '\r' | sed 's/:[0-9]*$//' |
		tr '[:upper:]' '[:lower:]' | grep -E '\.[a-z]{2,}$' |
		grep -vE '\.(arpa|local|localdomain)$' | sort -u || true
}

sni="$(fields 'tls.handshake.extensions_server_name' 'tls.handshake.extensions_server_name')"
dns="$(fields 'dns.flags.response == 0' 'dns.qry.name')"
http="$(fields 'http.request' 'http.host')"

# Addresses we opened a connection to, minus every address DNS told us about.
# 10.0.2.0/24 is the emulator's own gateway and resolver.
addrs() {
	tshark -r "$cap" -Y "$1" -T fields -e "$2" 2>/dev/null |
		tr ',' '\n' | tr -d '\r' | grep . |
		grep -vE '^(10\.0\.2\.|127\.|169\.254\.|22[4-9]\.|23[0-9]\.|255\.|0\.0\.0\.0$|fe80:|ff[0-9a-f]{2}:)' |
		sort -u || true
}
dialled="$(
	{
		addrs 'tcp.flags.syn==1 && tcp.flags.ack==0' 'ip.dst'
		addrs 'tcp.flags.syn==1 && tcp.flags.ack==0' 'ipv6.dst'
		addrs 'udp.dstport==443' 'ip.dst'
		addrs 'udp.dstport==443' 'ipv6.dst'
	} | sort -u
)"
resolved="$(
	{
		addrs 'dns.flags.response==1' 'dns.a'
		addrs 'dns.flags.response==1' 'dns.aaaa'
	} | sort -u
)"
dark="$(comm -23 <(echo "$dialled") <(echo "$resolved") | grep . || true)"

names="$(printf '%s\n%s\n%s\n' "$sni" "$dns" "$http" | grep . | sort -u || true)"

if [ -z "$names" ] && [ -z "$dark" ]; then
	echo "ERROR: $cap contains no contacted hosts at all." >&2
	echo "       That is a broken capture path, not a quiet app." >&2
	exit 1
fi

while IFS= read -r h; do
	[ -n "$h" ] || continue
	tag=""
	grep -qxF "$h" <<<"$sni" && tag="${tag}SNI+"
	grep -qxF "$h" <<<"$dns" && tag="${tag}DNS+"
	grep -qxF "$h" <<<"$http" && tag="${tag}HTTP+"
	note=""
	if grep -qiE "$noise" <<<"$h"; then
		note="[noise]"
	fi
	printf '%-12s %-45s %s\n' "${tag%+}" "$h" "$note" >&2
	echo "$h"
done <<<"$names"

# Addresses, not names — check-domains.sh cannot classify these, so they are
# reported for the reader only.
while IFS= read -r a; do
	[ -n "$a" ] || continue
	printf '%-12s %-45s %s\n' "IP" "$a" "[no DNS — hardcoded]" >&2
done <<<"$dark"
