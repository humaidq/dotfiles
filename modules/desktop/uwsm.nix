{
  config,
  pkgs,
  lib,
  vars,
  ...
}:
let
  cfg = config.sifr.desktop.uwsm;
  swayEnabled = config.sifr.desktop.sway.enable;

  # The nested slices uwsm adds under the user manager, in app2unit's own
  # "short=full" format. Setting this is not cosmetic: left alone app2unit
  # defaults to plain app.slice, which still isolates the app but is not sent a
  # stop before wayland-wm@sway.service on logout, so scoped apps would outlive
  # the session they belong to.
  app2unitSlices = "a=app-graphical.slice b=background-graphical.slice s=session-graphical.slice";
in
{
  options.sifr.desktop.uwsm = {
    enable = lib.mkEnableOption "uwsm-managed wayland session" // {
      # sway only for now. labwc has the same flat-session problem and the same
      # greetd shape, but it is the kids' compositor (modules/personal/kids.nix)
      # and is not where the runaway processes are, so it keeps the plain
      # `--cmd labwc` path until this has proven itself on a laptop.
      default = swayEnabled;
    };
  };

  # Why this module exists, since the payoff is invisible until something goes
  # wrong: systemd-oomd kills *cgroups*, never single processes. Started
  # straight from greetd, sway and every one of its descendants -- terminals,
  # and in turn everything run inside them -- share one flat session-N.scope,
  # so that scope is always the fattest candidate and killing it takes the
  # compositor with it. anoa lost the whole desktop to greetd twice this way
  # (2026-08-27 and 2026-08-28, the second time to a runaway python one-liner).
  #
  # uwsm moves the compositor into wayland-wm@sway.service under session.slice
  # and adds the app-/background-/session-graphical.slice trio; app2unit puts
  # each launched app in its own scope inside them. oomd then has real
  # candidates to choose between and picks the offender.
  #
  # This is the systemd.io "Desktop Environments" recommendation, and what
  # GNOME and KDE have always done -- it is only wlroots compositors, which are
  # deliberately init-agnostic, that need it bolted on.
  config = lib.mkIf cfg.enable {
    programs.uwsm = {
      enable = true;
      # Generates a sway-uwsm.desktop wayland-session entry. greetd is pointed
      # at `uwsm start` directly (see modules/desktop/sway/default.nix) rather
      # than at this entry, so that tuigreet keeps launching straight into sway
      # with no session picker; the entry is left in place as a fallback for
      # any display manager that enumerates sessions.
      waylandCompositors = lib.optionalAttrs swayEnabled {
        sway = {
          prettyName = "Sway";
          comment = "Sway compositor managed by UWSM";
          # Deliberately the current-system path and not lib.getExe: uwsm and
          # the running compositor must not drift apart across a rebuild.
          binPath = "/run/current-system/sw/bin/sway";
        };
      };
    };

    environment.systemPackages = [ pkgs.app2unit ];

    home-manager.users."${vars.user}" = {
      # Sourced by uwsm's environment preloader into the graphical session
      # only, which is the exact scope wanted here -- app2unit outside a
      # wayland session should keep its plain app.slice default, since the
      # -graphical slices do not exist there.
      xdg.configFile."uwsm/env".text = ''
        export APP2UNIT_SLICES="${app2unitSlices}"
      '';
    };
  };
}
