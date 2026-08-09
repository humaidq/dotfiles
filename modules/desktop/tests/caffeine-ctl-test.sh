#!/usr/bin/env bash
# State-machine tests for caffeine-ctl: PATH stubs, no real inhibitor or units.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CTL="$SCRIPT_DIR/../caffeine-ctl.sh"

tmp="$(mktemp -d)"

# Every PID any stub inhibitor (systemd-inhibit -> sleep 300, or the PID-reuse
# tail -f /dev/null stand-in) is spawned under gets appended here, so cleanup
# can kill all of them — not just whichever one happens to be recorded in
# $tmp/inhibit.pid at exit. Code paths that start a new stub and then
# overwrite the inhibit file with a different PID (or an unrelated PID, for
# the PID-reuse tests) would otherwise orphan the earlier one.
declare -a spawned_pids=()

cleanup() {
  local pid
  for pid in "${spawned_pids[@]}"; do
    [ -n "$pid" ] && kill "$pid" 2>/dev/null || true
  done
  # belt-and-suspenders: also kill whatever is currently recorded in the
  # inhibit file, in case it was never added to spawned_pids.
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
# Redirect away from whatever stdio this stub inherited: it's forked from the
# test script, so leaving it connected to our stdout/stderr would hold a
# piped reader (tail, tee, CI log collector) open until this sleep exits.
exec sleep 300 >/dev/null 2>&1
EOF

# Stub tracks per-unit active/inactive state (in $SYSTEMCTL_STATE_DIR) so
# `is-active --quiet` can answer honestly, instead of always exiting 0 like a
# stub that only logs would — that would make every current_mode check see
# "active" and defeat the I1 downgrade test below.
cat > "$tmp/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$SYSTEMCTL_LOG"
args=("$@")
if [ "${args[0]:-}" = "--user" ]; then
  args=("${args[@]:1}")
fi
cmd="${args[0]:-}"
case "$cmd" in
  start)
    printf 'active\n' > "$SYSTEMCTL_STATE_DIR/${args[1]}"
    ;;
  stop)
    printf 'inactive\n' > "$SYSTEMCTL_STATE_DIR/${args[1]}"
    ;;
  is-active)
    unit="${args[-1]}"
    state="$(cat "$SYSTEMCTL_STATE_DIR/$unit" 2>/dev/null || printf 'inactive\n')"
    [ "$state" = "active" ]
    exit $?
    ;;
esac
exit 0
EOF

cat > "$tmp/bin/notify-send" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

chmod +x "$tmp/bin/systemd-inhibit" "$tmp/bin/systemctl" "$tmp/bin/notify-send"

export SYSTEMCTL_LOG="$tmp/systemctl.log"
: > "$SYSTEMCTL_LOG"
mkdir -p "$tmp/systemctl-state"
export SYSTEMCTL_STATE_DIR="$tmp/systemctl-state"

track_inhibitor() { # record whatever PID is currently in the inhibit file
  local pid
  [ -f "$tmp/inhibit.pid" ] || return 0
  pid="$(cat "$tmp/inhibit.pid" 2>/dev/null || true)"
  [ -n "$pid" ] || return 0
  spawned_pids+=("$pid")
}

run_ctl() {
  PATH="$tmp/bin:$PATH" \
  CAFFEINE_MODE_FILE="$tmp/mode" \
  CAFFEINE_INHIBIT_FILE="$tmp/inhibit.pid" \
  CAFFEINE_BEEPER_UNIT="caffeine-beeper" \
  CAFFEINE_INHIBIT_MATCH="sleep" \
    bash "$CTL" "$@"
  local rc=$?
  track_inhibitor
  return "$rc"
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
  # Anchored to start/stop specifically so the is-active --quiet probes that
  # current_mode's beeper_active() now issues (also logged to SYSTEMCTL_LOG)
  # don't get picked up as if they were start/stop calls.
  local line
  line="$(grep -E '^--user (start|stop) caffeine-beeper$' "$SYSTEMCTL_LOG" | tail -n 1 || true)"
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
tail -f /dev/null >/dev/null 2>&1 &
unrelated_pid=$!
spawned_pids+=("$unrelated_pid")
printf '%s' "$unrelated_pid" > "$tmp/inhibit.pid"
printf 'double\n' > "$tmp/mode"
# status should report decaf because tail -f doesn't match "sleep"
check "stale PID (cmdline mismatch) reports decaf" decaf "$(run_ctl status)"

# --- I2: the kill path must not signal a recycled PID either -----------------
# `set decaf` (stop_inhibitor) must gate its kill on the same cmdline check as
# the read path, so a stale PID file whose PID has been reused by an
# unrelated process is never signalled — only cleaned up.
run_ctl set decaf
if kill -0 "$unrelated_pid" 2>/dev/null; then
  printf 'PASS: %s\n' "stop_inhibitor does not kill a cmdline-mismatched PID"
else
  printf 'FAIL: %s\n' "stop_inhibitor killed an unrelated process on PID reuse"
  fail=1
fi
check "stop_inhibitor still removes the stale inhibit file" gone \
  "$([ -f "$tmp/inhibit.pid" ] && printf 'present\n' || printf 'gone\n')"
# Clean up the unrelated process
kill "$unrelated_pid" 2>/dev/null || true
rm -f "$tmp/inhibit.pid"

# --- I1: double downgrades to caffeine when the beeper unit isn't actually
# active (unit exited on its own, or survived logout while the beeper died) --
run_ctl set double
check "double: beeper active per stub" active "$(cat "$tmp/systemctl-state/caffeine-beeper")"
# Simulate the beeper unit dying on its own, without going through
# caffeine-ctl (e.g. it crashed, or graphical-session.target restart killed
# it while the backgrounded inhibitor survived).
printf 'inactive\n' > "$tmp/systemctl-state/caffeine-beeper"
check "double with dead beeper reports caffeine, not double" caffeine "$(run_ctl status)"
check "double with dead beeper: mode file is untouched (advisory only)" double "$(cat "$tmp/mode")"
check "double with dead beeper: inhibitor still alive" alive "$(inhibitor_state)"
# One Super+c press from the downgraded reading must restore the alarm.
run_ctl cycle
check "cycle from downgraded double restores double" double "$(cat "$tmp/mode")"
check "cycle from downgraded double restarts the beeper" "--user start caffeine-beeper" "$(last_beeper_call)"
check "cycle from downgraded double: status now double" double "$(run_ctl status)"
run_ctl set decaf

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
