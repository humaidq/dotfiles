# Triple-State Caffeine Mode Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the two-state `caffeine-toggle` with a three-state `caffeine-ctl` (`decaf` → `caffeine` → `double`), where `double` additionally beeps 0.2s every 2.2s while the laptop runs on battery.

**Architecture:** Two new standalone bash scripts (`caffeine-ctl.sh`, `caffeine-beeper.sh`) live beside the existing `battery-guard.sh` in `modules/desktop/`, are wrapped with `pkgs.writeShellApplication` in `modules/desktop/wayland-services.nix`, and are tested by standalone shell scripts in `modules/desktop/tests/` using fake sysfs fixtures and `PATH` stubs. The beeper is an on-demand systemd user unit that `caffeine-ctl` starts and stops. The existing `/tmp/caffeine-inhibit-$USER.pid` remains the authoritative sleep-inhibitor handle so `suspend-if-allowed` and `battery-guard` keep working.

**Tech Stack:** NixOS module (`modules/desktop/`), bash, `systemd-inhibit`, systemd user services, `sox` (`play`) over PipeWire's PulseAudio shim, `upower`, `libnotify`.

**Design doc:** `docs/superpowers/specs/2026-08-09-triple-caffeine-design.md`

## Global Constraints

- Spec: `docs/superpowers/specs/2026-08-09-triple-caffeine-design.md`. Read it before starting.
- Tone parameters, copied verbatim from the spec: duration `0.2` seconds, silence interval `2` seconds, frequency `1000` Hz.
- Mode values are exactly the strings `decaf`, `caffeine`, `double`. No other spellings.
- Default state paths: mode `/tmp/caffeine-mode-$USER`, inhibitor `/tmp/caffeine-inhibit-$USER.pid`.
- The systemd user unit name is exactly `caffeine-beeper`.
- Do NOT change `battery-guard.sh`'s `decide()` function or any existing case in `modules/desktop/tests/battery-guard-test.sh`. The 20% / 7% thresholds and their semantics are unchanged.
- Do NOT mutate global audio state (no unmute, no sink volume changes). This is a deliberate accepted trade-off recorded in the spec's "Known limitation" section.
- All shell scripts start with `# shellcheck shell=bash` and `set -euo pipefail`, matching `modules/desktop/battery-guard.sh`.
- Commit with `--no-gpg-sign` (per `CLAUDE.md`; the signing key is a hardware key).
- Run `nix fmt` before each commit that touches a `.nix` or `.sh` file — it runs nixfmt, deadnix, statix and shellcheck.
- `nix flake check` is the real gate and must pass before the final commit.

---

### Task 1: `caffeine-ctl` state machine

**Files:**
- Create: `modules/desktop/caffeine-ctl.sh`
- Test: `modules/desktop/tests/caffeine-ctl-test.sh`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces:
  - Executable `caffeine-ctl` with subcommands `cycle`, `set <decaf|caffeine|double>`, `status`. `status` prints one of `decaf` / `caffeine` / `double` on stdout.
  - Env overrides `CAFFEINE_MODE_FILE`, `CAFFEINE_INHIBIT_FILE`, `CAFFEINE_BEEPER_UNIT`.
  - Mode-file path default `/tmp/caffeine-mode-${USER}`, consumed by Task 3.
  - Beeper unit name default `caffeine-beeper`, consumed by Tasks 3 and 4.

- [ ] **Step 1: Write the failing test**

Create `modules/desktop/tests/caffeine-ctl-test.sh`. It stubs `systemd-inhibit`, `systemctl` and `notify-send` on `PATH` so nothing real is touched: the `systemd-inhibit` stub just becomes a long `sleep`, and the `systemctl` stub appends its arguments to a log file the test asserts against.

```bash
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash modules/desktop/tests/caffeine-ctl-test.sh`
Expected: FAIL — `bash: modules/desktop/../caffeine-ctl.sh: No such file or directory`

- [ ] **Step 3: Write minimal implementation**

Create `modules/desktop/caffeine-ctl.sh`. Note the `if` blocks around `kill` — `&&`/`||` chains interact badly with `set -e`, and shellcheck (run by `nix fmt`) flags them.

