#!/usr/bin/env bash
set -euo pipefail

LEASE_FILE="${LEASE_FILE:-/var/lib/dnsmasq/dnsmasq.leases}"
HOSTS_FILE="${HOSTS_FILE:-}"

if ! command -v ip >/dev/null 2>&1; then
  echo "error: 'ip' command not found" >&2
  exit 1
fi

if [[ ! -f "$LEASE_FILE" ]]; then
  echo "warning: lease file not found at $LEASE_FILE" >&2
fi

tmp_leases="$(mktemp)"
tmp_neigh="$(mktemp)"
tmp_hosts="$(mktemp)"
trap 'rm -f "$tmp_leases" "$tmp_neigh" "$tmp_hosts"' EXIT

# Read dnsmasq reservations into: MAC -> IP, hostname. Reservation names take
# precedence over hostnames supplied by clients in their DHCP requests.
if [[ -n "$HOSTS_FILE" && -r "$HOSTS_FILE" ]]; then
  awk -F ',' '
    /^[[:space:]]*(#|$)/ { next }
    NF >= 3 {
      mac  = tolower($1)
      ip   = $2
      host = $3

      gsub(/^[[:space:]]+|[[:space:]]+$/, "", mac)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", ip)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", host)

      if (mac ~ /^([0-9a-f]{2}:){5}[0-9a-f]{2}$/ && ip != "" && host != "") {
        print mac "\t" ip "\t" host
      }
    }
  ' "$HOSTS_FILE" >"$tmp_hosts"
else
  : >"$tmp_hosts"
fi

# Read dnsmasq leases into: IP -> hostname, MAC
if [[ -f "$LEASE_FILE" ]]; then
  awk -F '\t' '
    ARGIND == 1 {
      reserved_by_mac[$1] = $3
      reserved_by_ip[$2] = $3
      next
    }
    ARGIND == 2 {
      field_count = split($0, fields, /[[:space:]]+/)
      if (field_count < 4) next
      mac  = tolower(fields[2])
      ip   = fields[3]
      host = fields[4]

      if (mac in reserved_by_mac) {
        host = reserved_by_mac[mac]
      } else if (ip in reserved_by_ip) {
        host = reserved_by_ip[ip]
      } else if (host == "*") {
        host = "-"
      }
      print ip "\t" host "\t" mac
    }
  ' "$tmp_hosts" "$LEASE_FILE" | sort -u >"$tmp_leases"
else
  : >"$tmp_leases"
fi

# Read neighbour table
# Example shapes:
# 192.168.1.10 dev br0 lladdr aa:bb:cc:dd:ee:ff REACHABLE
# 192.168.1.20 dev br0 INCOMPLETE
ip -4 neigh | awk '
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
