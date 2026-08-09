# Triple-state caffeine mode (decaf / caffeine / double) — design

Date: 2026-08-09
Status: Approved, ready for implementation plan

## Problem

`Super+c` currently runs `caffeine-toggle`, a two-state toggle: sleep inhibited
or not. The user wants a third state, "double caffeine", that additionally
raises an audible alarm whenever the laptop is running on battery — an
"unplugged my laptop" alert — and clearer naming for the existing states.

## Goals

1. Three modes cycled by a single `Super+c` press:
   `decaf → caffeine → double → decaf`.
   - `decaf` — normal behavior, machine sleeps.
   - `caffeine` — sleep inhibited (today's behavior).
   - `double` — sleep inhibited **and** an audible beep loop while on battery.
2. In `double`, while the power status is `Discharging`: 0.2s tone, 2s silence,
   repeat indefinitely. On AC the beeper is silent but stays armed.
3. The existing low-battery safety net keeps working and covers the new mode: at
   ≤20% on battery, any caffeine state collapses to `decaf` — inhibitor cleared,
   beeping stopped, normal sleep restored.

## Non-goals (YAGNI)

- No extra keybinding to jump straight to `decaf`; the cycle is enough.
- No per-host NixOS options for tone frequency, duration, or interval. Env
  overrides are sufficient, matching `battery-guard`.
- No mutation of global audio state (unmute / volume floor / restore). See
  "Known limitation" below.
- No escalation of the beep (louder or faster over time).
- No auto-restore of the previous mode after `battery-guard` intervenes.

## Key facts about the existing setup

- `modules/desktop/wayland-services.nix` defines `caffeine-toggle`, which runs
  `systemd-inhibit --what=idle:sleep:handle-lid-switch ... sleep infinity &` and
  stores the PID in `/tmp/caffeine-inhibit-$USER.pid`.
- `suspend-if-allowed` (swayidle, 600s) skips suspend while that PID is alive.
- `battery-guard.sh` reads the same PID file via `caffeine_active` and clears it
  via `clear_caffeine` at ≤20% discharging, and at ≤7% clears it and suspends.
- `modules/desktop/sway/default.nix:208` binds `${mod}+c` to `caffeine-toggle`.
- `pcspkr` and `snd_pcsp` are blacklisted in `modules/security/default.nix:169`,
  so a true hardware beep is unavailable. Audio is PipeWire with the Pulse shim
  (`modules/desktop/default.nix`).

## Architecture

### State model

Mode lives in a new state file `/tmp/caffeine-mode-$USER` containing exactly one
of `decaf`, `caffeine`, `double`. A missing or unreadable file means `decaf`.

The existing `/tmp/caffeine-inhibit-$USER.pid` is retained as the
sleep-inhibitor handle, but all three readers of that file now agree on the
same PID-reuse-hardened liveness check — alive *and* `/proc/$pid/cmdline`
matches `*_INHIBIT_MATCH*` — instead of the two-of-three agreement the branch
started with:

- `caffeine-ctl`'s `inhibitor_alive` (the original hardened check).
- `battery-guard`'s `caffeine_active` (hardened alongside it).
- `suspend-if-allowed`, which no longer re-implements a `kill -0` liveness
  check at all — it shells out to `caffeine-ctl status` and suspends only on
  `decaf`, so there is exactly one liveness implementation, not three that can
  drift out of sync.

The two `kill` sites that mutate the PID file — `caffeine-ctl`'s
`stop_inhibitor` and `battery-guard`'s `clear_caffeine` — also gate their
`kill` on that same check before signalling (they still unconditionally
`rm -f` the PID file). This closes a PID-reuse gap the earlier hardening left
open: `battery-guard`'s `decide()` returns `suspend` at ≤7% regardless of
whether caffeine is active, so a stale PID file whose PID had been recycled
by an unrelated process would otherwise get SIGTERM'd at critical battery.

| Mode | Inhibitor PID file | `caffeine-beeper` unit |
|---|---|---|
| `decaf` | absent | stopped |
| `caffeine` | present, alive | stopped |
| `double` | present, alive | running |

The two files can disagree if something external kills the inhibitor, or the
beeper unit stops on its own (crash, or a logout/compositor restart — the
beeper is `partOf graphical-session.target` but the backgrounded inhibitor
process is not a systemd unit and survives, since
`services.logind.killUserProcesses = false`). The mode file is advisory; the
PID file remains authoritative for "is sleep inhibited". `caffeine-ctl`
reconciles on every invocation:

- It derives the current mode as `decaf` whenever the inhibitor PID is dead,
  regardless of the mode file.
- If the mode file says `double` but `systemctl --user is-active --quiet
  caffeine-beeper` says the beeper unit is not active, the reported mode
  downgrades to `caffeine` — `double` means inhibitor-alive *and*
  beeper-running, and reporting a beeper-less `double` would leave the user
  believing an alarm is armed when it silently isn't. This downgrade only
  affects what `status`/`cycle` *report*; the mode file itself is left as
  `double`, so the very next `Super+c` press (`cycle` from the downgraded
  `caffeine` reading) restarts the beeper and returns to `double`, rather than
  advancing past a state that was never actually armed.

### Components

**`caffeine-ctl`** (`pkgs.writeShellApplication`, replaces `caffeine-toggle`)

Subcommands:

- `cycle` — advance `decaf → caffeine → double → decaf`. Bound to `Super+c`.
- `set <decaf|caffeine|double>` — go directly to a mode. Idempotent.
- `status` — print the current reconciled mode to stdout, exit 0.

`set` is the only code path that mutates state; `cycle` reads the current mode
and calls `set`. Transitions:

```
to decaf:     kill inhibitor PID, rm PID file, stop beeper unit, write "decaf"
to caffeine:  ensure inhibitor running, stop beeper unit, write "caffeine"
to double:    ensure inhibitor running, start beeper unit, write "double"
```

Each transition sends one `notify-send`:

- decaf — "☕ Decaf — sleep enabled"
- caffeine — "☕ Caffeine — sleep disabled (locking still works)"
- double — "☕☕ Double caffeine — sleep disabled, will beep on battery"

**`caffeine-beeper.sh` + `caffeine-beeper` user service**

A `systemd.user.service` that is deliberately **not** `wantedBy` any target — it
is started and stopped on demand by `caffeine-ctl`. It is `partOf`
`graphical-session.target` so it dies with the session.

Loop is a pure sysfs poll — there is no event source, unlike `battery-guard`,
which blocks on `upower --monitor`. The beeper never shells out to `upower` at
all: it polls sysfs every `CAFFEINE_BEEP_AC_POLL_INTERVAL` seconds while on AC,
and every `CAFFEINE_BEEP_INTERVAL` seconds while beeping on battery:

```
startup: exit 0 if no BAT* present
armed=1
loop:
  read status from /sys BAT0 (tolerate a failed/empty read — e.g. -EIO from a
    busy EC, or a battery hot-remove — by sleeping CAFFEINE_BEEP_AC_POLL_INTERVAL
    and retrying, rather than dying under set -e)
  if should_beep(status):        # status == "Discharging"
      if armed: notify "🔌 Power lost — double caffeine"; armed=0
      play tone (0.2s), sleep CAFFEINE_BEEP_INTERVAL (2s)
  else:
      armed=1                    # re-arm for the next unplug
      sleep CAFFEINE_BEEP_AC_POLL_INTERVAL (2s)
```

`should_beep` is a pure function taking the status string, so it is unit
testable exactly like `battery-guard`'s `decide`.

The notification fires once per unplug event, re-armed only on return to AC.

**Tone generation**

`sox`: `play -qn synth 0.2 sine 1000 gain -1`, routed through PipeWire's Pulse
shim. `sox` is added to the `wayland-services` package set.

**`battery-guard.sh` changes**

`clear_caffeine` gains two responsibilities beyond killing the PID: write
`decaf` to the mode file, and `systemctl --user stop caffeine-beeper`. Both are
best-effort (`|| true`) so the safety net never fails because of them. The
mode-file path is env-overridable as `BATTERY_GUARD_MODE_FILE` for testing.

`decide()` and every existing test case are untouched — the low/critical
thresholds and their semantics do not change. Because `caffeine_active` tests
the PID file, which `double` also maintains, `double` is already covered by the
20% and 7% rules with no change to the decision logic.

**Keybinding**

`modules/desktop/sway/default.nix:208` becomes
`"${mod}+c" = "exec caffeine-ctl cycle";`.

## Known limitation

The chosen approach plays the tone at maximum *stream* amplitude but does not
touch the sink. A muted or turned-down output device will therefore attenuate or
silence the alarm. Guaranteeing audibility would require force-unmuting and
raising the sink volume, then restoring it — rejected here because it mutates
global audio state and the restore is unreliable if the process is killed. This
is a deliberate, accepted trade-off.

## Environment overrides

For `caffeine-ctl` and `caffeine-beeper` (testing and tuning, not NixOS
options), following the `battery-guard` precedent:

- `CAFFEINE_MODE_FILE` (default `/tmp/caffeine-mode-$USER`)
- `CAFFEINE_INHIBIT_FILE` (default `/tmp/caffeine-inhibit-$USER.pid`)
- `CAFFEINE_INHIBIT_MATCH` (default `systemd-inhibit`) — substring
  `inhibitor_alive()` requires in `/proc/$pid/cmdline` before treating the PID
  file as live, guarding both the read path and the `stop_inhibitor` kill path
  against PID reuse
- `CAFFEINE_BEEPER_UNIT` (default `caffeine-beeper`)
- `CAFFEINE_BEEP_SYSFS` (default `/sys/class/power_supply`) — point at a fixture
- `CAFFEINE_BEEP_DURATION` (default `0.2`)
- `CAFFEINE_BEEP_INTERVAL` (default `2`)
- `CAFFEINE_BEEP_FREQ` (default `1000`)
- `CAFFEINE_BEEP_AC_POLL_INTERVAL` (default `2`) — poll period while on AC,
  and the retry delay after a transient sysfs read failure
- `CAFFEINE_BEEP_DRY_RUN` — print `beep` / `silent` instead of playing
- `CAFFEINE_BEEP_MAX_ITER` (default `0`, meaning run forever) — test-only
  escape hatch bounding the number of main-loop iterations, so a test can
  drive the loop over a scripted sysfs sequence and let it exit on its own
- `BATTERY_GUARD_MODE_FILE` (default `/tmp/caffeine-mode-$USER`, the same path
  as `CAFFEINE_MODE_FILE`)
- `BATTERY_GUARD_BEEPER_UNIT` (default `caffeine-beeper`)
- `BATTERY_GUARD_ONCE` — perform real actions once, then exit (testing only)
- `BATTERY_GUARD_INHIBIT_MATCH` (default `systemd-inhibit`) — substring
  `caffeine_active` requires in `/proc/$pid/cmdline` before treating the PID
  file as live, mirroring `caffeine-ctl`'s `CAFFEINE_INHIBIT_MATCH`/
  `inhibitor_alive()` hardening against PID reuse; also gates the
  `clear_caffeine` kill path, not just the read path

## Testing

New `modules/desktop/tests/caffeine-ctl-test.sh`, in the style of
`battery-guard-test.sh` (standalone shell script, run manually — the existing
test is not wired into `nix flake check` either):

- Full cycle from a clean slate: `decaf → caffeine → double → decaf`, asserting
  the mode file contents, inhibitor liveness, and beeper start/stop calls at
  each step. `systemctl` is stubbed on `PATH` to record invocations and to
  track each unit's active/inactive state, so `is-active --quiet` answers
  honestly.
- `set decaf` from `double` stops both the inhibitor and the beeper.
- `set` is idempotent: `set caffeine` twice leaves one live inhibitor.
- Reconciliation: with a stale mode file of `double` but a dead inhibitor PID,
  `status` reports `decaf` and `cycle` advances to `caffeine`.
- Cmdline hardening: a live PID whose `/proc/$pid/cmdline` doesn't match
  `CAFFEINE_INHIBIT_MATCH` (simulated PID reuse) is treated as dead —
  `status` reports `decaf`.
- I1 downgrade: with the beeper unit forced `inactive` behind
  `caffeine-ctl`'s back (simulating a crash or a logout that stopped the
  `partOf graphical-session.target` unit while the backgrounded inhibitor
  survived), `status` reports `caffeine` even though the mode file still says
  `double`; the mode file itself is left alone; the next `cycle` restarts the
  beeper and returns to `double`.
