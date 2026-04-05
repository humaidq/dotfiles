#!/usr/bin/env bash
# Focus mode - Block distracting websites for a specified duration
# Similar to SelfControl for macOS

BLOCKLIST="@blocklist@"
WHITELIST="@whitelist@"
STATE_DIR="/var/lib/focus-mode"
ACTIVE_FLAG="$STATE_DIR/active"
BLOCKED_IPS_FILE="$STATE_DIR/blocked-ips.txt"

show_help() {
  cat <<EOF
Usage: focus <hours> | status | help

Block distracting websites for a specified duration using firewall rules.
Similar to SelfControl for macOS - blocks cannot be removed early (nuclear mode).

Commands:
    <hours>         Enable focus mode for N hours (fractional hours supported)
                    Examples: focus 1    (1 hour)
                             focus 0.5  (30 minutes)
                             focus 2.5  (2.5 hours)

    status          Show current focus mode status
    help            Show this help message

Examples:
    focus 1           # Block distracting sites for 1 hour
    focus 0.5         # Block for 30 minutes
    focus status      # Check if focus mode is active

Note: Focus mode uses firewall rules to block websites by IP address.
      Whitelisted domains keep shared IP addresses reachable.
      Once enabled, it cannot be disabled early (nuclear mode).
      Rules automatically expire after the specified duration.

      Requires sudo access for firewall modifications.

Blocked domains:
$(echo "$BLOCKLIST" | tr ' ' '\n' | sed 's/^/  - /')

Whitelisted domains:
$(if [ -n "$WHITELIST" ]; then echo "$WHITELIST" | tr ' ' '\n' | sed 's/^/  - /'; else echo "  - (none)"; fi)
EOF
}

show_status() {
  if [ ! -f "$ACTIVE_FLAG" ]; then
    echo "Focus mode is NOT active"
    return 0
  fi

  local expiry_ts
  expiry_ts=$(cat "$ACTIVE_FLAG" 2>/dev/null || echo "0")

  # Validate that expiry_ts is a valid number
  if ! [[ "$expiry_ts" =~ ^[0-9]+$ ]]; then
    echo "Focus mode state file is corrupted"
    echo "Run 'sudo rm -f $ACTIVE_FLAG' to reset"
    return 1
  fi

  local current_ts
  current_ts=$(date +%s)

  if [ "$current_ts" -ge "$expiry_ts" ]; then
    echo "Focus mode expired (cleanup pending)"
    echo "Run 'sudo systemctl start focus-mode-cleanup' to clean up manually"
    return 0
  fi

  local remaining=$((expiry_ts - current_ts))
  local hours=$((remaining / 3600))
  local minutes=$(((remaining % 3600) / 60))
  local seconds=$((remaining % 60))

  local expiry_date
  expiry_date=$(date -d "@$expiry_ts" "+%H:%M on %Y-%m-%d")

  local ip_count=0
  if [ -f "$BLOCKED_IPS_FILE" ]; then
    ip_count=$(wc -l <"$BLOCKED_IPS_FILE")
  fi

  echo "=== Focus Mode Status ==="
  echo "Status: ACTIVE"
  echo "Expires: $expiry_date"
  echo "Remaining: ${hours}h ${minutes}m ${seconds}s"
  echo "Blocked IPs: $ip_count"
  echo ""
  echo "Note: Cannot be disabled early (nuclear mode)"
}