```bash
# shellcheck shell=bash
# caffeine-ctl — three-state sleep inhibition: decaf / caffeine / double.
# `double` additionally runs the caffeine-beeper unit, which beeps while on
# battery. The inhibitor PID file is authoritative for "is sleep inhibited";
# the mode file is advisory and reconciled against it on every invocation.
set -euo pipefail

MODE_FILE="${CAFFEINE_MODE_FILE:-/tmp/caffeine-mode-${USER:-unknown}}"
INHIBIT_FILE="${CAFFEINE_INHIBIT_FILE:-/tmp/caffeine-inhibit-${USER:-unknown}.pid}"
BEEPER_UNIT="${CAFFEINE_BEEPER_UNIT:-caffeine-beeper}"

inhibitor_alive() {
  [ -f "$INHIBIT_FILE" ] || return 1
  local pid
  pid="$(cat "$INHIBIT_FILE" 2>/dev/null || true)"
  [ -n "$pid" ] || return 1
  kill -0 "$pid" 2>/dev/null
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
    caffeine | double) printf '%s\n' "$mode" ;;
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
    if [ -n "$pid" ]; then
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
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash modules/desktop/tests/caffeine-ctl-test.sh`
Expected: PASS on every line, ending with `All caffeine-ctl tests passed.`

- [ ] **Step 5: Format and commit**

```bash
nix fmt
chmod +x modules/desktop/tests/caffeine-ctl-test.sh
git add modules/desktop/caffeine-ctl.sh modules/desktop/tests/caffeine-ctl-test.sh
git commit --no-gpg-sign -m "desktop: add caffeine-ctl three-state mode machine"
```

---

### Task 2: `caffeine-beeper` battery-watching beep loop

**Files:**
- Create: `modules/desktop/caffeine-beeper.sh`
- Test: `modules/desktop/tests/caffeine-beeper-test.sh`

**Interfaces:**
- Consumes: the `caffeine-beeper` unit name established in Task 1 (this task supplies the script that unit runs).
- Produces:
  - Executable `caffeine-beeper`, a long-running loop, to be wired as a systemd user service in Task 4.
  - Env overrides `CAFFEINE_BEEP_SYSFS`, `CAFFEINE_BEEP_DURATION`, `CAFFEINE_BEEP_INTERVAL`, `CAFFEINE_BEEP_FREQ`, `CAFFEINE_BEEP_DRY_RUN`.
  - Requires `play` (from `sox`), `upower` and `notify-send` on `PATH` — Task 4 supplies these via `runtimeInputs`.

- [ ] **Step 1: Write the failing test**

Create `modules/desktop/tests/caffeine-beeper-test.sh`, modelled directly on `battery-guard-test.sh`: a fake sysfs tree plus dry-run so no audio is ever played.

```bash
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash modules/desktop/tests/caffeine-beeper-test.sh`
Expected: FAIL — `bash: modules/desktop/tests/../caffeine-beeper.sh: No such file or directory`

- [ ] **Step 3: Write minimal implementation**

Create `modules/desktop/caffeine-beeper.sh`. `AUDIODRIVER=pulseaudio` is set explicitly: nixpkgs' `sox` links `libpulse`, and PipeWire's Pulse shim (`services.pipewire.pulse.enable`) is what's running — letting sox autodetect can land on ALSA and fail.

```bash
# shellcheck shell=bash
# caffeine-beeper — while on battery, emit a short tone every few seconds.
# Started and stopped on demand by caffeine-ctl for the "double" mode.
# Authoritative power state comes from sysfs; `upower --monitor` only wakes
# the loop while on AC. Dry-run prints the decision and exits.
set -euo pipefail

SYSFS="${CAFFEINE_BEEP_SYSFS:-/sys/class/power_supply}"
DURATION="${CAFFEINE_BEEP_DURATION:-0.2}"
INTERVAL="${CAFFEINE_BEEP_INTERVAL:-2}"
FREQ="${CAFFEINE_BEEP_FREQ:-1000}"
DRY_RUN="${CAFFEINE_BEEP_DRY_RUN:-}"

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
      if command -v upower >/dev/null 2>&1; then
        timeout 60 upower --monitor >/dev/null 2>&1 || true
      else
        sleep 10
      fi
    fi
  done
}

main "$@"
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash modules/desktop/tests/caffeine-beeper-test.sh`
Expected: PASS on every line, ending with `All caffeine-beeper tests passed.`

