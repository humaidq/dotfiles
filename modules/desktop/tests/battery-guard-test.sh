#!/usr/bin/env bash
# Decision-logic tests for battery-guard: fake sysfs + dry-run, no real suspend.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$SCRIPT_DIR/../battery-guard.sh"

tmp="$(mktemp -d)"
caffeine_pid=""
cleanup() {
  rm -rf "$tmp"
  if [ -n "${caffeine_pid:-}" ]; then kill "$caffeine_pid" 2>/dev/null || true; fi
}
trap cleanup EXIT

fail=0

set_battery() { # capacity status
  mkdir -p "$tmp/sysfs/BAT0"
  printf '%s' "$1" > "$tmp/sysfs/BAT0/capacity"
  printf '%s' "$2" > "$tmp/sysfs/BAT0/status"
}

start_caffeine() {
  sleep 300 &
  caffeine_pid=$!
  printf '%s' "$caffeine_pid" > "$tmp/inhibit.pid"
}

stop_caffeine() {
  if [ -n "${caffeine_pid:-}" ]; then kill "$caffeine_pid" 2>/dev/null || true; caffeine_pid=""; fi
  rm -f "$tmp/inhibit.pid"
}

run_guard() {
  BATTERY_GUARD_DRY_RUN=1 \
  BATTERY_GUARD_SYSFS="$tmp/sysfs" \
  BATTERY_GUARD_LOW=20 \
  BATTERY_GUARD_CRITICAL=7 \
  BATTERY_GUARD_INHIBIT_FILE="$tmp/inhibit.pid" \
    bash "$GUARD"
}

expect() { # desc want
  local got
  got="$(run_guard)"
  if [ "$got" = "$2" ]; then
    printf 'PASS: %s (%s)\n' "$1" "$got"
  else
    printf 'FAIL: %s — want %s, got %s\n' "$1" "$2" "$got"
    fail=1
  fi
}

set_battery 50 Discharging; stop_caffeine
expect "50% discharging, no caffeine" none

set_battery 15 Discharging; stop_caffeine
expect "15% discharging, no caffeine" none

set_battery 15 Discharging; start_caffeine
expect "15% discharging, caffeine on" disable-caffeine
stop_caffeine

set_battery 20 Discharging; start_caffeine
expect "20% boundary, caffeine on" disable-caffeine
stop_caffeine

set_battery 7 Discharging; start_caffeine
expect "7% boundary, caffeine on" suspend
stop_caffeine

set_battery 5 Discharging; stop_caffeine
expect "5% discharging, no caffeine" suspend

set_battery 15 Charging; start_caffeine
expect "15% charging, caffeine on" none
stop_caffeine

set_battery 100 Full; stop_caffeine
expect "100% full" none

if [ "$fail" -eq 0 ]; then
  printf '\nAll battery-guard tests passed.\n'
else
  printf '\nSome battery-guard tests FAILED.\n'
  exit 1
fi