enable_focus() {
  local hours="$1"

  # Validate input
  if [ -z "$hours" ]; then
    echo "Error: Hours parameter required"
    echo ""
    show_help
    exit 1
  fi

  # Check if hours is a valid number
  if ! [[ "$hours" =~ ^[0-9]+\.?[0-9]*$ ]]; then
    echo "Error: Hours must be a positive number"
    echo "Examples: 1, 0.5, 2.5"
    exit 1
  fi

  # Check if hours is greater than 0.01 (36 seconds minimum)
  if [ "$(echo "$hours < 0.01" | bc)" -eq 1 ]; then
    echo "Error: Hours must be at least 0.01 (36 seconds)"
    echo "Examples: 0.1 (6 minutes), 0.5 (30 minutes), 1 (1 hour)"
    exit 1
  fi

  if [ "$#" -ne 1 ]; then
    echo "Error: Unexpected arguments"
    echo ""
    show_help
    exit 1
  fi

  # Check if focus mode is already active
  if [ -f "$ACTIVE_FLAG" ]; then
    echo "Error: Focus mode is already active"
    echo ""
    show_status
    exit 1
  fi

  # Ensure state directory exists
  if [ ! -d "$STATE_DIR" ]; then
    sudo mkdir -p "$STATE_DIR"
    sudo chmod 755 "$STATE_DIR"
  fi

  echo "=== Enabling Focus Mode for $hours hour(s) ==="
  echo ""

  echo "Resolving blocked domains..."
  local ipv4_list=()
  local ipv6_list=()
  local domain_count=0
  local domain
  local ip

  for domain in $BLOCKLIST; do
    echo -n "  $domain ... "

    # Resolve IPv4
    local ipv4_addrs
    ipv4_addrs=$(dig +short "$domain" A 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' || true)

    # Resolve IPv6
    local ipv6_addrs
    ipv6_addrs=$(dig +short "$domain" AAAA 2>/dev/null | grep -E '^[0-9a-fA-F:]+$' || true)

    if [ -n "$ipv4_addrs" ] || [ -n "$ipv6_addrs" ]; then
      local v4_count=0
      local v6_count=0

      if [ -n "$ipv4_addrs" ]; then
        while IFS= read -r ip; do
          ipv4_list+=("$ip")
          v4_count=$((v4_count + 1))
        done <<<"$ipv4_addrs"
      fi

      if [ -n "$ipv6_addrs" ]; then
        while IFS= read -r ip; do
          ipv6_list+=("$ip")
          v6_count=$((v6_count + 1))
        done <<<"$ipv6_addrs"
      fi

      echo "OK ($v4_count IPv4, $v6_count IPv6)"
      domain_count=$((domain_count + 1))
    else
      echo "FAILED (no IPs resolved)"
    fi
  done

  echo ""
  echo "Resolved: $domain_count domains -> ${#ipv4_list[@]} IPv4 + ${#ipv6_list[@]} IPv6 addresses"

  local resolved_ipv4_count=${#ipv4_list[@]}
  local resolved_ipv6_count=${#ipv6_list[@]}
  if [ "$resolved_ipv4_count" -eq 0 ] && [ "$resolved_ipv6_count" -eq 0 ]; then
    echo ""
    echo "Error: No IP addresses resolved. Check your network connection."
    exit 1
  fi

  local whitelist_domain_count=0
  local excluded_ipv4_count=0
  local excluded_ipv6_count=0
  if [ -n "$WHITELIST" ]; then
    echo ""
    echo "Resolving whitelisted domains..."

    declare -A whitelist_ipv4_map=()
    declare -A whitelist_ipv6_map=()

    for domain in $WHITELIST; do
      echo -n "  $domain ... "

      local whitelist_ipv4_addrs
      whitelist_ipv4_addrs=$(dig +short "$domain" A 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' || true)

      local whitelist_ipv6_addrs
      whitelist_ipv6_addrs=$(dig +short "$domain" AAAA 2>/dev/null | grep -E '^[0-9a-fA-F:]+$' || true)

      if [ -n "$whitelist_ipv4_addrs" ] || [ -n "$whitelist_ipv6_addrs" ]; then
        local whitelist_v4_count=0
        local whitelist_v6_count=0

        if [ -n "$whitelist_ipv4_addrs" ]; then
          while IFS= read -r ip; do
            whitelist_ipv4_map["$ip"]=1
            whitelist_v4_count=$((whitelist_v4_count + 1))
          done <<<"$whitelist_ipv4_addrs"
        fi

        if [ -n "$whitelist_ipv6_addrs" ]; then
          while IFS= read -r ip; do
            whitelist_ipv6_map["$ip"]=1
            whitelist_v6_count=$((whitelist_v6_count + 1))
          done <<<"$whitelist_ipv6_addrs"
        fi

        echo "OK ($whitelist_v4_count IPv4, $whitelist_v6_count IPv6)"
        whitelist_domain_count=$((whitelist_domain_count + 1))
      else
        echo "FAILED (no IPs resolved)"
      fi
    done

    local filtered_ipv4_list=()
    local filtered_ipv6_list=()

    for ip in "${ipv4_list[@]}"; do
      if [ -n "${whitelist_ipv4_map[$ip]:-}" ]; then
        excluded_ipv4_count=$((excluded_ipv4_count + 1))
      else
        filtered_ipv4_list+=("$ip")
      fi
    done

    for ip in "${ipv6_list[@]}"; do
      if [ -n "${whitelist_ipv6_map[$ip]:-}" ]; then
        excluded_ipv6_count=$((excluded_ipv6_count + 1))
      else
        filtered_ipv6_list+=("$ip")
      fi
    done

    ipv4_list=("${filtered_ipv4_list[@]}")
    ipv6_list=("${filtered_ipv6_list[@]}")

    echo ""
    echo "Whitelist preserved: $whitelist_domain_count domains, excluded $excluded_ipv4_count IPv4 + $excluded_ipv6_count IPv6 addresses"
  fi

  if [ ${#ipv4_list[@]} -eq 0 ] && [ ${#ipv6_list[@]} -eq 0 ]; then
    echo ""
    echo "Warning: Whitelist excluded all resolved blocked IPs."
    echo "Focus mode will still activate, but no sites are blocked right now."
  fi

  # Save blocked IPs to file
  {
    if [ ${#ipv4_list[@]} -gt 0 ]; then
      printf '%s\n' "${ipv4_list[@]}"
    fi
    if [ ${#ipv6_list[@]} -gt 0 ]; then
      printf '%s\n' "${ipv6_list[@]}"
    fi
  } | sudo tee "$BLOCKED_IPS_FILE" >/dev/null

  echo ""
  echo "Creating firewall rules..."

  # Create IPv4 chain
  sudo iptables -N FOCUS_MODE 2>/dev/null || {
    echo "Warning: FOCUS_MODE chain already exists (cleaning up)"
    sudo iptables -F FOCUS_MODE
  }

  # Create IPv6 chain
  sudo ip6tables -N FOCUS_MODE 2>/dev/null || {
    echo "Warning: FOCUS_MODE IPv6 chain already exists (cleaning up)"
    sudo ip6tables -F FOCUS_MODE
  }

  # Add chains to OUTPUT
  sudo iptables -C OUTPUT -j FOCUS_MODE 2>/dev/null || sudo iptables -I OUTPUT 1 -j FOCUS_MODE
  sudo ip6tables -C OUTPUT -j FOCUS_MODE 2>/dev/null || sudo ip6tables -I OUTPUT 1 -j FOCUS_MODE

  # Add blocking rules for IPv4
  for ip in "${ipv4_list[@]}"; do
    sudo iptables -A FOCUS_MODE -d "$ip" -j REJECT --reject-with icmp-host-unreachable
  done

  # Add blocking rules for IPv6
  for ip in "${ipv6_list[@]}"; do
    sudo ip6tables -A FOCUS_MODE -d "$ip" -j REJECT --reject-with icmp6-adm-prohibited
  done

  echo "Firewall rules created successfully"

  # Calculate expiry timestamp (convert to integer seconds to be safe)
  local hours_in_seconds
  hours_in_seconds=$(echo "scale=0; $hours * 3600 / 1" | bc)
  local expiry_ts
  expiry_ts=$(date -d "+${hours_in_seconds} seconds" +%s)
  local expiry_date
  expiry_date=$(date -d "@$expiry_ts" "+%H:%M on %Y-%m-%d")

  # Write state file
  echo "$expiry_ts" | sudo tee "$ACTIVE_FLAG" >/dev/null

  # Schedule cleanup with systemd-run
  echo ""
  echo "Scheduling automatic cleanup..."
  if ! sudo systemd-run \
    --on-active="${hours}h" \
    --unit=focus-mode-cleanup \
    --description="Focus mode automatic cleanup" \
    --service-type=oneshot \
    --quiet \
    /bin/sh -c "PATH=/run/current-system/sw/bin:\$PATH /run/current-system/sw/bin/focus _cleanup" 2>&1; then
    echo ""
    echo "ERROR: Failed to schedule automatic cleanup!"
    echo "Cleaning up firewall rules..."
    # Clean up firewall rules since we can't schedule cleanup
    sudo iptables -D OUTPUT -j FOCUS_MODE 2>/dev/null || true
    sudo iptables -F FOCUS_MODE 2>/dev/null || true
    sudo iptables -X FOCUS_MODE 2>/dev/null || true
    sudo ip6tables -D OUTPUT -j FOCUS_MODE 2>/dev/null || true
    sudo ip6tables -F FOCUS_MODE 2>/dev/null || true
    sudo ip6tables -X FOCUS_MODE 2>/dev/null || true
    sudo rm -f "$ACTIVE_FLAG" "$BLOCKED_IPS_FILE"
    exit 1
  fi

  echo ""
  echo "=== Focus Mode Activated ==="
  echo "Duration: $hours hour(s)"
  echo "Expires: $expiry_date"
  echo "Blocked: ${#ipv4_list[@]} IPv4 + ${#ipv6_list[@]} IPv6 addresses from $domain_count domains"
  echo ""
  echo "Stay focused! Focus mode cannot be disabled early."
  echo "Use 'focus status' to check remaining time."
}

disable_focus() {
  # Check if focus mode has actually expired (prevent manual cheating)
  if [ -f "$ACTIVE_FLAG" ]; then
    local expiry_ts
    expiry_ts=$(cat "$ACTIVE_FLAG" 2>/dev/null || echo "0")
    local current_ts
    current_ts=$(date +%s)

    if [[ "$expiry_ts" =~ ^[0-9]+$ ]] && [ "$current_ts" -lt "$expiry_ts" ]; then
      local remaining=$((expiry_ts - current_ts))
      local hours=$((remaining / 3600))
      local minutes=$(((remaining % 3600) / 60))
      echo "Nice try! Focus mode is still active."
      echo "Remaining: ${hours}h ${minutes}m"
      echo ""
      echo "The whole point is that you CAN'T disable it early."
      echo "Stay focused!"
      exit 1
    fi
  fi

  # Log to both stdout and syslog for debugging
  {
    echo "=== Cleaning up Focus Mode ==="
    echo "Running as UID: $EUID"

    # Detect if we need sudo (not running as root)
    local SUDO_CMD=""
    if [ "$EUID" -ne 0 ]; then
      SUDO_CMD="sudo"
      echo "Using sudo for commands"
    else
      echo "Running as root, no sudo needed"
    fi

    # Remove firewall rules
    echo "Removing firewall rules..."

    # IPv4 cleanup
    $SUDO_CMD iptables -D OUTPUT -j FOCUS_MODE 2>/dev/null || true
    $SUDO_CMD iptables -F FOCUS_MODE 2>/dev/null || true
    $SUDO_CMD iptables -X FOCUS_MODE 2>/dev/null || true

    # IPv6 cleanup
    $SUDO_CMD ip6tables -D OUTPUT -j FOCUS_MODE 2>/dev/null || true
    $SUDO_CMD ip6tables -F FOCUS_MODE 2>/dev/null || true
    $SUDO_CMD ip6tables -X FOCUS_MODE 2>/dev/null || true

    # Remove state files
    $SUDO_CMD rm -f "$ACTIVE_FLAG" "$BLOCKED_IPS_FILE"

    echo "Focus mode disabled successfully"
  } 2>&1 | tee >(logger -t focus-mode-cleanup)
}

# Main command dispatcher
case "${1:-}" in
[0-9]*)
  enable_focus "$@"
  ;;
status)
  show_status
  ;;
_cleanup)
  # Internal command for systemd timer
  disable_focus
  ;;
help | --help | -h)
  show_help
  ;;
"")
  echo "Error: No command specified"
  echo ""
  show_help
  exit 1
  ;;
*)
  echo "Error: Unknown command '$1'"
  echo ""
  show_help
  exit 1
  ;;
esac
