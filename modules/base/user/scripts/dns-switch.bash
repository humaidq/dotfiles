# Quick DNS switcher for when Nebula/internal DNS is down or for captive portals
# Usage: dns-switch [dhcp|nebula|cloudflare|google|auto|status|help]

ACTION="${1:-}"

show_help() {
  cat <<EOF
Usage: dns-switch [option]

Switch DNS servers when Nebula network is down or for captive portals.

Options:
    dhcp          Use DNS from the current DHCP lease (for captive portals)
    cloudflare    Switch to Cloudflare DNS (1.1.1.1, 1.0.0.1)
    google        Switch to Google DNS (8.8.8.8, 8.8.4.4)
    nebula        Return to Nebula DNS (10.10.0.12)
    auto          Return to declarative default/systemd-resolved DNS
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
  # Get the primary active uplink connection name.
  nmcli -t -f NAME,DEVICE,TYPE connection show --active | grep -vE ':(loopback|tun)$' | head -n1 | cut -d: -f1
}

get_device() {
  # Get the primary active uplink device name (e.g., wlan0).
  nmcli -t -f NAME,DEVICE,TYPE connection show --active | grep -vE ':(loopback|tun)$' | head -n1 | cut -d: -f2
}

get_dhcp_dns() {
  local device="$1"
  local line

  while IFS= read -r line; do
    line=${line#*:}
    case "$line" in
    "domain_name_servers = "*)
      printf '%s\n' "${line#domain_name_servers = }"
      return 0
      ;;
    esac
  done < <(nmcli -t -f DHCP4.OPTION device show "$device")

  return 1
}

show_resolved_section() {
  local title="$1"
  local target="$2"

  echo "$title"
  if [ -n "$target" ]; then
    resolvectl status "$target" | grep -E 'Current DNS Server:|DNS Servers:|DNS Domain:|Default Route:' || echo "Unable to determine"
  else
    {
      resolvectl dns | grep '^Global:'
      resolvectl domain | grep '^Global:'
    } || echo "Unable to determine"
  fi
}

clear_connection_dns_overrides() {
  local conn="$1"
  local device="$2"

  sudo nmcli connection modify "$conn" ipv4.dns ""
  sudo nmcli connection modify "$conn" ipv6.dns ""
  sudo nmcli device reapply "$device" >/dev/null 2>&1 || true
}

apply_link_dns() {
  local device="$1"
  local dns_servers="$2"

  # resolvectl expects DNS servers as separate arguments, not comma-separated.
  # shellcheck disable=SC2086
  sudo resolvectl dns "$device" ${dns_servers//,/ }
  sudo resolvectl domain "$device" "~."
  sudo resolvectl flush-caches
}

show_status() {
  local conn device dhcp_dns

  conn=$(get_connection)
  device=$(get_device)

  echo "=== Current DNS Configuration ==="
  echo
  echo "Active connection:"
  if [ -n "$conn" ]; then
    echo "$conn"
  else
    echo "Unable to determine"
  fi
  echo
  show_resolved_section "Global DNS (from systemd-resolved):" ""
  echo
  if [ -n "$device" ]; then
    show_resolved_section "Active link DNS (from systemd-resolved):" "$device"
    echo
    echo "DHCP DNS from NetworkManager lease:"
    dhcp_dns=$(get_dhcp_dns "$device" 2>/dev/null || true)
    if [ -n "$dhcp_dns" ]; then
      echo "$dhcp_dns"
    else
      echo "Unable to determine"
    fi
    echo
  fi
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
  apply_link_dns "$device" "$dns_servers"

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

  echo "Resetting to declarative default DNS on connection: $conn (device: $device)"
  echo "Clearing any connection-level DNS overrides"
  clear_connection_dns_overrides "$conn" "$device"

  echo "Reverting runtime DNS override for $device"
  sudo resolvectl revert "$device"
  sudo resolvectl flush-caches

  echo "✓ DNS reset to automatic (systemd-resolved)"
  echo
  sleep 1
  show_status
}

set_dhcp() {
  local conn device dhcp_dns
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

  dhcp_dns=$(get_dhcp_dns "$device" 2>/dev/null || true)

  if [ -z "$dhcp_dns" ]; then
    echo "Error: Unable to determine DHCP DNS for $device"
    exit 1
  fi

  echo "Switching to DHCP-provided DNS on connection: $conn (device: $device)"
  echo "Using DHCP lease DNS: $dhcp_dns"
  apply_link_dns "$device" "$dhcp_dns"

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
auto | automatic | reset)
  reset_dns
  ;;
status)
  show_status
  ;;
help | --help | -h)
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
