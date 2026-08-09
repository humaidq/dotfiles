# shellcheck shell=bash
# caffeine-ctl — three-state sleep inhibition: decaf / caffeine / double.
# `double` additionally runs the caffeine-beeper unit, which beeps while on
# battery. The inhibitor PID file is authoritative for "is sleep inhibited";
# the mode file is advisory and reconciled against it on every invocation.
# `double` specifically means inhibitor-alive AND beeper-active; if the mode
# file says `double` but the beeper unit isn't actually running, current_mode
# downgrades the reported mode to `caffeine` so a stale/silent "double" is
# never reported as armed (see current_mode).
set -euo pipefail

MODE_FILE="${CAFFEINE_MODE_FILE:-/tmp/caffeine-mode-${USER:-unknown}}"
INHIBIT_FILE="${CAFFEINE_INHIBIT_FILE:-/tmp/caffeine-inhibit-${USER:-unknown}.pid}"
BEEPER_UNIT="${CAFFEINE_BEEPER_UNIT:-caffeine-beeper}"
INHIBIT_MATCH="${CAFFEINE_INHIBIT_MATCH:-systemd-inhibit}"

inhibitor_alive() {
  [ -f "$INHIBIT_FILE" ] || return 1
  local pid cmdline
  pid="$(cat "$INHIBIT_FILE" 2>/dev/null || true)"
  [ -n "$pid" ] || return 1
  # Cheap gate: process exists
  kill -0 "$pid" 2>/dev/null || return 1
  # Confirmation: PID's cmdline contains the expected process name (guards against PID reuse)
  # Use tr to convert NUL separators before command substitution to avoid bash warnings
  cmdline="$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null || true)"
  [ -n "$cmdline" ] || return 1
  case "$cmdline" in
    *"$INHIBIT_MATCH"*) return 0 ;;
    *) return 1 ;;
  esac
}

beeper_active() {
  systemctl --user is-active --quiet "$BEEPER_UNIT"
}

current_mode() {
  # A dead inhibitor means decaf no matter what the mode file claims.
  if ! inhibitor_alive; then
    printf 'decaf\n'
    return 0
  fi
  local mode
  mode="$(cat "$MODE_FILE" 2>/dev/null || true)"
  case "$mode" in
    double)
      # double requires the beeper to actually be running; if it died or
      # never started, report the half that is still true.
      if beeper_active; then
        printf 'double\n'
      else
        printf 'caffeine\n'
      fi
      ;;
    caffeine) printf 'caffeine\n' ;;
    *) printf 'caffeine\n' ;;
  esac
}

next_mode() {
  case "$1" in
    decaf) printf 'caffeine\n' ;;
    caffeine) printf 'double\n' ;;
    *) printf 'decaf\n' ;;
  esac
}

stop_inhibitor() {
  local pid=""
  if [ -f "$INHIBIT_FILE" ]; then
    pid="$(cat "$INHIBIT_FILE" 2>/dev/null || true)"
    # Only signal the PID if it's actually our inhibitor (same cmdline-based
    # liveness check the read path uses); a stale, recycled PID must never be
    # killed. Always clear the file either way.
    if [ -n "$pid" ] && inhibitor_alive; then
      kill "$pid" 2>/dev/null || true
    fi
    rm -f "$INHIBIT_FILE"
  fi
}

start_inhibitor() {
  if inhibitor_alive; then
    return 0
  fi
  rm -f "$INHIBIT_FILE"
  systemd-inhibit --what=idle:sleep:handle-lid-switch \
    --why="Caffeine mode - preventing sleep" \
    --who="${USER:-unknown}" \
    --mode=block \
    sleep infinity &
  printf '%s' "$!" > "$INHIBIT_FILE"
}

beeper() { # start|stop
  systemctl --user "$1" "$BEEPER_UNIT" 2>/dev/null || true
}

notify() { # summary body
  notify-send -t 3000 "$1" "$2" 2>/dev/null || true
}

set_mode() {
  case "$1" in
    decaf)
      stop_inhibitor
      beeper stop
      printf 'decaf\n' > "$MODE_FILE"
      notify "☕ Decaf" "Sleep enabled"
      ;;
    caffeine)
      start_inhibitor
      beeper stop
      printf 'caffeine\n' > "$MODE_FILE"
      notify "☕ Caffeine" "Sleep disabled (locking still works)"
      ;;
    double)
      start_inhibitor
      beeper start
      printf 'double\n' > "$MODE_FILE"
      notify "☕☕ Double caffeine" "Sleep disabled, will beep on battery"
      ;;
    *)
      printf 'caffeine-ctl: unknown mode: %s\n' "$1" >&2
      exit 2
      ;;
  esac
}

main() {
  case "${1:-cycle}" in
    cycle) set_mode "$(next_mode "$(current_mode)")" ;;
    set)
      if [ $# -lt 2 ]; then
        printf 'caffeine-ctl: set requires a mode\n' >&2
        exit 2
      fi
      set_mode "$2"
      ;;
    status) current_mode ;;
    *)
      printf 'usage: caffeine-ctl [cycle|set <decaf|caffeine|double>|status]\n' >&2
      exit 2
      ;;
  esac
}

main "$@"
