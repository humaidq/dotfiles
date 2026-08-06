#!/usr/bin/env bash
# quickscan — find the peer carrying a device's traffic in seconds, not minutes.
#
# Usage: quickscan.sh <bongo|bingo> [seconds] [client ...]
#
# A full inspection round writes a pcap, copies it back and runs tshark: over
# two minutes. This streams the capture over the existing ssh socket straight
# into a local tshark, so nothing is written or copied, and an 8-second sample
# is enough to see which peer is carrying a device — a tunnel at even 1 Mbps is
# unmistakable that fast.
#
# Two things this deliberately does NOT do, both of which the full round is for:
# it truncates at a small snaplen, so there is no SNI or payload here, and it
# reports only byte ranking. Do not use it as the evidence for a block on its
# own; use it to find *where to look*, then confirm.
#
# `sudo -n timeout ... tcpdump` does not work: the sudoers rule grants tcpdump
# itself, not timeout, and the wrapper is silently denied — which looks exactly
# like an idle network. tcpdump self-terminates with -G/-W instead.
set -u

site=${1:?usage: quickscan.sh <bongo|bingo> [secs] [client ...]}
secs=${2:-8}
if [ $# -ge 2 ]; then shift 2; else shift 1; fi

case $site in
  bongo) HOST=bongo;             NET=10.20. ;;
  bingo) HOST=humaid@10.10.0.18; NET=192.168.50. ;;
  *) echo "unknown site: $site" >&2; exit 1 ;;
esac
SOCK=/tmp/claude-1000/$site.sock

ssh -S "$SOCK" -O check "$HOST" >/dev/null 2>&1 || {
  echo "no ControlMaster for $HOST — open one first" >&2; exit 1; }

filt="not port 53"
if [ $# -gt 0 ]; then
  h=""; for c in "$@"; do h="${h:+$h or }host $c"; done
  filt="$filt and ($h)"
fi

blocked=$(ssh -n -S "$SOCK" "$HOST" 'tempblock list' 2>/dev/null \
          | awk '{print $1}' | grep -E '^[0-9]' | sort -u)

ssh -n -S "$SOCK" "$HOST" \
    "sudo -n tcpdump -i enp2s0 -nn -s 128 -G $secs -W 1 -w - '$filt' 2>/dev/null" \
| tshark -r - -T fields -E separator=/t \
    -e ip.src -e ip.dst -e ip.len -e tcp.dstport -e udp.dstport 2>/dev/null \
| awk -F'\t' -v net="$NET" -v secs="$secs" -v blocked="$blocked" '
    BEGIN { n=split(blocked,b,"\n"); for(i=1;i<=n;i++) bl[b[i]]=1 }
    {
      if (index($1,net)==1)      { c=$1; p=$2; pt=$4$5 }
      else if (index($2,net)==1) { c=$2; p=$1; pt="" }
      else next
      if (index(p,net)==1 || p ~ /^(224|239|255)\./) next
      tot[c]+=$3; pb[c" "p]+=$3; if (pt!="") port[c" "p]=pt
    }
    END {
      for (k in pb) { split(k,x," ");
        if (pb[k]>m[x[1]]) { m[x[1]]=pb[k]; tp[x[1]]=x[2]; tpt[x[1]]=port[k] } }
      printf "%-16s %10s %8s %6s  %-16s %-8s %s\n", \
             "CLIENT","BYTES","kbit/s","SHARE","TOP PEER","PORT","STATE"
      for (c in tot) {
        if (tot[c] < 10000) continue
        printf "%-16s %10d %8.0f %5.1f%%  %-16s %-8s %s\n", \
          c, tot[c], m[c]*8/1000/secs, 100*m[c]/tot[c], tp[c], tpt[c], \
          (tp[c] in bl ? "already-blocked" : "NEW")
      }
    }' | { read -r hdr; echo "$hdr"; sort -k2 -rn; }
