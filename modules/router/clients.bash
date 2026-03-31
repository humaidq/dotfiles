#!/usr/bin/env bash
set -euo pipefail

LEASE_FILE="${LEASE_FILE:-/var/lib/misc/dnsmasq.leases}"

if ! command -v ip >/dev/null 2>&1; then
  echo "error: 'ip' command not found" >&2
  exit 1
fi

if [[ ! -f "$LEASE_FILE" ]]; then
  echo "warning: lease file not found at $LEASE_FILE" >&2
fi

tmp_leases="$(mktemp)"
tmp_neigh="$(mktemp)"
trap 'rm -f "$tmp_leases" "$tmp_neigh"' EXIT

# Read dnsmasq leases into: IP -> hostname, MAC
if [[ -f "$LEASE_FILE" ]]; then
  awk '
    NF >= 4 {
      expiry = $1
      mac    = $2
      ip     = $3
      host   = $4

      if (host == "*") host = "-"
      print ip "\t" host "\t" mac
    }
  ' "$LEASE_FILE" | sort -u >"$tmp_leases"
else
  : >"$tmp_leases"
fi

# Read neighbour table
# Example shapes:
# 192.168.1.10 dev br0 lladdr aa:bb:cc:dd:ee:ff REACHABLE
# 192.168.1.20 dev br0 INCOMPLETE
ip neigh | awk '
  {
    ip = $1
    dev = "-"
    mac = "-"
    state = $NF

    for (i = 1; i <= NF; i++) {
      if ($i == "dev" && (i + 1) <= NF) {
        dev = $(i + 1)
      }
      if ($i == "lladdr" && (i + 1) <= NF) {
        mac = $(i + 1)
      }
    }

    print ip "\t" dev "\t" mac "\t" state
  }
' | sort -u >"$tmp_neigh"

awk -F '\t' '
  BEGIN {
    OFS = "\t"
  }

  FNR == NR {
    lease_host[$1] = $2
    lease_mac[$1]  = $3
    next
  }

  {
    ip    = $1
    dev   = $2
    nmac  = $3
    state = $4

    host = (ip in lease_host ? lease_host[ip] : "-")
    mac  = nmac

    if (mac == "-" && (ip in lease_mac)) {
      mac = lease_mac[ip]
    }

    source = "neigh"
    if ((ip in lease_host) && host != "-") {
      source = "neigh+lease"
    } else if (ip in lease_mac) {
      source = "neigh+lease"
    }

    print ip, host, mac, dev, state, source
  }
' "$tmp_leases" "$tmp_neigh" | sort -V | awk -F '\t' '
  BEGIN {
    printf "%-39s  %-30s  %-17s  %-10s  %-12s  %-12s\n", "IP", "HOSTNAME", "MAC", "INTERFACE", "STATE", "SOURCE"
    printf "%-39s  %-30s  %-17s  %-10s  %-12s  %-12s\n", \
      "---------------------------------------", \
      "------------------------------", \
      "-----------------", \
      "----------", \
      "------------", \
      "------------"
  }
  {
    printf "%-39s  %-30s  %-17s  %-10s  %-12s  %-12s\n", $1, $2, $3, $4, $5, $6
  }
'

# Show lease-only entries that are not currently in neighbour table
awk -F '\t' '
  FNR == NR {
    seen[$1] = 1
    next
  }
  !($1 in seen) {
    print $1 "\t" $2 "\t" $3 "\t-\tLEASE_ONLY\tlease-only"
  }
' "$tmp_neigh" "$tmp_leases" | awk -F '\t' '
  BEGIN {
    printed = 0
  }
  {
    if (!printed) {
      print ""
      printf "%-39s  %-30s  %-17s  %-10s  %-12s  %-12s\n", "IP", "HOSTNAME", "MAC", "INTERFACE", "STATE", "SOURCE"
      printf "%-39s  %-30s  %-17s  %-10s  %-12s  %-12s\n", \
        "---------------------------------------", \
        "------------------------------", \
        "-----------------", \
        "----------", \
        "------------", \
        "------------"
      printed = 1
    }
    printf "%-39s  %-30s  %-17s  %-10s  %-12s  %-12s\n", $1, $2, $3, $4, $5, $6
  }
'
