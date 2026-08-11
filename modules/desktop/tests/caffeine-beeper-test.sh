#!/usr/bin/env bash
# Decision-logic tests for caffeine-beeper: fake sysfs + dry-run, no audio.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BEEPER="$SCRIPT_DIR/../caffeine-beeper.sh"

tmp="$(mktemp -d)"
cleanup() { rm -rf "$tmp"; }
trap cleanup EXIT

fail=0

set_battery() { # status
  mkdir -p "$tmp/sysfs/BAT0"
  printf '%s' "100" > "$tmp/sysfs/BAT0/capacity"
  printf '%s' "$1" > "$tmp/sysfs/BAT0/status"
}

run_beeper() {
  CAFFEINE_BEEP_DRY_RUN=1 \
  CAFFEINE_BEEP_SYSFS="$tmp/sysfs" \
    bash "$BEEPER"
}

expect() { # desc want
  local got
  got="$(run_beeper)"
  if [ "$got" = "$2" ]; then
    printf 'PASS: %s (%s)\n' "$1" "$got"
  else
    printf 'FAIL: %s — want %s, got %s\n' "$1" "$2" "$got"
    fail=1
  fi
}

set_battery Discharging
expect "discharging beeps" beep

set_battery Charging
expect "charging is silent" silent

set_battery Full
expect "full is silent" silent

set_battery "Not charging"
expect "not charging is silent" silent

set_battery Unknown
expect "unknown status is silent" silent

# No battery at all (desktop): must exit 0 quietly, printing nothing.
rm -rf "$tmp/sysfs"
mkdir -p "$tmp/sysfs"
got="$(run_beeper)"
if [ -z "$got" ]; then
  printf 'PASS: no battery present prints nothing\n'
else
  printf 'FAIL: no battery present — want empty output, got %s\n' "$got"
  fail=1
fi

# --- armed / once-per-unplug integration test -----------------------------
# The dry-run cases above only exercise should_beep(); they never run the
# main loop, which is exactly the gap that let two broken upower-waiting
# implementations pass review. Now that the loop is plain sysfs polling
# with no subshell, drive it for real: stub notify-send and play, bound
# the loop with CAFFEINE_BEEP_MAX_ITER, and script a sysfs sequence of
# unplug -> still-unplugged -> replug -> unplug while the loop runs.
# Assert the notification fires exactly twice (once per unplug), not once
# per beep.

stub_bin="$tmp/stubbin"
mkdir -p "$stub_bin"
notify_log="$tmp/notify.log"
: > "$notify_log"

cat > "$stub_bin/notify-send" <<'EOF'
#!/usr/bin/env bash
printf 'NOTIFY\n' >> "$NOTIFY_LOG"
EOF
chmod +x "$stub_bin/notify-send"

# play_tone shells out to `play` (sox); stub it so no audio is ever emitted.
cat > "$stub_bin/play" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$stub_bin/play"

set_battery Discharging # unplugged from the start

(
  sleep 0.4
  set_battery Charging # replugged
  sleep 0.4
  set_battery Discharging # unplugged again
) &
writer_pid=$!

NOTIFY_LOG="$notify_log" PATH="$stub_bin:$PATH" \
CAFFEINE_BEEP_SYSFS="$tmp/sysfs" \
CAFFEINE_BEEP_INTERVAL=0.05 \
CAFFEINE_BEEP_AC_POLL_INTERVAL=0.05 \
CAFFEINE_BEEP_MAX_ITER=30 \
  bash "$BEEPER"

wait "$writer_pid" 2>/dev/null || true

notify_count="$(wc -l < "$notify_log" | tr -d ' ')"
if [ "$notify_count" = "2" ]; then
  printf 'PASS: unplug -> still-unplugged -> replug -> unplug notifies exactly twice (%s)\n' "$notify_count"
else
  printf 'FAIL: expected exactly 2 notifications across unplug/replug/unplug, got %s\n' "$notify_count"
  fail=1
fi

# --- sink volume floor ----------------------------------------------------
# The tone is played at full *stream* amplitude, but the sink's own volume
# still applies on top of it — so a muted or turned-down output made the alarm
# inaudible, which is the whole point of the mode. play_tone must floor the
# sink and unmute it for the duration of the tone, then put the user's exact
# prior volume and mute state back.

wpctl_log="$tmp/wpctl.log"

# Stub wpctl: `get-volume` replays a scripted sink state (or fails, to model an
# unreachable wireplumber); everything else is logged instead of applied.
cat > "$stub_bin/wpctl" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = "get-volume" ]; then
  [ -n "${WPCTL_FAIL:-}" ] && exit 1
  printf '%s\n' "${WPCTL_STATE:-}"
  exit 0
fi
printf '%s\n' "$*" >> "$WPCTL_LOG"
EOF
chmod +x "$stub_bin/wpctl"

# One pass of the main loop over a discharging battery is exactly one beep.
run_one_beep() { # sink-state [fail]
  : > "$wpctl_log"
  set_battery Discharging
  NOTIFY_LOG="$notify_log" PATH="$stub_bin:$PATH" \
  WPCTL_LOG="$wpctl_log" WPCTL_STATE="$1" WPCTL_FAIL="${2:-}" \
  CAFFEINE_BEEP_SYSFS="$tmp/sysfs" \
  CAFFEINE_BEEP_INTERVAL=0.01 \
  CAFFEINE_BEEP_AC_POLL_INTERVAL=0.01 \
  CAFFEINE_BEEP_MAX_ITER=1 \
    bash "$BEEPER"
}

expect_wpctl() { # desc want-semicolon-joined
  local got
  got="$(tr '\n' ';' < "$wpctl_log")"
  if [ "$got" = "$2" ]; then
    printf 'PASS: %s\n' "$1"
  else
    printf 'FAIL: %s — want [%s], got [%s]\n' "$1" "$2" "$got"
    fail=1
  fi
}

SINK='@DEFAULT_AUDIO_SINK@'

run_one_beep 'Volume: 0.20 [MUTED]'
expect_wpctl "muted sink is raised and unmuted, then re-muted and restored" \
  "set-volume $SINK 0.6;set-mute $SINK 0;set-mute $SINK 1;set-volume $SINK 0.20;"

run_one_beep 'Volume: 0.20'
expect_wpctl "quiet sink is raised to the floor, then restored" \
  "set-volume $SINK 0.6;set-volume $SINK 0.20;"

run_one_beep 'Volume: 0.80'
expect_wpctl "sink above the floor is left completely alone" ""

run_one_beep 'Volume: 0.60'
expect_wpctl "sink exactly at the floor is left completely alone" ""

# wireplumber unreachable: degrade to playing the tone and hope, never die.
if run_one_beep 'Volume: 0.20' 1; then
  expect_wpctl "unreachable wireplumber touches nothing" ""
else
  printf 'FAIL: unreachable wireplumber killed the beeper\n'
  fail=1
fi

if [ "$fail" -eq 0 ]; then
  printf '\nAll caffeine-beeper tests passed.\n'
else
  printf '\nSome caffeine-beeper tests FAILED.\n'
  exit 1
fi
