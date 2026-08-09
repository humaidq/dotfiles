# shellcheck shell=bash
# caffeine-beeper — while on battery, emit a short tone every few seconds.
# Started and stopped on demand by caffeine-ctl for the "double" mode.
# Authoritative power state comes from sysfs; upower events wake the loop
# to re-check status. Dry-run prints the decision and exits.
set -euo pipefail

SYSFS="${CAFFEINE_BEEP_SYSFS:-/sys/class/power_supply}"
DURATION="${CAFFEINE_BEEP_DURATION:-0.2}"
INTERVAL="${CAFFEINE_BEEP_INTERVAL:-2}"
FREQ="${CAFFEINE_BEEP_FREQ:-1000}"
DRY_RUN="${CAFFEINE_BEEP_DRY_RUN:-}"
WAKEUP_FILE="${CAFFEINE_BEEP_WAKEUP_FILE:-/tmp/caffeine-beeper-wakeup-${USER:-unknown}}"

export AUDIODRIVER=pulseaudio

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

should_beep() {
  # args: status -> beep|silent
  if [ "$1" = "Discharging" ]; then
    printf 'beep\n'
  else
    printf 'silent\n'
  fi
}

play_tone() {
  # Full stream amplitude; the sink's own volume still applies (see spec's
  # "Known limitation"). Never let a missing sink kill the loop.
  play -qn synth "$DURATION" sine "$FREQ" gain -1 >/dev/null 2>&1 || true
}

main() {
  local bat status decision armed=1
  if ! bat="$(find_battery)"; then
    exit 0
  fi

  if [ -n "$DRY_RUN" ]; then
    status="$(cat "$bat/status")"
    should_beep "$status"
    exit 0
  fi

  while true; do
    if ! bat="$(find_battery)"; then
      exit 0
    fi
    status="$(cat "$bat/status")"
    decision="$(should_beep "$status")"

    if [ "$decision" = "beep" ]; then
      if [ "$armed" -eq 1 ]; then
        notify-send -t 5000 "🔌 Power lost" "Double caffeine — beeping until replugged" || true
        armed=0
      fi
      play_tone
      sleep "$INTERVAL"
    else
      # Back on AC: re-arm the notification and idle until a power event.
      armed=1
      rm -f "$WAKEUP_FILE"

      if command -v upower >/dev/null 2>&1; then
        # Drain upower events; timeout after 2s to ensure re-check.
        # Never break from the read loop — that leaves upower orphaned.
        timeout 2 upower --monitor 2>/dev/null | while read -r _; do
          # Power event occurred; check if status changed to Discharging.
          # We run in a subshell (pipe), so use a file to signal.
          if bat="$(find_battery)"; then
            st="$(cat "$bat/status")"
            if [ "$st" = "Discharging" ]; then
              touch "$WAKEUP_FILE"
            fi
          fi
        done
      else
        sleep 10
      fi

      # Debounce only if upower timed out with no discharge event.
      # If we detected discharge, skip debounce and re-check immediately.
      if [ ! -f "$WAKEUP_FILE" ]; then
        sleep 5
      fi
      rm -f "$WAKEUP_FILE"
    fi
  done
}

main "$@"
