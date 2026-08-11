{
  config,
  pkgs,
  lib,
  vars,
  ...
}:
let
  cfg = config.sifr.desktop.wayland-services;
  gfxCfg = config.sifr.desktop;
  swayEnabled = config.sifr.desktop.sway.enable;
  labwcEnabled = config.sifr.desktop.labwc.enable;

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
      gawk # float compare of the sink volume against the floor
      libnotify
      sox
      wireplumber # wpctl, to floor the sink volume for the tone
    ];
    text = builtins.readFile ./caffeine-beeper.sh;
  };

  # Delegates the "is sleep inhibited" question to caffeine-ctl instead of
  # re-reading the PID file itself, so there is exactly one PID-reuse-hardened
  # liveness check in the codebase (caffeine-ctl's inhibitor_alive) rather
  # than three that can drift out of sync.
  suspendIfAllowed = pkgs.writeShellApplication {
    name = "suspend-if-allowed";
    runtimeInputs = [
      caffeineCtl
      pkgs.systemd
    ];
    text = ''
      if [ "$(caffeine-ctl status)" = "decaf" ]; then
        exec systemctl suspend
      fi
    '';
  };

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

  # WiFi-based geolocation against beacondb.net (shares its source with the
  # `blocate` helper). `--coords` prints just "LAT LON" for wlsunset.
  blocate = pkgs.writers.writePython3Bin "blocate" {
    libraries = [ pkgs.python3Packages.requests ];
  } (builtins.readFile ../base/user/scripts/blocate.py);

  # Adjust display colour temperature based on the sun, using a location
  # resolved from beacondb (wlsunset itself only takes static coordinates).
  wlsunsetBeacondb = pkgs.writeShellApplication {
    name = "wlsunset-beacondb";
    runtimeInputs = [
      blocate
      pkgs.wlsunset
      pkgs.networkmanager # nmcli, used by blocate
    ];
    text = ''
      coords="$(blocate --coords)"
      lat="''${coords%% *}"
      lon="''${coords##* }"
      echo "wlsunset: using location from beacondb: $lat $lon"
      exec wlsunset -l "$lat" -L "$lon" -t 4000 -T 6500
    '';
  };
in
{
  options.sifr.desktop.wayland-services = {
    enable = lib.mkEnableOption "shared wayland services" // {
      default = swayEnabled || labwcEnabled;
    };
    batteryGuard.enable =
      lib.mkEnableOption "low-battery guard (auto-disable caffeine, suspend when critical)"
      // {
        default = true;
      };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = with pkgs; [
      swayidle
      chayang # gradual screen dimming
      libnotify
      caffeineCtl
      caffeineBeeper
      suspendIfAllowed
      batteryGuard
      cliphist # clipboard history
      wl-clipboard
    ];

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
      caffeine-beeper = {
        enable = true;
        description = "Beep while on battery (double caffeine mode)";
        # Started on demand by caffeine-ctl, so no wantedBy.
        serviceConfig = {
          Type = "simple";
          ExecStart = lib.getExe caffeineBeeper;
          Restart = "on-failure";
          RestartSec = 5;
        };
        partOf = [ "graphical-session.target" ];
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
    services.dbus.packages = [
      pkgs.gcr
    ];

    # Unlock the gnome-keyring with the login password when logging in through
    # greetd, so rbw's pinentry-gnome3 / gcr don't prompt for it separately.
    security.pam.services.greetd.enableGnomeKeyring = true;

    home-manager.users."${vars.user}" = {
      # home manager services
      services = {
        gnome-keyring.enable = true;
        lxqt-policykit-agent.enable = true;
        swayidle = {
          enable = true;
          events = {
            before-sleep = "${lib.getExe pkgs.swaylock} -f";
            lock = "${lib.getExe pkgs.swaylock} -f";
            unlock = "${pkgs.procps}/bin/pkill -USR1 swaylock";
          };
          timeouts = [
            {
              timeout = 240;
              command = ''${pkgs.libnotify}/bin/notify-send -t 60000 --urgency critical -- "Screen will lock in 1 minute..."'';
            }
            {
              timeout = 285;
              command = "${pkgs.chayang}/bin/chayang -d 15 && ${pkgs.swaylock}/bin/swaylock -f";
            }
            {
              timeout = 600;
              command = "${lib.getExe suspendIfAllowed}";
            }
          ];
        };
        dunst = {
          enable = true;
          settings = {
            global = {
              origin = "top-right";
              frame_color = "#130e24";
              font = if gfxCfg.berkeley.enable then "Berkeley Mono 8" else "Fira Code 8";
            };
            urgency_normal = {
              background = "#1d2e86";
              foreground = "#fff";
              timeout = 10;
            };
          };
        };
      };
    };
  };
}
