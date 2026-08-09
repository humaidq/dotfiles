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

The existing `/tmp/caffeine-inhibit-$USER.pid` is retained **unchanged** as the
sleep-inhibitor handle, so `suspend-if-allowed` and `battery-guard`'s
`caffeine_active` keep working with no change to their logic.

| Mode | Inhibitor PID file | `caffeine-beeper` unit |
|---|---|---|
| `decaf` | absent | stopped |
| `caffeine` | present, alive | stopped |
| `double` | present, alive | running |

The two files can disagree if something external kills the inhibitor. The mode
file is advisory; the PID file remains authoritative for "is sleep inhibited".
`caffeine-ctl` reconciles on every invocation: it derives the current mode as
`decaf` whenever the inhibitor PID is dead, regardless of the mode file.

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

Loop, mirroring `battery-guard`'s structure (sysfs is authoritative,
`upower --monitor` only wakes the loop):

```
startup: exit 0 if no BAT* present
armed=1
loop:
  read status from /sys BAT0
  if should_beep(status):        # status == "Discharging"
      if armed: notify "🔌 Power lost — double caffeine"; armed=0
      play tone (0.2s), sleep 2
  else:
      armed=1                    # re-arm for the next unplug
      block on upower --monitor / sleep poll
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
- `CAFFEINE_BEEP_SYSFS` (default `/sys/class/power_supply`) — point at a fixture
- `CAFFEINE_BEEP_DURATION` (default `0.2`)
- `CAFFEINE_BEEP_INTERVAL` (default `2`)
- `CAFFEINE_BEEP_FREQ` (default `1000`)
- `CAFFEINE_BEEP_DRY_RUN` — print `beep` / `silent` instead of playing
- `BATTERY_GUARD_MODE_FILE` (default `/tmp/caffeine-mode-$USER`, the same path
  as `CAFFEINE_MODE_FILE`)

## Testing

New `modules/desktop/tests/caffeine-ctl-test.sh`, in the style of
`battery-guard-test.sh` (standalone shell script, run manually — the existing
test is not wired into `nix flake check` either):

- Full cycle from a clean slate: `decaf → caffeine → double → decaf`, asserting
  the mode file contents, inhibitor liveness, and beeper start/stop calls at
  each step. `systemctl` is stubbed on `PATH` to record invocations.
- `set decaf` from `double` stops both the inhibitor and the beeper.
- `set` is idempotent: `set caffeine` twice leaves one live inhibitor.
- Reconciliation: with a stale mode file of `double` but a dead inhibitor PID,
  `status` reports `decaf` and `cycle` advances to `caffeine`.

New `modules/desktop/tests/caffeine-beeper-test.sh`:

- `should_beep` via `CAFFEINE_BEEP_DRY_RUN` against a fake sysfs:
  `Discharging → beep`; `Charging`, `Full`, `Not charging` → `silent`.
- No `BAT*` in the fixture → exits 0 without beeping.

Extension to `modules/desktop/tests/battery-guard-test.sh`:

- At 20% discharging in `double`, `clear_caffeine` writes `decaf` to the mode
  file and issues the beeper stop.

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
