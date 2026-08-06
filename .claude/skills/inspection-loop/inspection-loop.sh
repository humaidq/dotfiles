#!/usr/bin/env bash
# inspection-loop — gather one round of evidence. Decides nothing, blocks
# nothing, writes to no tracked file. The agent running it reads the report and
# makes the call.
#
# Usage: inspection-loop.sh <bongo|bingo> [seconds]
#
# Prints a report to stdout: every LAN client ranked by bytes, its dominant
# peer, that peer's share, the port, the whois, whether the resolver explains
# the address, and any SNI seen on the flow.
set -u

site=${1:?usage: inspection-loop.sh <bongo|bingo> [secs]}
secs=${2:-120}

case $site in
  bongo) HOST=bongo;             NET=10.20. ;;
  bingo) HOST=humaid@10.10.0.18; NET=192.168.50. ;;
  *) echo "unknown site: $site" >&2; exit 1 ;;
esac
IFACE=enp2s0
SOCK=/tmp/claude-1000/$site.sock
WORK=${WORK:-/tmp/claude-1000/inspection-$site}
mkdir -p "$WORK"

ssh -S "$SOCK" -O check "$HOST" >/dev/null 2>&1 || {
  echo "no ControlMaster for $HOST — open one first (see SKILL.md)" >&2; exit 1; }

ssh -n -S "$SOCK" "$HOST" "nohup sudo -n tcpdump -i $IFACE -nn -s 0 -G $secs -W 1 \
  -w ~/.cache/inspect.pcap 'not port 53' >/dev/null 2>&1 &" >/dev/null 2>&1
sleep $((secs + 6))
scp -o ControlPath="$SOCK" "$HOST":.cache/inspect.pcap "$WORK/r.pcap" >/dev/null 2>&1
ssh -n -S "$SOCK" "$HOST" 'rm -f ~/.cache/inspect.pcap' >/dev/null 2>&1
[ -s "$WORK/r.pcap" ] || { echo "capture failed or empty" >&2; exit 1; }

ssh -n -S "$SOCK" "$HOST" 'tempblock list' 2>/dev/null | awk '{print $1}' \
  | grep -E '^[0-9]' | sort >"$WORK/blocked.txt"

# Keyed on src AND dst. Keying on the destination alone misattributes: CDN edge
# is shared, so another device's ClientHello to the same address gets reported
# as this client's, which is how a plain CDN flow can be mistaken for a fronted
# tunnel.
tshark -r "$WORK/r.pcap" -Y tls.handshake.extensions_server_name -T fields \
  -E separator=/t -e ip.src -e ip.dst -e tls.handshake.extensions_server_name 2>/dev/null \
  | sort -u >"$WORK/sni.txt"

tshark -r "$WORK/r.pcap" -T fields -E separator=/t \
  -e ip.src -e ip.dst -e ip.len -e tcp.dstport -e udp.dstport 2>/dev/null \
| awk -F'\t' -v net="$NET" '
    { if(index($1,net)==1){c=$1;p=$2;pt=$4$5} else if(index($2,net)==1){c=$2;p=$1;pt=""} else next
      if(index(p,net)==1 || p ~ /^(224|239|255)\./) next
      tot[c]+=$3; b[c" "p]+=$3; if(pt!="") po[c" "p]=pt }
    END{ for(k in b){ split(k,a," "); if(b[k]>m[a[1]]){m[a[1]]=b[k]; tp[a[1]]=a[2]; tport[a[1]]=po[k]} }
         for(c in tot) printf "%s %d %d %.1f %s %s\n", c, tot[c], m[c], 100*m[c]/tot[c], tp[c], tport[c] }' \
| sort -k2 -rn >"$WORK/rank.txt"

printf '%-16s %10s %6s  %-16s %-9s %s\n' CLIENT BYTES SHARE "TOP PEER" PORT EVIDENCE
while read -r client total topbytes share peer port; do
  [ "$total" -lt 20000 ] && continue
  [ "$topbytes" -lt 1000 ] && continue
  state=$(grep -qx "$peer" "$WORK/blocked.txt" && echo "already-blocked" || echo "")
  net=$(whois "$peer" 2>/dev/null | grep -iE '^(netname|orgname|org-name|descr)' \
        | head -2 | tr -s ' ' | cut -d: -f2- | tr -d '\n' | cut -c1-46)
  asn=$(whois "$peer" 2>/dev/null | grep -iE '^(origin|originas)' | head -1 | tr -s ' ' | cut -d: -f2-)
  sni=$(awk -F'\t' -v c="$client" -v p="$peer" '$1==c && $2==p {print $3}' \
        "$WORK/sni.txt" | paste -sd, - | cut -c1-40)
  [ -z "$sni" ] && sni_note="no-clienthello-from-this-client" || sni_note=""
  dns=$(ssh -n -S "$SOCK" "$HOST" "journalctl -u blocky --no-pager --since '10 min ago' \
        | grep -F '$peer' | head -1" 2>/dev/null)
  printf '%-16s %10d %5.1f%%  %-16s %-9s %s%s%s%s%s %s\n' \
    "$client" "$total" "$share" "$peer" "${port:-?}" \
    "${net}" "${asn:+ /$asn}" "${sni:+ sni=$sni}" "${sni_note:+ $sni_note}" \
    "$([ -n "$dns" ] && echo ' resolver-explains' || echo ' NO-DNS')" "$state"
done <"$WORK/rank.txt"

rm -f "$WORK/r.pcap"
