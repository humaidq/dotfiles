dns-switch dhcp

if ! connectivity=$(nmcli networking connectivity check); then
  dns-switch reset
  exit 0
fi

if [ "$connectivity" = "portal" ]; then
  xdg-open https://neverssl.com
  exit 0
fi

dns-switch reset
