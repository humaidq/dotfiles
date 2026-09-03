#!/usr/bin/env bash
# hunt — watch known-tunnelling devices and cripple each node as it appears.
#
# Usage: hunt.sh <bongo|bingo> <cycles> <client> [client ...]
#
# This is the attrition tool: the point is not to catch every node but to make
# each one useless within about half a minute of coming up, so the service is
# unreliable enough to stop being worth using. It blocks without asking, which
# is only defensible because of how narrowly it is scoped:
#
#   * only the devices named on the command line — devices already established
#     to be tunnelling. An unscoped run would flag whichever phone was loading
#     a video, because over eight seconds that looks identical.
#   * only a peer that stays top across consecutive scans. One scan is noise.
#   * only when the resolver has no line for the peer in the last 30 minutes.
#     Anything the device actually looked up is app content, not a hardcoded
#     node — this is the condition that spares CDN traffic.
#   * only when whois says rented hosting, never CDN or carrier space. A call
#     peer and a live-stream upload both look like a tunnel otherwise, and
#     throttling them makes a call unusable or a broadcast stall.
#
# Only tunnel endpoints belong on this path. imo/BIGO infrastructure is blocked
# by address instead, and everything else — gambling, adware, tracking — is a
# wildcard host block. See SKILL.md for which lever suits which finding.
#
# Every decision, including every skip and why, goes to the log. Read it.
set -u

site=${1:?usage: hunt.sh <bongo|bingo> <cycles> <client> [client ...]}
cycles=${2:?cycles}
shift 2
targets=("$@")
[ ${#targets[@]} -gt 0 ] || { echo "refusing to run unscoped — name the devices" >&2; exit 1; }

case $site in
  bongo) sshhost=bongo ;;
  bingo) sshhost=humaid@10.10.0.18 ;;
  *) echo "unknown site: $site" >&2; exit 1 ;;
esac
here=$(dirname "$0")
SOCK=/tmp/claude-1000/$site.sock
REPO=$(git -C "$here" rev-parse --show-toplevel)
LOG=${LOG:-/tmp/claude-1000/hunt-$site.log}

# The throttle list is a sops secret since 2026-09-03. Decrypt once into a
# working copy the membership test can grep, and re-encrypt after every append
# rather than at the end — a hunt runs for many cycles and gets interrupted,
# and losing the addresses it already took is worse than the re-encrypt cost.
LIST_ENC=$REPO/secrets/router/custom-throttle-list.txt
LIST=$(mktemp); chmod go-rwx "$LIST"
trap 'rm -f "$LIST"' EXIT
sops -d "$LIST_ENC" > "$LIST" || { echo "cannot decrypt $LIST_ENC" >&2; exit 1; }

list_add() {
  printf '%s\n' "$1" >>"$LIST"
  cp "$LIST" "$LIST_ENC"
  sops --encrypt --in-place "$LIST_ENC"
}

KEEP='GOOGLE|AKAMAI|FASTLY|CLOUDFLARE|FACEBOOK|META |AMAZON|MICROSOFT|APPLE|NETFLIX|SAMSUNG|ALIBABA|ALICLOUD|TENCENT|BYTEDANCE|BYTED|BYTEPLUS|TIKTOK|PAGODA|VOLCENGINE|CDN77|LIMELIGHT|EDGECAST|ZENLAYER|ZENLA|EMIRNET|ETISALAT|EITC|MOBILE|TELECOM|VODA|ZAIN|STC|BANGLALINK|GRAMEEN|AIRTEL'
HOSTING='DIGITALOCEAN|DO-13|OVH|HETZNER|CLOUD-FSN|CLOUD-HEL|CLOUD-NBG|IONOS|NGCS|LINODE|VULTR|CONTABO|ALTUSHOST|AH-|MELBIKOMAS|LEASEWEB|SCALEWAY|IPXO|PRIVATE CUSTOMER|CH-AH-NET|CONSTANT'

declare -A streak
for cycle in $(seq 1 "$cycles"); do
  out=$("$here/quickscan.sh" "$site" 8 "${targets[@]}") || { echo "scan failed" >>"$LOG"; sleep 2; continue; }
  seen=""
  while read -r client _b kbit share peer port state; do
    [ "$client" = CLIENT ] && continue
    [ -z "${peer:-}" ] && continue
    [ "$state" = already-handled ] && continue
    key="$client $peer"; seen="$seen|$key|"
    streak[$key]=$(( ${streak[$key]:-0} + 1 ))
    [ "${streak[$key]}" -ge 2 ] || continue

    dns=$(ssh -n -S "$SOCK" "$sshhost" \
          "journalctl -u blocky --no-pager --since '30 min ago' | grep -F '$peer' | head -1" 2>/dev/null)
    if [ -n "$dns" ]; then
      echo "cycle $cycle SKIP $client -> $peer — resolver explains it" >>"$LOG"; continue
    fi
    net=$(whois "$peer" 2>/dev/null | grep -iE '^(netname|orgname|org-name|descr)' \
          | grep -viE 'certificate|[A-Za-z0-9+/]{40,}' | head -2 | tr -s ' ' | tr -d '\n')
    if echo "$net" | grep -qiE "$KEEP"; then
      echo "cycle $cycle SKIP $client -> $peer — CDN/carrier: $net" >>"$LOG"; continue
    fi
    if ! echo "$net" | grep -qiE "$HOSTING"; then
      echo "cycle $cycle HOLD $client -> $peer — unrecognised owner, not auto-blocking: $net" >>"$LOG"; continue
    fi

    ssh -n -S "$SOCK" "$sshhost" "tempthrottle add $peer" >>"$LOG" 2>&1
    grep -qE "^${peer//./\\.}([[:space:]]|#|$)" "$LIST" || list_add "$peer"
    echo "cycle $cycle THROTTLE $client -> $peer port $port share=$share ${kbit}kbit/s  $net" >>"$LOG"
    unset "streak[$key]"
  done <<<"$out"
  for k in "${!streak[@]}"; do
    case "$seen" in *"|$k|"*) ;; *) unset "streak[$k]" ;; esac
  done
done
echo "hunt finished $cycles cycles" >>"$LOG"