- [ ] **Step 5: Verify the tone actually plays on this machine**

This is the one thing the dry-run test cannot cover. Run by hand:

```bash
nix shell nixpkgs#sox -c env AUDIODRIVER=pulseaudio play -qn synth 0.2 sine 1000 gain -1
```

Expected: a single audible 0.2s tone. If it errors with a driver problem, the fallback is to generate a WAV once and play it with `pw-play`:
`sox -n /tmp/beep.wav synth 0.2 sine 1000 gain -1 && pw-play /tmp/beep.wav`
— if you need the fallback, replace the body of `play_tone` with that two-step form (generating the WAV once at startup into `${XDG_RUNTIME_DIR:-/tmp}/caffeine-beep.wav`) and add `pkgs.pipewire` to `runtimeInputs` in Task 4.

- [ ] **Step 6: Format and commit**

```bash
nix fmt
chmod +x modules/desktop/tests/caffeine-beeper-test.sh
git add modules/desktop/caffeine-beeper.sh modules/desktop/tests/caffeine-beeper-test.sh
git commit --no-gpg-sign -m "desktop: add caffeine-beeper on-battery tone loop"
```

---

### Task 3: Teach `battery-guard` to collapse double caffeine to decaf

**Files:**
- Modify: `modules/desktop/battery-guard.sh:11` (add env vars), `modules/desktop/battery-guard.sh:32-41` (`clear_caffeine`), `modules/desktop/battery-guard.sh:89-109` (`main`, add a run-once escape)
- Test: `modules/desktop/tests/battery-guard-test.sh` (append new cases; do not touch existing ones)

**Interfaces:**
- Consumes: the mode file path and `decaf` mode string from Task 1; the `caffeine-beeper` unit name from Task 1.
- Produces: `clear_caffeine` now also writes `decaf` to the mode file and stops the beeper unit. New env overrides `BATTERY_GUARD_MODE_FILE`, `BATTERY_GUARD_BEEPER_UNIT`, `BATTERY_GUARD_ONCE`.

**Note on `BATTERY_GUARD_ONCE`:** the spec's env list does not include it. It is needed because the existing `BATTERY_GUARD_DRY_RUN` short-circuits *before* any side effect, so there is no way to test the real `clear_caffeine` without entering the infinite monitor loop. `BATTERY_GUARD_ONCE=1` performs the real actions exactly once and exits. Add it to the spec's env-override list in the same commit.

- [ ] **Step 1: Write the failing test**

Append to `modules/desktop/tests/battery-guard-test.sh`, immediately **before** the final `if [ "$fail" -eq 0 ]` summary block. The existing cases and helpers above it stay exactly as they are.

```bash
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash modules/desktop/tests/battery-guard-test.sh`
Expected: the original cases still PASS, then the new ones FAIL — the mode file still reads `double` because `clear_caffeine` doesn't write it, and no `--user stop caffeine-beeper` line is logged. (`BATTERY_GUARD_ONCE` is not honoured yet, so the run may also hang in the monitor loop; if it does, Ctrl-C — that is itself the expected failure.)

- [ ] **Step 3: Write minimal implementation**

Edit `modules/desktop/battery-guard.sh`. Add the two new env vars after the existing `INHIBIT_FILE` line (currently line 11):

```bash
MODE_FILE="${BATTERY_GUARD_MODE_FILE:-/tmp/caffeine-mode-${USER:-unknown}}"
BEEPER_UNIT="${BATTERY_GUARD_BEEPER_UNIT:-caffeine-beeper}"
ONCE="${BATTERY_GUARD_ONCE:-}"
```

Replace `clear_caffeine` (currently lines 32-41) with:

```bash
clear_caffeine() {
  local pid=""
  if [ -f "$INHIBIT_FILE" ]; then
    pid="$(cat "$INHIBIT_FILE" 2>/dev/null || true)"
    if [ -n "$pid" ]; then
      kill "$pid" 2>/dev/null || true
    fi
    rm -f "$INHIBIT_FILE"
  fi
  # Collapse caffeine-ctl's mode to decaf and silence the beeper. Both are
  # best-effort: the safety net must never fail because of them.
  printf 'decaf\n' > "$MODE_FILE" 2>/dev/null || true
  systemctl --user stop "$BEEPER_UNIT" 2>/dev/null || true
}
```

