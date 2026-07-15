# shellcheck shell=bash
# battery-guard — on battery, disable caffeine at LOW% and suspend at CRITICAL%.
# Authoritative state is read from sysfs; the event loop is woken by
# `upower --monitor`. Dry-run mode prints the chosen action and exits.
set -euo pipefail

SYSFS="${BATTERY_GUARD_SYSFS:-/sys/class/power_supply}"
LOW="${BATTERY_GUARD_LOW:-20}"
CRITICAL="${BATTERY_GUARD_CRITICAL:-7}"
DRY_RUN="${BATTERY_GUARD_DRY_RUN:-}"
INHIBIT_FILE="${BATTERY_GUARD_INHIBIT_FILE:-/tmp/caffeine-inhibit-${USER:-unknown}.pid}"

find_battery() {
  local bat
  for bat in "$SYSFS"/BAT*; do
    if [ -e "$bat/capacity" ] && [ -e "$bat/status" ]; then
      printf '%s\n' "$bat"
      return 0
    fi
  done
  return 1
}

caffeine_active() {
  [ -f "$INHIBIT_FILE" ] || return 1
  local pid
  pid="$(cat "$INHIBIT_FILE" 2>/dev/null || true)"
  [ -n "$pid" ] || return 1
  kill -0 "$pid" 2>/dev/null
}

clear_caffeine() {
  local pid=""
  if [ -f "$INHIBIT_FILE" ]; then
    pid="$(cat "$INHIBIT_FILE" 2>/dev/null || true)"
    if [ -n "$pid" ]; then
      kill "$pid" 2>/dev/null || true
    fi
    rm -f "$INHIBIT_FILE"
  fi
}

decide() {
  # args: capacity status caffeine(yes|no) -> none|disable-caffeine|suspend
  local capacity="$1" status="$2" caffeine="$3"
  if [ "$status" != "Discharging" ]; then
    printf 'none\n'; return 0
  fi
  if [ "$capacity" -le "$CRITICAL" ]; then
    printf 'suspend\n'; return 0
  fi
  if [ "$capacity" -le "$LOW" ] && [ "$caffeine" = "yes" ]; then
    printf 'disable-caffeine\n'; return 0
  fi
  printf 'none\n'
}

run_once() {
  local bat capacity status caffeine action
  if ! bat="$(find_battery)"; then
    if [ -n "$DRY_RUN" ]; then printf 'none\n'; fi
    return 0
  fi
  capacity="$(cat "$bat/capacity")"
  status="$(cat "$bat/status")"
  if caffeine_active; then caffeine=yes; else caffeine=no; fi
  action="$(decide "$capacity" "$status" "$caffeine")"

  if [ -n "$DRY_RUN" ]; then
    printf '%s\n' "$action"
    return 0
  fi

  case "$action" in
    disable-caffeine)
      clear_caffeine
      notify-send -t 5000 "🔋 Battery low" "Caffeine disabled — sleep re-enabled (${capacity}%)" || true
      ;;
    suspend)
      clear_caffeine
      notify-send -t 5000 --urgency critical "🔋 Battery critical" "Suspending to save your work (${capacity}%)" || true
      systemctl suspend || true
      sleep 5  # debounce after resume so we don't tight-loop on repeated events
      ;;
    none) : ;;
  esac
}

main() {
  if ! find_battery >/dev/null 2>&1; then
    if [ -n "$DRY_RUN" ]; then printf 'none\n'; fi
    exit 0
  fi
  run_once
  if [ -n "$DRY_RUN" ]; then exit 0; fi
  if command -v upower >/dev/null 2>&1; then
    while true; do
      upower --monitor | while read -r _; do
        run_once
      done
      sleep 5
    done
  else
    while true; do
      sleep 30
      run_once
    done
  fi
}

main "$@"
