#!/usr/bin/env bash
# Focus mode - Block distracting websites for a specified duration
# Similar to SelfControl for macOS

BLOCKLIST="@blocklist@"
SLOW_BANDWIDTH="@slow_bandwidth@"
STATE_DIR="/var/lib/focus-mode"
ACTIVE_FLAG="$STATE_DIR/active"
BLOCKED_IPS_FILE="$STATE_DIR/blocked-ips.txt"
BANDWIDTH_FLAG="$STATE_DIR/bandwidth"

show_help() {
    cat <<EOF
Usage: focus <hours> [--slow] | status | help

Block distracting websites for a specified duration using firewall rules.
Similar to SelfControl for macOS - blocks cannot be removed early (nuclear mode).

Commands:
    <hours>         Enable focus mode for N hours (fractional hours supported)
                    Examples: focus 1    (1 hour)
                             focus 0.5  (30 minutes)
                             focus 2.5  (2.5 hours)

    <hours> --slow  Enable focus mode with bandwidth throttling ($SLOW_BANDWIDTH)
                    Examples: focus 1 --slow    (1 hour with slow internet)
                             focus 0.5 --slow  (30 min with slow internet)

    status          Show current focus mode status
    help            Show this help message

Examples:
    focus 1           # Block distracting sites for 1 hour
    focus 0.5         # Block for 30 minutes
    focus 2 --slow    # Block for 2 hours AND throttle bandwidth to $SLOW_BANDWIDTH
    focus status      # Check if focus mode is active

Note: Focus mode uses firewall rules to block websites by IP address.
      The --slow flag additionally limits bandwidth using Linux traffic control (tc).
      Once enabled, it cannot be disabled early (nuclear mode).
      Rules automatically expire after the specified duration.

      Requires sudo access for firewall and traffic control modifications.

Blocked domains:
$(echo "$BLOCKLIST" | tr ' ' '\n' | sed 's/^/  - /')
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
        ip_count=$(wc -l < "$BLOCKED_IPS_FILE")
    fi

    local bandwidth_limit=""
    if [ -f "$BANDWIDTH_FLAG" ]; then
        bandwidth_limit=$(cat "$BANDWIDTH_FLAG" 2>/dev/null || echo "")
    fi

    echo "=== Focus Mode Status ==="
    echo "Status: ACTIVE"
    echo "Expires: $expiry_date"
    echo "Remaining: ${hours}h ${minutes}m ${seconds}s"
    echo "Blocked IPs: $ip_count"
    if [ -n "$bandwidth_limit" ]; then
        echo "Bandwidth: Limited to $bandwidth_limit"
    fi
    echo ""
    echo "Note: Cannot be disabled early (nuclear mode)"
}