In `main` (currently lines 89-109), add the run-once escape immediately after the existing `run_once` call and its dry-run exit:

```bash
  run_once
  if [ -n "$DRY_RUN" ]; then exit 0; fi
  if [ -n "$ONCE" ]; then exit 0; fi
```

Leave `decide()` and everything else untouched.

- [ ] **Step 4: Run test to verify it passes**

Run: `bash modules/desktop/tests/battery-guard-test.sh`
Expected: every case PASSes — the eight original ones and the five new ones — ending with `All battery-guard tests passed.`

- [ ] **Step 5: Record the new env var in the spec**

Add to the "Environment overrides" list in `docs/superpowers/specs/2026-08-09-triple-caffeine-design.md`:

```markdown
- `CAFFEINE_BEEPER_UNIT` (default `caffeine-beeper`)
- `BATTERY_GUARD_BEEPER_UNIT` (default `caffeine-beeper`)
- `BATTERY_GUARD_ONCE` — perform real actions once, then exit (testing only)
```

- [ ] **Step 6: Format and commit**

```bash
nix fmt
git add modules/desktop/battery-guard.sh modules/desktop/tests/battery-guard-test.sh docs/superpowers/specs/2026-08-09-triple-caffeine-design.md
git commit --no-gpg-sign -m "desktop: battery-guard collapses double caffeine to decaf"
```

---

### Task 4: Wire into NixOS and rebind Super+c

**Files:**
- Modify: `modules/desktop/wayland-services.nix:14-38` (replace `caffeineToggle`), `:54-63` (add the beeper package), `:102-111` (`environment.systemPackages`), `:113-151` (`systemd.user.services`)
- Modify: `modules/desktop/sway/default.nix:208` (rebind)

**Interfaces:**
- Consumes: `modules/desktop/caffeine-ctl.sh` (Task 1) and `modules/desktop/caffeine-beeper.sh` (Task 2).
- Produces: `caffeine-ctl` and `caffeine-beeper` on `PATH`; the `caffeine-beeper` systemd user unit; `Super+c` bound to `caffeine-ctl cycle`.

- [ ] **Step 1: Replace the `caffeineToggle` binding with `caffeineCtl`**

In `modules/desktop/wayland-services.nix`, delete the whole `caffeineToggle = pkgs.writeShellScriptBin "caffeine-toggle" '' ... '';` block (lines 14-38, including the `# Caffeine toggle script to prevent sleep` comment) and put in its place:

```nix
  # Three-state sleep inhibition: decaf / caffeine / double (beeps on battery).
  caffeineCtl = pkgs.writeShellApplication {
    name = "caffeine-ctl";
    runtimeInputs = with pkgs; [
      coreutils
      libnotify
      systemd
    ];
    text = builtins.readFile ./caffeine-ctl.sh;
  };

  caffeineBeeper = pkgs.writeShellApplication {
    name = "caffeine-beeper";
    runtimeInputs = with pkgs; [
      coreutils
      libnotify
      sox
      upower
      systemd
    ];
    text = builtins.readFile ./caffeine-beeper.sh;
  };
```

Leave `suspendIfAllowed` (lines 40-52) exactly as it is — it reads the same inhibitor PID file, which is unchanged.

- [ ] **Step 2: Swap the packages in `environment.systemPackages`**

In the `environment.systemPackages` list (currently lines 102-111), replace `caffeineToggle` with:

```nix
      caffeineCtl
      caffeineBeeper
```

- [ ] **Step 3: Add the on-demand beeper user service**

In the `systemd.user.services` attrset (currently starting line 113), add a `caffeine-beeper` entry alongside `cliphist` and `wlsunset`. It is deliberately **not** `wantedBy` anything — `caffeine-ctl` starts it — but `partOf graphical-session.target` so it dies with the session.

```nix
      caffeine-beeper = {
        enable = true;
        description = "Beep while on battery (double caffeine mode)";
        # Started on demand by caffeine-ctl, so no wantedBy.
        serviceConfig = {
          Type = "simple";
          ExecStart = lib.getExe caffeineBeeper;
        };
        partOf = [ "graphical-session.target" ];
      };
```

