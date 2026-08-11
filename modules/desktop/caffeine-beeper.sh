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
SINK="${CAFFEINE_BEEP_SINK:-@DEFAULT_AUDIO_SINK@}"
# Sink volume the tone is guaranteed to play at, as a wpctl 0.0-1.0 fraction.
MIN_VOLUME="${CAFFEINE_BEEP_MIN_VOLUME:-0.6}"
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

# Prior sink state saved by boost_sink, put back by restore_sink. Empty means
# nothing was touched and there is nothing to restore.
saved_vol=""
saved_muted=""

boost_sink() {
  # Full stream amplitude is not enough on its own: the sink's own volume still
  # applies on top, so a muted or turned-down output silences the alarm. Raise
  # the sink to MIN_VOLUME and unmute it, but only for the length of the tone,
  # and only when it is actually too quiet — a sink already loud enough is left
  # completely alone so the user's volume stays theirs between beeps.
  local state vol muted=0
  state="$(wpctl get-volume "$SINK" 2>/dev/null)" || return 0
  # "Volume: 0.20" or "Volume: 0.20 [MUTED]"
  vol="${state#Volume: }"
  vol="${vol%% *}"
  case "$vol" in
    '' | *[!0-9.]*) return 0 ;; # unrecognised format; leave the sink alone
  esac
  case "$state" in
    *'[MUTED]'*) muted=1 ;;
  esac

  if [ "$muted" -eq 0 ] && awk -v v="$vol" -v m="$MIN_VOLUME" 'BEGIN { exit !(v >= m) }'; then
    return 0
  fi

  saved_vol="$vol"
  saved_muted="$muted"
  # Volume before unmute, so the sink is never briefly live at the old level.
  wpctl set-volume "$SINK" "$MIN_VOLUME" 2>/dev/null || true
  if [ "$muted" -eq 1 ]; then
    wpctl set-mute "$SINK" 0 2>/dev/null || true
  fi
}

restore_sink() {
  [ -n "$saved_vol" ] || return 0
  # Mute before volume, for the same reason boost_sink orders them the other way.
  if [ "$saved_muted" = "1" ]; then
    wpctl set-mute "$SINK" 1 2>/dev/null || true
  fi
  wpctl set-volume "$SINK" "$saved_vol" 2>/dev/null || true
  saved_vol=""
  saved_muted=""
}

play_tone() {
  # Never let a missing sink kill the loop.
  boost_sink
  play -qn synth "$DURATION" sine "$FREQ" gain -1 >/dev/null 2>&1 || true
  restore_sink
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

# Cover the ~0.2s window where the sink is held above the user's setting: if
# the unit is stopped mid-tone, put their volume back rather than leaving it
# floored. restore_sink clears its own state, so double-firing is harmless.
trap restore_sink EXIT INT TERM

main "$@"
