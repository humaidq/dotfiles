# shellcheck shell=bash
# caffeine-beeper — while on battery, emit a short tone every few seconds.
# Started and stopped on demand by caffeine-ctl for the "double" mode.
# Authoritative power state comes from sysfs. There is no event source:
# the main loop just polls sysfs every CAFFEINE_BEEP_AC_POLL_INTERVAL
# seconds while on AC, and every CAFFEINE_BEEP_INTERVAL seconds while
# beeping on battery. No external process is used to wait for power
# events. Dry-run prints the decision and exits.
set -euo pipefail

SYSFS="${CAFFEINE_BEEP_SYSFS:-/sys/class/power_supply}"
DURATION="${CAFFEINE_BEEP_DURATION:-0.2}"
INTERVAL="${CAFFEINE_BEEP_INTERVAL:-2}"
FREQ="${CAFFEINE_BEEP_FREQ:-1000}"
AC_POLL_INTERVAL="${CAFFEINE_BEEP_AC_POLL_INTERVAL:-2}"
DRY_RUN="${CAFFEINE_BEEP_DRY_RUN:-}"
# Test-only escape hatch: bound the number of main-loop iterations so a
# test can drive the loop over a scripted sysfs sequence and then let it
# exit on its own. 0 (default) means run forever, as in production.
MAX_ITER="${CAFFEINE_BEEP_MAX_ITER:-0}"

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
  local bat status decision armed=1 iter=0
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
    # Tolerate a transient sysfs read failure (-EIO/-ENODATA from a busy EC,
    # or a battery hot-remove mid-read) instead of letting it kill this
    # long-lived service under set -e. Just wait and retry.
    status="$(cat "$bat/status" 2>/dev/null || true)"
    if [ -z "$status" ]; then
      sleep "$AC_POLL_INTERVAL"
      iter=$((iter + 1))
      if [ "$MAX_ITER" -gt 0 ] && [ "$iter" -ge "$MAX_ITER" ]; then
        exit 0
      fi
      continue
    fi
    decision="$(should_beep "$status")"

    if [ "$decision" = "beep" ]; then
      if [ "$armed" -eq 1 ]; then
        notify-send -t 5000 "🔌 Power lost" "Double caffeine — beeping until replugged" || true
        armed=0
      fi
      play_tone
      sleep "$INTERVAL"
    else
      # Back on AC: re-arm the notification and poll again shortly.
      armed=1
      sleep "$AC_POLL_INTERVAL"
    fi

    iter=$((iter + 1))
    if [ "$MAX_ITER" -gt 0 ] && [ "$iter" -ge "$MAX_ITER" ]; then
      exit 0
    fi
  done
}

main "$@"
