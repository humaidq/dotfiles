# Battery Guard for Caffeine Mode Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** On laptops, automatically disable caffeine mode when the battery drops to 20% and suspend-to-RAM at a critical ~7%, so an unattended unplugged machine never dies with unsaved work.

**Architecture:** A small `battery-guard` shell daemon runs as a per-user `systemd` service in the graphical session. It reads authoritative battery state from `/sys/class/power_supply/BAT0/{capacity,status}`, woken by `upower --monitor` events. At ≤20% discharging it clears the caffeine `systemd-inhibit` lock (reusing the existing `/tmp/caffeine-inhibit-$USER.pid` file) and notifies; at ≤7% it force-clears caffeine and calls `systemctl suspend`. UPower's own thresholds are configured as a declarative backstop.

**Tech Stack:** NixOS module (`home-manager`/`systemd.user`), `pkgs.writeShellApplication` (shellcheck-gated), Bash, `upower`, `libnotify`, `systemd`.

## Global Constraints

- Option flags live under `sifr.*`; add new options to a feature-local `options` block (here: `sifr.desktop.wayland-services.batteryGuard.enable`). (Verbatim from CLAUDE.md conventions.)
- Always commit with `--no-gpg-sign` (hardware signing key can't be touched from an agent session). (Verbatim from CLAUDE.md conventions.)
- The real CI gate is `nix flake check`; it must pass locally. Format with `nix fmt` (nixfmt + deadnix + statix + shellcheck).
- Caffeine mechanism is fixed: inhibitor PID lives in `/tmp/caffeine-inhibit-$USER.pid`; a live PID there means caffeine is on.
- Thresholds: disable caffeine at 20%, suspend at 7% (script defaults, env-overridable).
- Chosen critical action is **suspend-to-RAM** (no hibernate) — do not add `boot.resumeDevice` or hibernate config.

---

## File Structure

- **Create** `modules/desktop/battery-guard.sh` — the daemon logic (no shebang; `writeShellApplication` supplies it). Self-contained and directly runnable under `bash` for tests.
- **Create** `modules/desktop/tests/battery-guard-test.sh` — decision-logic test using fake sysfs + dry-run.
- **Modify** `modules/desktop/wayland-services.nix` — add the `batteryGuard` package (`writeShellApplication`), the `sifr.desktop.wayland-services.batteryGuard.enable` option, and the `battery-guard` `systemd.user` service.
- **Modify** `modules/laptop/default.nix` — add the `services.upower` threshold/backstop block.

---

### Task 1: Battery-guard daemon script + decision-logic test

Test-first. The script exposes a dry-run mode (`BATTERY_GUARD_DRY_RUN=1`) that reads state once and prints the chosen action (`none` / `disable-caffeine` / `suspend`) without executing it. The test drives it with a fake sysfs tree and a real background process standing in for the caffeine inhibitor.

**Files:**
- Create: `modules/desktop/battery-guard.sh`
- Test: `modules/desktop/tests/battery-guard-test.sh`

**Interfaces:**
- Consumes: nothing (leaf script).
- Produces: an executable named `battery-guard` (later wrapped by `writeShellApplication` with `meta.mainProgram = "battery-guard"`). Environment overrides it honors: `BATTERY_GUARD_SYSFS` (default `/sys/class/power_supply`), `BATTERY_GUARD_LOW` (20), `BATTERY_GUARD_CRITICAL` (7), `BATTERY_GUARD_DRY_RUN` (unset), `BATTERY_GUARD_INHIBIT_FILE` (default `/tmp/caffeine-inhibit-$USER.pid`). Dry-run prints exactly one of `none|disable-caffeine|suspend`.

- [ ] **Step 1: Write the failing test**

Create `modules/desktop/tests/battery-guard-test.sh`:

```bash
#!/usr/bin/env bash
# Decision-logic tests for battery-guard: fake sysfs + dry-run, no real suspend.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$SCRIPT_DIR/../battery-guard.sh"

tmp="$(mktemp -d)"
caffeine_pid=""
cleanup() {
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
  sleep 300 &
  caffeine_pid=$!
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

if [ "$fail" -eq 0 ]; then
  printf '\nAll battery-guard tests passed.\n'
else
  printf '\nSome battery-guard tests FAILED.\n'
  exit 1
fi
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash modules/desktop/tests/battery-guard-test.sh`
Expected: FAIL — `bash: .../battery-guard.sh: No such file or directory` (script doesn't exist yet).

- [ ] **Step 3: Write the daemon script**

Create `modules/desktop/battery-guard.sh` (no shebang — `writeShellApplication` adds it; safe to run directly with `bash`):

```bash
# battery-guard — on battery, disable caffeine at LOW% and suspend at CRITICAL%.
# Authoritative state is read from sysfs; the event loop is woken by
# `upower --monitor`. Dry-run mode prints the chosen action and exits.
set -euo pipefail

SYSFS="${BATTERY_GUARD_SYSFS:-/sys/class/power_supply}"
LOW="${BATTERY_GUARD_LOW:-20}"
CRITICAL="${BATTERY_GUARD_CRITICAL:-7}"
DRY_RUN="${BATTERY_GUARD_DRY_RUN:-}"
INHIBIT_FILE="${BATTERY_GUARD_INHIBIT_FILE:-/tmp/caffeine-inhibit-${USER:-unknown}.pid}"

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

caffeine_active() {
  [ -f "$INHIBIT_FILE" ] || return 1
  local pid
  pid="$(cat "$INHIBIT_FILE" 2>/dev/null || true)"
  [ -n "$pid" ] || return 1
  kill -0 "$pid" 2>/dev/null
}

clear_caffeine() {
  local pid=""
  if [ -f "$INHIBIT_FILE" ]; then
    pid="$(cat "$INHIBIT_FILE" 2>/dev/null || true)"
    if [ -n "$pid" ]; then
      kill "$pid" 2>/dev/null || true
    fi
    rm -f "$INHIBIT_FILE"
  fi
}

decide() {
  # args: capacity status caffeine(yes|no) -> none|disable-caffeine|suspend
  local capacity="$1" status="$2" caffeine="$3"
  if [ "$status" != "Discharging" ]; then
    printf 'none\n'; return 0
  fi
  if [ "$capacity" -le "$CRITICAL" ]; then
    printf 'suspend\n'; return 0
  fi
  if [ "$capacity" -le "$LOW" ] && [ "$caffeine" = "yes" ]; then
    printf 'disable-caffeine\n'; return 0
  fi
  printf 'none\n'
}

run_once() {
  local bat capacity status caffeine action
  if ! bat="$(find_battery)"; then
    if [ -n "$DRY_RUN" ]; then printf 'none\n'; fi
    return 0
  fi
  capacity="$(cat "$bat/capacity")"
  status="$(cat "$bat/status")"
  if caffeine_active; then caffeine=yes; else caffeine=no; fi
  action="$(decide "$capacity" "$status" "$caffeine")"

  if [ -n "$DRY_RUN" ]; then
    printf '%s\n' "$action"
    return 0
  fi

  case "$action" in
    disable-caffeine)
      clear_caffeine
      notify-send -t 5000 "🔋 Battery low" "Caffeine disabled — sleep re-enabled (${capacity}%)"
      ;;
    suspend)
      clear_caffeine
      notify-send -t 5000 --urgency critical "🔋 Battery critical" "Suspending to save your work (${capacity}%)"
      systemctl suspend
      sleep 5  # debounce after resume so we don't tight-loop on repeated events
      ;;
    none) : ;;
  esac
}

main() {
  if ! find_battery >/dev/null 2>&1; then
    if [ -n "$DRY_RUN" ]; then printf 'none\n'; fi
    exit 0
  fi
  run_once
  if [ -n "$DRY_RUN" ]; then exit 0; fi
  if command -v upower >/dev/null 2>&1; then
    upower --monitor | while read -r _; do
      run_once
    done
  else
    while true; do
      sleep 30
      run_once
    done
  fi
}

main "$@"
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash modules/desktop/tests/battery-guard-test.sh`
Expected: PASS — all 8 lines print `PASS:` and it ends with `All battery-guard tests passed.`

- [ ] **Step 5: Lint the script with shellcheck**

Run: `shellcheck modules/desktop/battery-guard.sh modules/desktop/tests/battery-guard-test.sh`
Expected: no output (clean). If `shellcheck` isn't on PATH: `nix shell nixpkgs#shellcheck -c shellcheck modules/desktop/battery-guard.sh modules/desktop/tests/battery-guard-test.sh`

- [ ] **Step 6: Commit**

```bash
git add modules/desktop/battery-guard.sh modules/desktop/tests/battery-guard-test.sh
git commit --no-gpg-sign -m "feat(desktop): battery-guard daemon script + decision tests"
```

---

### Task 2: Wire battery-guard into wayland-services

Package the script with `writeShellApplication` (this is where shellcheck runs in-build), add the enable option, and register the user service alongside `cliphist`/`wlsunset`.

**Files:**
- Modify: `modules/desktop/wayland-services.nix`

**Interfaces:**
- Consumes: `modules/desktop/battery-guard.sh` (via `builtins.readFile`), and the caffeine PID convention `/tmp/caffeine-inhibit-$USER.pid` already used in this file.
- Produces: option `sifr.desktop.wayland-services.batteryGuard.enable` (bool, default `true`); a `systemd.user` service `battery-guard` bound to `graphical-session.target`.

- [ ] **Step 1: Add the `batteryGuard` package in the `let` block**

In `modules/desktop/wayland-services.nix`, immediately after the `suspendIfAllowed` definition (ends at the line ``  '';`` before `blocate`), add:

```nix
  batteryGuard = pkgs.writeShellApplication {
    name = "battery-guard";
    runtimeInputs = with pkgs; [
      coreutils
      libnotify
      upower
      systemd
    ];
    text = builtins.readFile ./battery-guard.sh;
  };
```

- [ ] **Step 2: Add the enable option**

In the `options.sifr.desktop.wayland-services` block, add `batteryGuard.enable` after the existing `enable` option so the block reads:

```nix
  options.sifr.desktop.wayland-services = {
    enable = lib.mkEnableOption "shared wayland services" // {
      default = swayEnabled || labwcEnabled;
    };
    batteryGuard.enable = lib.mkEnableOption "low-battery guard (auto-disable caffeine, suspend when critical)" // {
      default = true;
    };
  };
```

- [ ] **Step 3: Add `batteryGuard` to system packages**

In `config.environment.systemPackages`, add `batteryGuard` to the list (next to `caffeineToggle` / `suspendIfAllowed`):

```nix
    environment.systemPackages = with pkgs; [
      swayidle
      chayang # gradual screen dimming
      libnotify
      caffeineToggle
      suspendIfAllowed
      batteryGuard
      cliphist # clipboard history
      wl-clipboard
    ];
```

- [ ] **Step 4: Register the user service**

Change the `systemd.user.services` block so the `battery-guard` service is added when enabled. Replace the closing of that block (currently `};` after the `wlsunset` service) so it reads:

```nix
    systemd.user.services = {
      cliphist = {
        enable = true;
        description = "Clipboard history daemon";
        serviceConfig = {
          Type = "simple";
          ExecStart = "${pkgs.wl-clipboard}/bin/wl-paste --watch ${pkgs.cliphist}/bin/cliphist store";
        };
        partOf = [ "graphical-session.target" ];
        wantedBy = [ "graphical-session.target" ];
      };
      wlsunset = {
        enable = true;
        description = "Day/night colour temperature (location from beacondb)";
        serviceConfig = {
          Type = "simple";
          ExecStart = "${wlsunsetBeacondb}/bin/wlsunset-beacondb";
          # Geolocation needs WiFi scans and network; retry until both are up.
          Restart = "on-failure";
          RestartSec = 30;
        };
        partOf = [ "graphical-session.target" ];
        wantedBy = [ "graphical-session.target" ];
      };
    }
    // lib.optionalAttrs cfg.batteryGuard.enable {
      battery-guard = {
        enable = true;
        description = "Disable caffeine and suspend on low battery";
        serviceConfig = {
          Type = "simple";
          ExecStart = lib.getExe batteryGuard;
          Restart = "on-failure";
          RestartSec = 30;
        };
        partOf = [ "graphical-session.target" ];
        wantedBy = [ "graphical-session.target" ];
      };
    };
```

- [ ] **Step 5: Format**

Run: `nix fmt`
Expected: exits 0; `git diff --stat` shows only expected formatting on touched files.

- [ ] **Step 6: Build anoa to verify eval + in-build shellcheck**

Run: `nix build .#nixosConfigurations.anoa.config.system.build.toplevel`
Expected: builds successfully. (`writeShellApplication` runs shellcheck on `battery-guard.sh` during this build; a lint error would fail here.)

- [ ] **Step 7: Commit**

```bash
git add modules/desktop/wayland-services.nix
git commit --no-gpg-sign -m "feat(desktop): run battery-guard as a user service"
```

---

### Task 3: Configure UPower thresholds and backstop

Declare the thresholds in one place and give UPower a last-resort action below our 7% suspend point, so critical battery is still handled if the daemon isn't running.

**Files:**
- Modify: `modules/laptop/default.nix`

**Interfaces:**
- Consumes: nothing from other tasks. `anoa` already sets `services.upower.ignoreLid = true`; these attrs merge without conflict.
- Produces: `services.upower` enabled with `percentageLow=20`, `percentageAction=3`, `criticalPowerAction="PowerOff"`.

- [ ] **Step 1: Add the UPower block**

In `modules/laptop/default.nix`, after the `services.tlp = { ... };` block (ends at line ~57 `};`), add:

```nix
    # Battery thresholds. The battery-guard user service owns the real behavior
    # (disable caffeine at 20%, suspend at 7%); UPower's own action sits below
    # that as a last-resort backstop for when the daemon isn't running.
    services.upower = {
      enable = true;
      usePercentageForPolicy = true;
      percentageLow = 20;
      percentageCritical = 10;
      percentageAction = 3;
      criticalPowerAction = "PowerOff";
    };
```

- [ ] **Step 2: Format**

Run: `nix fmt`
Expected: exits 0.

- [ ] **Step 3: Build anoa**

Run: `nix build .#nixosConfigurations.anoa.config.system.build.toplevel`
Expected: builds successfully.

- [ ] **Step 4: Commit**

```bash
git add modules/laptop/default.nix
git commit --no-gpg-sign -m "feat(laptop): configure UPower low-battery thresholds"
```

---

### Task 4: Full flake check + manual verification

**Files:** none (verification only).

- [ ] **Step 1: Run the real gate**

Run: `nix flake check`
Expected: passes with no errors.

- [ ] **Step 2: Re-run the decision test (regression)**

Run: `bash modules/desktop/tests/battery-guard-test.sh`
Expected: `All battery-guard tests passed.`

- [ ] **Step 3: Manual live check on anoa (after `nixos-rebuild switch`)**

Run: `sudo nixos-rebuild switch --flake .#anoa`
Then confirm the service is active: `systemctl --user status battery-guard`
Expected: `active (running)`.

- [ ] **Step 4: Manual dry-run against real hardware**

Run: `BATTERY_GUARD_DRY_RUN=1 battery-guard`
Expected: prints `none` on a healthy/charging battery. Optionally raise the low threshold to confirm the caffeine branch: turn caffeine on (`Mod+c`), then `BATTERY_GUARD_DRY_RUN=1 BATTERY_GUARD_LOW=100 battery-guard` while discharging → prints `disable-caffeine`.

- [ ] **Step 5: Commit any final tweaks (if needed)**

```bash
git add -A
git commit --no-gpg-sign -m "chore: battery-guard verification tweaks"
```

---

## Self-Review notes

- **Spec coverage:** 20% disable-caffeine (Task 1 `disable-caffeine` action + Task 2 service); 7% suspend (Task 1 `suspend` action); always-on safety net incl. force-clear caffeine at critical (Task 1 `clear_caffeine` in the `suspend` branch, runs regardless of prior state); UPower coordination/backstop (Task 3); self-exit on no battery (Task 1 `main`/`find_battery`); env-overridable thresholds + testability (Task 1); user-session placement for notify/suspend (Task 2 `graphical-session.target`). All covered.
- **Placeholder scan:** none — every code step contains full content.
- **Type/name consistency:** `battery-guard` name, `BATTERY_GUARD_*` env vars, action strings `none|disable-caffeine|suspend`, and `INHIBIT_FILE`/`/tmp/caffeine-inhibit-$USER.pid` are used identically across the script, test, and service wiring.
