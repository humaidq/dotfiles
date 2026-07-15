# Battery guard for caffeine mode — design

Date: 2026-07-16
Status: Approved, ready for implementation plan

## Problem

On laptops, "caffeine mode" holds a `systemd-inhibit` lock that blocks
`idle:sleep:handle-lid-switch`, preventing the machine from sleeping. If the
user forgets it on while unplugged, the battery drains to empty and the laptop
dies, risking data loss — because the inhibitor also blocks any automatic
suspend.

Today nothing handles critical battery on these hosts: `services.upower` has no
action configured.

## Goals

1. On battery, when charge drops to **20%**, automatically disable caffeine
   mode so normal sleep/lid behavior resumes, and notify the user.
2. On battery, when charge drops to a **critical ~7%**, force-clear any caffeine
   inhibitor and **suspend-to-RAM** so unsaved work is preserved (a suspended
   laptop draws ~1%/hr and survives many hours).
3. Fill the current gap: the critical safety net fires **always** (general
   safety net), not only when caffeine was involved.

Target environment: sway first (implementation is session-agnostic but scoped
and tested for sway).

## Non-goals (YAGNI)

- No hibernate / hybrid-sleep / `boot.resumeDevice` work. anoa is ZFS root with
  zram + encrypted zvol overflow swap; hibernating to a ZFS zvol is fragile and
  discouraged. Suspend-to-RAM early is the chosen, reliable behavior.
- No auto-re-enable of caffeine on replug (surprising; user just gets a
  notification that it was disabled).
- No per-host threshold NixOS options (env-overridable is enough).
- No config UI, no labwc-specific work.

## Key facts about the existing setup

- Caffeine mechanism (`modules/desktop/wayland-services.nix`): `caffeine-toggle`
  runs `systemd-inhibit --what=idle:sleep:handle-lid-switch ... sleep infinity &`
  and stores the PID in `/tmp/caffeine-inhibit-$USER.pid`. `suspend-if-allowed`
  (invoked by swayidle at 600s) skips suspend while that PID is alive.
- Because caffeine blocks `sleep`, **any** automatic suspend is blocked while
  caffeine is on. Disabling caffeine at 20% is therefore the necessary first
  step before a critical action can fire.
- Laptop stack (`modules/laptop/default.nix`): TLP, no `services.upower` tuning.
- anoa: ZFS root, zram primary swap + encrypted zvol overflow, no
  `boot.resumeDevice`, `services.upower.ignoreLid = true`.

## Architecture

A new user-session daemon, `battery-guard`, added to
`modules/desktop/wayland-services.nix` alongside caffeine / swayidle /
`suspend-if-allowed`.

- Runs as `home-manager.users.<vars.user>.systemd.user.services.battery-guard`,
  `partOf` + `wantedBy` `graphical-session.target`. The user session is required
  for: `notify-send` (user dbus), reading `/tmp/caffeine-inhibit-$USER.pid`, and
  polkit-blessed `systemctl suspend` for the active session.
- Built with `pkgs.writeShellApplication` so it is covered by shellcheck in
  `nix fmt`.
- Gating: enabled by new option
  `sifr.desktop.wayland-services.batteryGuard.enable`, default `cfg.enable`
  (the shared wayland-services flag). The script **self-exits at startup if no
  `/sys/class/power_supply/BAT*` is present**, so desktops start it and it
  immediately exits clean — zero ongoing cost, no eval-time battery detection
  needed.

## Daemon logic

Authoritative state comes from `/sys/class/power_supply/BAT0/{capacity,status}`
(reliable integers/enums), not from parsing `upower` text. `upower --monitor`
is used only to block/wake the loop on battery events; if unavailable the loop
falls back to `sleep 30`.

```
startup: exit 0 if no BAT* present
armed_low=1
loop:
  read capacity (int) + status from /sys BAT0
  if status == "Discharging":
      if capacity <= CRITICAL (7):
          force-clear caffeine inhibitor (kill PID + rm file)
          notify "Battery critical — suspending to save your work"
          systemctl suspend
      elif capacity <= LOW (20):
          if caffeine active: disable caffeine (kill inhibit + rm file)
          if armed_low:
              notify "Battery low — caffeine disabled, sleep re-enabled"
              armed_low=0
  else:  # Charging / Full / Not charging (AC)
      armed_low=1   # re-arm for next discharge cycle
  wait for next event (block on `upower --monitor`, min re-check interval)
```

Behavior details:

- **Idempotency:** disabling caffeine is naturally idempotent (the toggle checks
  the PID file); running the check repeatedly is safe.
- **Edge guard (`armed_low`):** the low-battery notification fires once per
  discharge cycle, re-armed only when the machine returns to a charging/AC
  state. Prevents notification spam.
- **Suspend anti-loop:** after resume, if still ≤7% and discharging it suspends
  again — this is desired (stay asleep until plugged in). The blocking
  `upower --monitor` plus a minimum re-check interval prevents a tight CPU loop.
- **Force-clear at critical:** at 7% the daemon kills the caffeine inhibitor
  even if the user re-enabled it after the 20% warning (scope = always).

Environment overrides (for testing and tuning, not exposed as NixOS options):

- `BATTERY_GUARD_LOW` (default 20)
- `BATTERY_GUARD_CRITICAL` (default 7)
- `BATTERY_GUARD_SYSFS` (default `/sys/class/power_supply`) — point at a fixture
- `BATTERY_GUARD_DRY_RUN` (default unset) — print the chosen action
  (`none` / `disable-caffeine` / `suspend`) instead of executing it

## UPower coordination

Declared in `modules/laptop/default.nix` (this is laptop-specific and the laptop
module already owns TLP/power config):

```nix
services.upower = {
  enable = true;
  percentageLow = 20;
  percentageCritical = 10;
  percentageAction = 3;              # below our 7% suspend — daemon fires first
  criticalPowerAction = "PowerOff";  # last-resort backstop only, never normally reached
  usePercentageForPolicy = true;
};
```

The daemon owns real behavior at 20% / 7%. UPower's own action sits at 3% purely
as a backstop for the case where the daemon is not running. Thresholds are thus
declared in one obvious place.

## Testing

- **Decision-logic test:** a shell test runs the script with
  `BATTERY_GUARD_SYSFS=<fixture>` and `BATTERY_GUARD_DRY_RUN=1`, feeding fake
  `capacity` / `status` files and asserting the printed action across cases:
  - 50% Discharging → `none`
  - 20% Discharging, no caffeine → `none` (nothing to disable) or
    `disable-caffeine` when caffeine present
  - 20% Discharging, caffeine on → `disable-caffeine`
  - 7% Discharging → `suspend`
  - 20% Charging/AC → `none` + re-arm
- **Manual verification (anoa):** run with `BATTERY_GUARD_DRY_RUN=1` while
  unplugged to watch live reactions; plus one real unplugged end-to-end check
  (temporarily raising thresholds to trigger quickly).

## Files touched

- `modules/desktop/wayland-services.nix` — add the `battery-guard` script, the
  `sifr.desktop.wayland-services.batteryGuard.enable` option, and the user
  service.
- `modules/laptop/default.nix` — add the `services.upower` block.
- `modules/desktop/tests/battery-guard-test.sh` — decision-logic shell test
  driven by `BATTERY_GUARD_SYSFS` + `BATTERY_GUARD_DRY_RUN`.
