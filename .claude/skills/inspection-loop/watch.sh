#!/usr/bin/env bash
# watch — repeated quick scans, reporting only peers that dominate *persistently*.
#
# Usage: watch.sh <bongo|bingo> [scans] [secs-per-scan] [min-streak]
#
# A single short scan is a bad detector: in eight seconds a phone loading one
# video is 100% dominated by a CDN, so share alone flags Google, Meta, Akamai
# and TikTok every time. What separates a tunnel is that it dominates the *next*
# scan too, and the one after. This runs back-to-back scans and reports a
# (client, peer) pair only once it has been top for min-streak consecutive
# scans — roughly 25 seconds at the defaults, against two minutes for a full
# round, with far less noise than one short scan.
#
# It still decides nothing. Confirm a candidate with whois and the resolver log
# before blocking; see SKILL.md.
set -u

site=${1:?usage: watch.sh <bongo|bingo> [scans] [secs] [min-streak] [client ...]}
scans=${2:-12}
secs=${3:-8}
need=${4:-3}
if [ $# -ge 4 ]; then shift 4; else shift $#; fi
# Scoping to devices already known to tunnel is what makes a short window
# trustworthy. Unscoped, an eight-second scan flags whichever phone happens to
# be loading a video; on a device that tunnels, a persistent unexplained peer is
# almost always the node.
targets=("$@")
here=$(dirname "$0")
case $site in
  bongo) sshhost=bongo ;;
  bingo) sshhost=humaid@10.10.0.18 ;;
  *) echo "unknown site: $site" >&2; exit 1 ;;
esac

declare -A streak prev
for _ in $(seq 1 "$scans"); do
  out=$("$here/quickscan.sh" "$site" "$secs" "${targets[@]}") || { echo "scan failed" >&2; exit 1; }
  seen=""
  while read -r client _bytes kbit share peer port state; do
    [ "$client" = CLIENT ] && continue
    [ -z "${peer:-}" ] && continue
    key="$client $peer"
    seen="$seen|$key|"
    streak[$key]=$(( ${streak[$key]:-0} + 1 ))
    prev[$key]="$share $port $state $kbit"
    if [ "${streak[$key]}" -eq "$need" ]; then
      # Persistence alone does not separate a tunnel from someone watching a
      # long video — both dominate every scan. Confirm the moment a pair
      # qualifies, which costs a whois and one journal grep and only ever runs
      # for candidates.
      net=$(whois "$peer" 2>/dev/null \
            | grep -iE '^(netname|orgname|org-name|descr)' \
            | grep -viE 'certificate|^descr: *-----|[A-Za-z0-9+/]{40,}' | head -2 \
            | tr -s ' ' | cut -d: -f2- | tr -d '\n' | cut -c1-52)
      dns=$(ssh -n -S "/tmp/claude-1000/$site.sock" "$sshhost" \
            "journalctl -u blocky --no-pager --since '30 min ago' | grep -F '$peer' | head -1" 2>/dev/null)
      echo "PERSISTENT  $client -> $peer port $port  share=$share ${kbit}kbit/s  $state"
      echo "            whois:$net"
      echo "            $([ -n "$dns" ] && echo "resolver explains it — likely CDN/app content" \
                                       || echo "NO resolver line — candidate node")"
    fi
  done <<<"$out"
  # a pair that stopped being top loses its streak; only unbroken runs count
  for k in "${!streak[@]}"; do
    case "$seen" in *"|$k|"*) ;; *) unset "streak[$k]" ;; esac
  done
done

echo "--- end of watch: pairs still streaking ---"
for k in "${!streak[@]}"; do
  [ "${streak[$k]}" -ge "$need" ] && echo "  $k  ${prev[$k]}  streak=${streak[$k]}"
done