- I2 kill-path hardening: `stop_inhibitor` (via `set decaf`) does not signal a
  PID-reuse-mismatched PID, but still removes the stale inhibit file.

New `modules/desktop/tests/caffeine-beeper-test.sh`:

- `should_beep` via `CAFFEINE_BEEP_DRY_RUN` against a fake sysfs:
  `Discharging → beep`; `Charging`, `Full`, `Not charging` → `silent`.
- No `BAT*` in the fixture → exits 0 without beeping.
- Armed / once-per-unplug integration test: drives the real main loop (not
  just `should_beep`) with `notify-send` and `play` stubbed, `notify-send`'s
  invocations logged, and `CAFFEINE_BEEP_MAX_ITER` bounding the loop. Scripts
  a sysfs sequence of unplug → still-unplugged → replug → unplug while the
  loop runs concurrently, and asserts the notification fires exactly twice
  (once per unplug, not once per beep). This is the test that would have
  caught the two prior upower-waiting implementations that never actually
  polled sysfs in a loop.

Extension to `modules/desktop/tests/battery-guard-test.sh`:

- At 20% discharging in `double`, `clear_caffeine` writes `decaf` to the mode
  file and issues the beeper stop.
- Cmdline hardening: a live inhibitor process whose cmdline doesn't match
  `BATTERY_GUARD_INHIBIT_MATCH` is treated as caffeine-inactive.
- I2 kill-path hardening: at ≤7% discharging (where `decide()` returns
  `suspend` regardless of whether caffeine is active), `clear_caffeine` does
  not signal a PID-reuse-mismatched PID, but still removes the stale inhibit
  file.

Manual verification on anoa: enter `double`, unplug, confirm the 0.2s/2s pattern
and the single notification; replug and confirm silence; re-unplug and confirm
the notification re-arms.

## Files touched

- `modules/desktop/wayland-services.nix` — replace `caffeineToggle` with
  `caffeine-ctl`, add the `caffeine-beeper` script and user service, add `sox`.
- `modules/desktop/caffeine-ctl.sh` — new.
- `modules/desktop/caffeine-beeper.sh` — new.
- `modules/desktop/battery-guard.sh` — extend `clear_caffeine`.
- `modules/desktop/sway/default.nix` — rebind `${mod}+c`.
- `modules/desktop/tests/caffeine-ctl-test.sh` — new.
- `modules/desktop/tests/caffeine-beeper-test.sh` — new.
- `modules/desktop/tests/battery-guard-test.sh` — one added case.