enable_focus() {
    local hours="$1"
    local enable_slow=false

    # Parse --slow flag
    if [[ "${2:-}" == "--slow" ]]; then
        enable_slow=true
    fi

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

    # Resolve domains to IPs
    echo "Resolving domains to IP addresses..."
    local ipv4_list=()
    local ipv6_list=()
    local domain_count=0

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
                done <<< "$ipv4_addrs"
            fi

            if [ -n "$ipv6_addrs" ]; then
                while IFS= read -r ip; do
                    ipv6_list+=("$ip")
                    v6_count=$((v6_count + 1))
                done <<< "$ipv6_addrs"
            fi

            echo "OK ($v4_count IPv4, $v6_count IPv6)"
            domain_count=$((domain_count + 1))
        else
            echo "FAILED (no IPs resolved)"
        fi
    done

    echo ""
    echo "Resolved: $domain_count domains -> ${#ipv4_list[@]} IPv4 + ${#ipv6_list[@]} IPv6 addresses"

    if [ ${#ipv4_list[@]} -eq 0 ] && [ ${#ipv6_list[@]} -eq 0 ]; then
        echo ""
        echo "Error: No IP addresses resolved. Check your network connection."
        exit 1
    fi

    # Save blocked IPs to file
    {
        if [ ${#ipv4_list[@]} -gt 0 ]; then
            printf '%s\n' "${ipv4_list[@]}"
        fi
        if [ ${#ipv6_list[@]} -gt 0 ]; then
            printf '%s\n' "${ipv6_list[@]}"
        fi
    } | sudo tee "$BLOCKED_IPS_FILE" > /dev/null

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

    # Apply bandwidth throttling if --slow flag is set
    if [ "$enable_slow" = true ]; then
        echo ""
        echo "Applying bandwidth throttling ($SLOW_BANDWIDTH)..."

        # Load ifb module for ingress shaping (creates ifb0, ifb1, etc.)
        sudo modprobe ifb numifbs=10 2>/dev/null || true

        # Get all network interfaces, excluding lo and sifr0
        local interfaces
        interfaces=$(ip -o link show | awk -F': ' '{print $2}' | grep -v '^lo$' | grep -v '^sifr0$' | grep -v '@')

        local throttled_count=0
        local ifb_index=0

        for iface in $interfaces; do
            local ifb_dev="ifb${ifb_index}"
            local success=true

            # Throttle egress (upload/outbound)
            # Use 'replace' to handle cases where a qdisc already exists
            # burst: 15kbit (just under 2KB) to minimize bursting
            # latency: 50ms for tighter control
            if ! sudo tc qdisc replace dev "$iface" root tbf rate "$SLOW_BANDWIDTH" burst 15kbit latency 50ms 2>/dev/null; then
                echo "  $iface: failed to add egress throttling"
                success=false
            fi

            # Throttle ingress (download/inbound) using ifb device
            if [ "$success" = true ]; then
                # Bring up IFB device
                if ! sudo ip link set "$ifb_dev" up 2>/dev/null; then
                    echo "  $iface: failed to bring up $ifb_dev"
                    success=false
                fi
            fi

            if [ "$success" = true ]; then
                # Add ingress qdisc to real interface
                if ! sudo tc qdisc add dev "$iface" ingress 2>/dev/null; then
                    echo "  $iface: failed to add ingress qdisc"
                    success=false
                fi
            fi

            if [ "$success" = true ]; then
                # Redirect ingress traffic to IFB device
                if ! sudo tc filter add dev "$iface" parent ffff: protocol all u32 match u32 0 0 action mirred egress redirect dev "$ifb_dev" 2>/dev/null; then
                    echo "  $iface: failed to redirect to $ifb_dev"
                    success=false
                fi
            fi

            if [ "$success" = true ]; then
                # Apply rate limiting on IFB device (this shapes the ingress of real interface)
                if ! sudo tc qdisc add dev "$ifb_dev" root tbf rate "$SLOW_BANDWIDTH" burst 15kbit latency 50ms 2>/dev/null; then
                    echo "  $iface: failed to add throttling to $ifb_dev"
                    success=false
                fi
            fi

            if [ "$success" = true ]; then
                echo "  $iface -> $ifb_dev: limited to $SLOW_BANDWIDTH (upload and download)"
                ((throttled_count++)) || true
            else
                echo "  $iface: limited to $SLOW_BANDWIDTH (upload only, download throttling failed)"
            fi

            ((ifb_index++)) || true
        done

        if [ $throttled_count -eq 0 ]; then
            echo "  Warning: No interfaces were throttled (may already have qdisc rules)"
        else
            echo "  Throttled $throttled_count interface(s)"
        fi

        # Save bandwidth flag to state
        echo "$SLOW_BANDWIDTH" | sudo tee "$BANDWIDTH_FLAG" > /dev/null
    fi

    # Calculate expiry timestamp (convert to integer seconds to be safe)
    local hours_in_seconds
    hours_in_seconds=$(echo "scale=0; $hours * 3600 / 1" | bc)
    local expiry_ts
    expiry_ts=$(date -d "+${hours_in_seconds} seconds" +%s)
    local expiry_date
    expiry_date=$(date -d "@$expiry_ts" "+%H:%M on %Y-%m-%d")

    # Write state file
    echo "$expiry_ts" | sudo tee "$ACTIVE_FLAG" > /dev/null

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
        sudo rm -f "$ACTIVE_FLAG" "$BLOCKED_IPS_FILE" "$BANDWIDTH_FLAG"
        exit 1
    fi

    echo ""
    echo "=== Focus Mode Activated ==="
    echo "Duration: $hours hour(s)"
    echo "Expires: $expiry_date"
    echo "Blocked: ${#ipv4_list[@]} IPv4 + ${#ipv6_list[@]} IPv6 addresses from $domain_count domains"
    if [ "$enable_slow" = true ]; then
        echo "Bandwidth: Limited to $SLOW_BANDWIDTH"
    fi
    echo ""
    echo "Stay focused! Focus mode cannot be disabled early."
    echo "Use 'focus status' to check remaining time."
}

disable_focus() {
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

        # Remove bandwidth limits
        echo "Removing bandwidth limits..."

        # Get all network interfaces, excluding lo and sifr0
        local interfaces
        interfaces=$(ip -o link show | awk -F': ' '{print $2}' | grep -v '^lo$' | grep -v '^sifr0$' | grep -v '@' || true)

        for iface in $interfaces; do
            # Remove egress throttling and restore default qdisc
            $SUDO_CMD tc qdisc del dev "$iface" root 2>/dev/null || true
            # Restore default qdisc (fq_codel is modern default, fallback to pfifo_fast)
            $SUDO_CMD tc qdisc add dev "$iface" root fq_codel 2>/dev/null || $SUDO_CMD tc qdisc add dev "$iface" root pfifo_fast 2>/dev/null || true

            # Remove ingress throttling (this also removes filters)
            $SUDO_CMD tc qdisc del dev "$iface" ingress 2>/dev/null || true
        done

        # Clean up all IFB devices (ifb0 through ifb9)
        for i in {0..9}; do
            local ifb_dev="ifb${i}"
            if ip link show "$ifb_dev" >/dev/null 2>&1; then
                $SUDO_CMD tc qdisc del dev "$ifb_dev" root 2>/dev/null || true
                $SUDO_CMD ip link set "$ifb_dev" down 2>/dev/null || true
            fi
        done

        # Remove state files
        $SUDO_CMD rm -f "$ACTIVE_FLAG" "$BLOCKED_IPS_FILE" "$BANDWIDTH_FLAG"

        echo "Focus mode disabled successfully"
    } 2>&1 | tee >(logger -t focus-mode-cleanup)
}

# Main command dispatcher
case "${1:-}" in
    [0-9]*)
        enable_focus "$@"  # Pass all arguments to handle --slow flag
        ;;
    status)
        show_status
        ;;
    _cleanup)
        # Internal command for systemd timer
        disable_focus
        ;;
    help|--help|-h)
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
