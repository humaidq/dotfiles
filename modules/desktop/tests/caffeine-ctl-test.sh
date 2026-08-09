#!/usr/bin/env bash
# State-machine tests for caffeine-ctl: PATH stubs, no real inhibitor or units.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CTL="$SCRIPT_DIR/../caffeine-ctl.sh"

tmp="$(mktemp -d)"
cleanup() {
  # kill any stub inhibitor still alive
  if [ -f "$tmp/inhibit.pid" ]; then
    kill "$(cat "$tmp/inhibit.pid" 2>/dev/null || true)" 2>/dev/null || true
  fi
  rm -rf "$tmp"
}
trap cleanup EXIT

fail=0

# --- PATH stubs -------------------------------------------------------------
mkdir -p "$tmp/bin"

cat > "$tmp/bin/systemd-inhibit" <<'EOF'
#!/usr/bin/env bash
# Ignore all the --what/--why/--who/--mode flags and just be a long-lived proc.
exec sleep 300
EOF

cat > "$tmp/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$SYSTEMCTL_LOG"
EOF

cat > "$tmp/bin/notify-send" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

chmod +x "$tmp/bin/systemd-inhibit" "$tmp/bin/systemctl" "$tmp/bin/notify-send"

export SYSTEMCTL_LOG="$tmp/systemctl.log"
: > "$SYSTEMCTL_LOG"

run_ctl() {
  PATH="$tmp/bin:$PATH" \
  CAFFEINE_MODE_FILE="$tmp/mode" \
  CAFFEINE_INHIBIT_FILE="$tmp/inhibit.pid" \
  CAFFEINE_BEEPER_UNIT="caffeine-beeper" \
  CAFFEINE_INHIBIT_MATCH="sleep" \
    bash "$CTL" "$@"
}

check() { # desc want got
  if [ "$2" = "$3" ]; then
    printf 'PASS: %s (%s)\n' "$1" "$3"
  else
    printf 'FAIL: %s — want %s, got %s\n' "$1" "$2" "$3"
    fail=1
  fi
}

inhibitor_state() { # -> alive|dead
  local pid
  [ -f "$tmp/inhibit.pid" ] || { printf 'dead\n'; return 0; }
  pid="$(cat "$tmp/inhibit.pid" 2>/dev/null || true)"
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    printf 'alive\n'
  else
    printf 'dead\n'
  fi
}

last_beeper_call() { # -> the most recent "--user start|stop caffeine-beeper" line, or "none"
  local line
  line="$(grep -E 'caffeine-beeper$' "$SYSTEMCTL_LOG" | tail -n 1 || true)"
  if [ -z "$line" ]; then printf 'none\n'; else printf '%s\n' "$line"; fi
}

# --- clean slate ------------------------------------------------------------
check "status with no state at all" decaf "$(run_ctl status)"

# --- cycle: decaf -> caffeine ----------------------------------------------
run_ctl cycle
check "cycle 1 mode file" caffeine "$(cat "$tmp/mode")"
check "cycle 1 status" caffeine "$(run_ctl status)"
check "cycle 1 inhibitor" alive "$(inhibitor_state)"
check "cycle 1 beeper stopped" "--user stop caffeine-beeper" "$(last_beeper_call)"

# --- cycle: caffeine -> double ---------------------------------------------
run_ctl cycle
check "cycle 2 mode file" double "$(cat "$tmp/mode")"
check "cycle 2 status" double "$(run_ctl status)"
check "cycle 2 inhibitor" alive "$(inhibitor_state)"
check "cycle 2 beeper started" "--user start caffeine-beeper" "$(last_beeper_call)"

# --- cycle: double -> decaf -------------------------------------------------
run_ctl cycle
check "cycle 3 mode file" decaf "$(cat "$tmp/mode")"
check "cycle 3 status" decaf "$(run_ctl status)"
check "cycle 3 inhibitor" dead "$(inhibitor_state)"
check "cycle 3 beeper stopped" "--user stop caffeine-beeper" "$(last_beeper_call)"

# --- set decaf from double tears down both ---------------------------------
run_ctl set double
check "set double inhibitor" alive "$(inhibitor_state)"
run_ctl set decaf
check "set decaf from double: inhibitor" dead "$(inhibitor_state)"
check "set decaf from double: beeper" "--user stop caffeine-beeper" "$(last_beeper_call)"

# --- set is idempotent: no orphaned second inhibitor ------------------------
run_ctl set caffeine
first_pid="$(cat "$tmp/inhibit.pid")"
run_ctl set caffeine
second_pid="$(cat "$tmp/inhibit.pid")"
check "set caffeine twice keeps one inhibitor" "$first_pid" "$second_pid"
check "set caffeine twice still alive" alive "$(inhibitor_state)"

# --- reconciliation: stale mode file, dead inhibitor ------------------------
kill "$(cat "$tmp/inhibit.pid")" 2>/dev/null || true
sleep 0.2
printf 'double\n' > "$tmp/mode"
check "stale double + dead inhibitor reports decaf" decaf "$(run_ctl status)"
run_ctl cycle
check "cycle from stale state advances to caffeine" caffeine "$(cat "$tmp/mode")"

# --- inhibitor alive but mode file missing ----------------------------------
rm -f "$tmp/mode"
check "alive inhibitor, no mode file reports caffeine" caffeine "$(run_ctl status)"

# --- PID-reuse: stale PID that no longer matches inhibit pattern ----------------
# Simulate PID reuse: start a process that doesn't contain "sleep" in its cmdline,
# write its PID to inhibit file, and verify status reports decaf.
unrelated_pid=""
tail -f /dev/null &
unrelated_pid=$!
printf '%s' "$unrelated_pid" > "$tmp/inhibit.pid"
printf 'double\n' > "$tmp/mode"
# status should report decaf because tail -f doesn't match "sleep"
check "stale PID (cmdline mismatch) reports decaf" decaf "$(run_ctl status)"
# Clean up the unrelated process
kill "$unrelated_pid" 2>/dev/null || true
rm -f "$tmp/inhibit.pid"

# --- bad input --------------------------------------------------------------
if run_ctl set espresso >/dev/null 2>&1; then
  printf 'FAIL: set with an unknown mode should exit non-zero\n'
  fail=1
else
  printf 'PASS: set with an unknown mode exits non-zero\n'
fi

if [ "$fail" -eq 0 ]; then
  printf '\nAll caffeine-ctl tests passed.\n'
else
  printf '\nSome caffeine-ctl tests FAILED.\n'
  exit 1
fi
