# Quick DNS switcher for when Nebula/internal DNS is down or for captive portals
# Usage: dns-switch [dhcp|nebula|cloudflare|google|auto|status|help]

ACTION="${1:-}"

show_help() {
    cat <<EOF
Usage: dns-switch [option]

Switch DNS servers when Nebula network is down or for captive portals.

Options:
    dhcp          Use DHCP-provided DNS (for captive portals)
    cloudflare    Switch to Cloudflare DNS (1.1.1.1, 1.0.0.1)
    google        Switch to Google DNS (8.8.8.8, 8.8.4.4)
    nebula        Return to Nebula DNS (10.10.0.12)
    auto          Return to automatic/systemd-resolved DNS
    status        Show current DNS configuration
    help          Show this help message

Examples:
    dns-switch dhcp           # Use network DNS for captive portal
    dns-switch cloudflare     # Switch to Cloudflare DNS
    dns-switch nebula         # Return to Nebula DNS
    dns-switch status         # Check current DNS settings

Note: Changes are temporary and will be reset after network restart
      or system reboot. For permanent changes, modify your NixOS config.
EOF
}

get_connection() {
    # Get the active connection name
    nmcli -t -f NAME,DEVICE connection show --active | grep -v '^lo:' | head -n1 | cut -d: -f1
}

get_device() {
    # Get the active device name (e.g., wlan0)
    nmcli -t -f NAME,DEVICE connection show --active | grep -v '^lo:' | head -n1 | cut -d: -f2
}

show_status() {
    echo "=== Current DNS Configuration ==="
    echo
    echo "Active connection:"
    get_connection
    echo
    echo "Current DNS servers (from systemd-resolved):"
    resolvectl status | grep -A 20 "^Link" | grep "Current DNS Server\|DNS Servers" || echo "Unable to determine"
    echo
    echo "Resolv.conf:"
    grep nameserver /etc/resolv.conf
}

set_dns() {
    local dns_servers="$1"
    local description="$2"

    local conn device
    conn=$(get_connection)
    device=$(get_device)

    if [ -z "$conn" ]; then
        echo "Error: No active network connection found"
        exit 1
    fi

    if [ -z "$device" ]; then
        echo "Error: No active network device found"
        exit 1
    fi

    echo "Setting DNS to $description on connection: $conn (device: $device)"
    sudo nmcli connection modify "$conn" ipv4.dns "$dns_servers"
    sudo nmcli connection modify "$conn" ipv4.ignore-auto-dns yes
    sudo nmcli connection up "$conn" > /dev/null 2>&1 || true

    # Set DNS domain routing to route all queries through this interface
    echo "Setting DNS domain routing for $device"
    sudo resolvectl domain "$device" "~."

    echo "✓ DNS switched to $description"
    echo
    sleep 1
    show_status
}

reset_dns() {
    local conn device
    conn=$(get_connection)
    device=$(get_device)

    if [ -z "$conn" ]; then
        echo "Error: No active network connection found"
        exit 1
    fi

    if [ -z "$device" ]; then
        echo "Error: No active network device found"
        exit 1
    fi

    echo "Resetting to automatic DNS on connection: $conn (device: $device)"
    sudo nmcli connection modify "$conn" ipv4.dns ""
    sudo nmcli connection modify "$conn" ipv4.ignore-auto-dns no
    sudo nmcli connection up "$conn" > /dev/null 2>&1 || true

    # Revert DNS domain routing to default
    echo "Reverting DNS domain routing for $device"
    sudo resolvectl revert "$device"

    echo "✓ DNS reset to automatic (systemd-resolved)"
    echo
    sleep 1
    show_status
}

set_dhcp() {
    local conn device
    conn=$(get_connection)
    device=$(get_device)

    if [ -z "$conn" ]; then
        echo "Error: No active network connection found"
        exit 1
    fi

    if [ -z "$device" ]; then
        echo "Error: No active network device found"
        exit 1
    fi

    echo "Switching to DHCP-provided DNS on connection: $conn (device: $device)"
    sudo nmcli connection modify "$conn" ipv4.dns ""
    sudo nmcli connection modify "$conn" ipv6.dns ""
    sudo nmcli connection modify "$conn" ipv4.ignore-auto-dns no
    sudo nmcli connection modify "$conn" ipv6.ignore-auto-dns no
    sudo nmcli connection up "$conn" > /dev/null 2>&1 || true

    # Revert DNS domain routing to default (let DHCP handle it)
    echo "Reverting DNS domain routing for $device"
    sudo resolvectl revert "$device"

    # Flush cache
    sudo resolvectl flush-caches

    echo "✓ DNS switched to DHCP-provided (for captive portals)"
    echo
    sleep 1
    show_status
}

case "$ACTION" in
    dhcp)
        set_dhcp
        ;;
    cloudflare)
        set_dns "1.1.1.1,1.0.0.1" "Cloudflare (1.1.1.1, 1.0.0.1)"
        ;;
    google)
        set_dns "8.8.8.8,8.8.4.4" "Google (8.8.8.8, 8.8.4.4)"
        ;;
    nebula)
        set_dns "10.10.0.12" "Nebula DNS (10.10.0.12)"
        ;;
    auto|automatic|reset)
        reset_dns
        ;;
    status)
        show_status
        ;;
    help|--help|-h)
        show_help
        ;;
    "")
        echo "Error: No option specified"
        echo
        show_help
        exit 1
        ;;
    *)
        echo "Error: Unknown option '$ACTION'"
        echo
        show_help
        exit 1
        ;;
esac