- [ ] **Step 4: Rebind Super+c**

In `modules/desktop/sway/default.nix:208`, change:

```nix
            "${mod}+c" = "exec caffeine-toggle";
```

to:

```nix
            "${mod}+c" = "exec caffeine-ctl cycle";
```

- [ ] **Step 5: Confirm nothing else still refers to the old name**

Run: `grep -rn "caffeine-toggle" --include="*.nix" --include="*.sh" .`
Expected: no output. If anything remains, update it to `caffeine-ctl`.

- [ ] **Step 6: Format and build**

```bash
nix fmt
nix build .#nixosConfigurations.anoa.config.system.build.toplevel --no-link
```

Expected: builds cleanly. A failure here is most likely a `writeShellApplication` shellcheck error in one of the two new scripts — fix the script, not the Nix.

- [ ] **Step 7: Run the full gate**

Run: `nix flake check`
Expected: passes.

- [ ] **Step 8: Commit**

```bash
git add modules/desktop/wayland-services.nix modules/desktop/sway/default.nix
git commit --no-gpg-sign -m "desktop: wire caffeine-ctl and caffeine-beeper, rebind Super+c"
```

---

### Task 5: Live verification on anoa

**Files:** none — this task changes nothing, it confirms the previous four.

**Interfaces:**
- Consumes: everything from Tasks 1-4, switched onto the running system.

- [ ] **Step 1: Switch to the new configuration**

```bash
sudo nixos-rebuild switch --flake .#anoa
```

- [ ] **Step 2: Verify the three-state cycle**

Run `caffeine-ctl status` (expect `decaf`), then press `Super+c` and re-check after each press:

| Press | Expected `status` | Expected notification |
|---|---|---|
| 1 | `caffeine` | ☕ Caffeine — Sleep disabled |
| 2 | `double` | ☕☕ Double caffeine |
| 3 | `decaf` | ☕ Decaf — Sleep enabled |

Also confirm the inhibitor is genuinely registered while in `caffeine`:
`systemd-inhibit --list | grep -i caffeine`

- [ ] **Step 3: Verify the beeper lifecycle**

With the laptop **plugged in**, press `Super+c` twice to reach `double`, then:

```bash
systemctl --user is-active caffeine-beeper
```

Expected: `active`, and **silence** — it is armed but on AC.

- [ ] **Step 4: Verify the beep pattern on unplug**

Unplug the power. Expected: one "🔌 Power lost" notification, then a 0.2s tone roughly every 2.2s, indefinitely. Time about 30 seconds of it to confirm the cadence is steady and does not drift or double up.

- [ ] **Step 5: Verify replug silences it and the notification re-arms**

Plug the power back in. Expected: beeping stops within a few seconds, no notification. Unplug again — expected: the "🔌 Power lost" notification fires a second time (the re-arm works) and beeping resumes.

- [ ] **Step 6: Verify the low-battery collapse**

Still in `double` and unplugged, temporarily raise the threshold so it fires immediately rather than waiting for a real 20% drain:

```bash
systemctl --user stop battery-guard
BATTERY_GUARD_LOW=100 BATTERY_GUARD_ONCE=1 battery-guard
```

Expected: the "🔋 Battery low" notification, beeping stops, `caffeine-ctl status` prints `decaf`, and `systemctl --user is-active caffeine-beeper` prints `inactive`. Then restore the real daemon:

```bash
systemctl --user start battery-guard
```

- [ ] **Step 7: Return to a clean state**

```bash
caffeine-ctl set decaf
systemctl --user is-active caffeine-beeper   # expect: inactive
systemd-inhibit --list | grep -i caffeine    # expect: no output
```

---

## Verification Summary

Before considering this done, all of the following must have been run and passed:

- [ ] `bash modules/desktop/tests/caffeine-ctl-test.sh` — all pass
- [ ] `bash modules/desktop/tests/caffeine-beeper-test.sh` — all pass
- [ ] `bash modules/desktop/tests/battery-guard-test.sh` — all pass, originals included
- [ ] `nix fmt` — clean
- [ ] `nix flake check` — passes
- [ ] Task 5 live verification on anoa — every step confirmed
