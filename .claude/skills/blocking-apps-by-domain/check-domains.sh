#!/usr/bin/env bash
# Classify hostnames against the router's resolver so you only add real ones.
#
#   check-domains.sh example.com other.com
#   apk-domains.sh com.some.app | check-domains.sh
#   check-domains.sh -s 10.10.0.16 example.com     # query bongo over Nebula
#
# BLOCKED        already answered with 0.0.0.0 (blocky blockType = zeroIp)
# LIVE           resolves; a real target
# NXDOMAIN       nothing there now — a wildcard still covers it if the operator
#                brings it back, but check the apex before assuming it is dead
set -euo pipefail

server="10.20.0.1"
if [ "${1:-}" = "-s" ]; then
	server="${2:?usage: check-domains.sh [-s resolver] <host>...}"
	shift 2
fi

names=("$@")
if [ ${#names[@]} -eq 0 ]; then
	mapfile -t names
fi

for n in "${names[@]}"; do
	[ -n "$n" ] || continue
	last=$(dig +short +time=3 +tries=1 "@$server" "$n" | tail -1)
	case "$last" in
	0.0.0.0) state="BLOCKED" ;;
	"") state="NXDOMAIN" ;;
	*) state="LIVE      $last" ;;
	esac
	printf '%-40s %s\n' "$n" "$state"
done
