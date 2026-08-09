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

if [ "$fail" -eq 0 ]; then
  printf '\nAll caffeine-beeper tests passed.\n'
else
  printf '\nSome caffeine-beeper tests FAILED.\n'
  exit 1
fi
