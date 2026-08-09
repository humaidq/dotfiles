#!/usr/bin/env bash
# Decision-logic tests for battery-guard: fake sysfs + dry-run, no real suspend.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$SCRIPT_DIR/../battery-guard.sh"

tmp="$(mktemp -d)"
caffeine_pid=""

# Every stub inhibitor PID spawned via start_caffeine (or the PID-reuse
# tail -f /dev/null stand-in) is appended here, so cleanup can kill all of
# them rather than relying solely on whatever the caffeine_pid variable last
# held — a straightforward safety net in case any start/stop pairing is ever
# skipped or reordered.
declare -a spawned_pids=()

cleanup() {
  local pid
  for pid in "${spawned_pids[@]}"; do
    [ -n "$pid" ] && kill "$pid" 2>/dev/null || true
  done
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
  # Redirect away from whatever stdio this stub inherited: it's forked from
  # the test script, so leaving it connected to our stdout/stderr would hold
  # a piped reader (tail, tee, CI log collector) open until this sleep exits.
  sleep 300 >/dev/null 2>&1 &
  caffeine_pid=$!
  spawned_pids+=("$caffeine_pid")
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
  BATTERY_GUARD_INHIBIT_MATCH="sleep" \
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

# --- cmdline hardening: a live process whose cmdline does not match must be
# treated as caffeine-inactive (guards against PID reuse), mirroring
# caffeine-ctl.sh's inhibitor_alive(). Deliberately does NOT override
# BATTERY_GUARD_INHIBIT_MATCH, so the default ("systemd-inhibit") is compared
# against the fake inhibitor's real cmdline ("sleep 300"), which is a
# genuinely live but non-matching process — not the pre-existing dead-PID path.
set_battery 15 Discharging; start_caffeine
hardening_got="$(
  BATTERY_GUARD_DRY_RUN=1 \
  BATTERY_GUARD_SYSFS="$tmp/sysfs" \
  BATTERY_GUARD_LOW=20 \
  BATTERY_GUARD_CRITICAL=7 \
  BATTERY_GUARD_INHIBIT_FILE="$tmp/inhibit.pid" \
    bash "$GUARD"
)"
if [ "$hardening_got" = "none" ]; then
  printf 'PASS: %s (%s)\n' "live process with non-matching cmdline is treated as inactive" "$hardening_got"
else
  printf 'FAIL: %s — want %s, got %s\n' "live process with non-matching cmdline is treated as inactive" "none" "$hardening_got"
  fail=1
fi
stop_caffeine

# --- side-effect tests: clear_caffeine also resets mode + stops the beeper ---
# These use BATTERY_GUARD_ONCE (real actions, single pass) rather than dry-run,
# with notify-send and systemctl stubbed on PATH.
mkdir -p "$tmp/bin"

cat > "$tmp/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$SYSTEMCTL_LOG"
EOF

cat > "$tmp/bin/notify-send" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

chmod +x "$tmp/bin/systemctl" "$tmp/bin/notify-send"
export SYSTEMCTL_LOG="$tmp/systemctl.log"

run_guard_once() {
  : > "$SYSTEMCTL_LOG"
  PATH="$tmp/bin:$PATH" \
  BATTERY_GUARD_ONCE=1 \
  BATTERY_GUARD_SYSFS="$tmp/sysfs" \
  BATTERY_GUARD_LOW=20 \
  BATTERY_GUARD_CRITICAL=7 \
  BATTERY_GUARD_INHIBIT_FILE="$tmp/inhibit.pid" \
  BATTERY_GUARD_MODE_FILE="$tmp/mode" \
  BATTERY_GUARD_BEEPER_UNIT="caffeine-beeper" \
  BATTERY_GUARD_INHIBIT_MATCH="sleep" \
    bash "$GUARD"
}

check_side_effect() { # desc want got
  if [ "$2" = "$3" ]; then
    printf 'PASS: %s (%s)\n' "$1" "$3"
  else
    printf 'FAIL: %s — want %s, got %s\n' "$1" "$2" "$3"
    fail=1
  fi
}

beeper_stopped() { # -> stopped|none
  if grep -q -e '--user stop caffeine-beeper' "$SYSTEMCTL_LOG" 2>/dev/null; then
    printf 'stopped\n'
  else
    printf 'none\n'
  fi
}

inhibit_file_state() { # -> present|gone
  if [ -f "$tmp/inhibit.pid" ]; then printf 'present\n'; else printf 'gone\n'; fi
}

# 15% discharging while in double caffeine -> collapse to decaf, stop beeper.
set_battery 15 Discharging; start_caffeine
printf 'double\n' > "$tmp/mode"
run_guard_once
check_side_effect "low battery in double resets mode file" decaf "$(cat "$tmp/mode")"
check_side_effect "low battery in double stops beeper" stopped "$(beeper_stopped)"
check_side_effect "low battery in double kills inhibitor" gone "$(inhibit_file_state)"
stop_caffeine

# Healthy battery in double caffeine -> nothing is touched.
set_battery 80 Discharging; start_caffeine
printf 'double\n' > "$tmp/mode"
run_guard_once
check_side_effect "healthy battery leaves mode file alone" double "$(cat "$tmp/mode")"
check_side_effect "healthy battery issues no beeper stop" none "$(beeper_stopped)"
check_side_effect "healthy battery keeps inhibitor" present "$(inhibit_file_state)"
stop_caffeine

# --- I2: the kill path must not signal a recycled PID either -----------------
# clear_caffeine must gate its kill on caffeine_active (the same check the
# read path uses), so a stale PID file whose PID has been recycled by an
# unrelated process is only cleaned up, never signalled. This matters because
# decide() returns "suspend" at <=7% discharging *regardless* of whether
# caffeine is active, and that branch calls clear_caffeine unconditionally —
# a stale/reused PID at critical battery must not get SIGTERM'd.
unrelated_pid=""
tail -f /dev/null >/dev/null 2>&1 &
unrelated_pid=$!
spawned_pids+=("$unrelated_pid")
printf '%s' "$unrelated_pid" > "$tmp/inhibit.pid"
printf 'double\n' > "$tmp/mode"
set_battery 5 Discharging # <=7%: decide() returns suspend unconditionally
run_guard_once
if kill -0 "$unrelated_pid" 2>/dev/null; then
  printf 'PASS: %s\n' "clear_caffeine does not kill a cmdline-mismatched PID"
else
  printf 'FAIL: %s\n' "clear_caffeine killed an unrelated process on PID reuse"
  fail=1
fi
check_side_effect "clear_caffeine still removes the stale inhibit file on PID reuse" gone "$(inhibit_file_state)"
kill "$unrelated_pid" 2>/dev/null || true

if [ "$fail" -eq 0 ]; then
  printf '\nAll battery-guard tests passed.\n'
else
  printf '\nSome battery-guard tests FAILED.\n'
  exit 1
fi
