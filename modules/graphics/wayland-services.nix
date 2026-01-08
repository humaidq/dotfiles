{
  config,
  pkgs,
  lib,
  vars,
  ...
}:
let
  cfg = config.sifr.graphics.wayland-services;
  gfxCfg = config.sifr.graphics;
  swayEnabled = config.sifr.graphics.sway.enable;
  labwcEnabled = config.sifr.graphics.labwc.enable;

  # Caffeine toggle script to prevent sleep
  caffeineToggle = pkgs.writeShellScriptBin "caffeine-toggle" ''
    INHIBIT_FILE="/tmp/caffeine-inhibit-$USER.pid"

    if [ -f "$INHIBIT_FILE" ]; then
      # Caffeine is on, turn it off
      PID=$(cat "$INHIBIT_FILE")
      if kill "$PID" 2>/dev/null; then
        rm "$INHIBIT_FILE"
        ${pkgs.libnotify}/bin/notify-send -t 3000 "☕ Caffeine" "Sleep enabled"
      else
        rm "$INHIBIT_FILE"
        ${pkgs.libnotify}/bin/notify-send -t 3000 "☕ Caffeine" "Already disabled"
      fi
    else
      # Caffeine is off, turn it on
      ${pkgs.systemd}/bin/systemd-inhibit --what=idle:sleep \
        --why="Caffeine mode - preventing sleep" \
        --who="$USER" \
        --mode=block \
        sleep infinity &
      echo $! > "$INHIBIT_FILE"
      ${pkgs.libnotify}/bin/notify-send -t 3000 "☕ Caffeine" "Sleep disabled (locking still works)"
    fi
  '';
in
{
  options.sifr.graphics.wayland-services = {
    enable = lib.mkEnableOption "shared wayland services" // {
      default = swayEnabled || labwcEnabled;
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = with pkgs; [
      swaylock-effects # lockscreen
      swayidle
      chayang # gradual screen dimming
      libnotify
      dunst # notification daemon
      caffeineToggle
      cliphist # clipboard history
      wl-clipboard
    ];

    systemd.user.services = {
      ianny = {
        enable = false;
        description = "ianny daemon";
        serviceConfig = {
          Type = "simple";
          ExecStart = "${pkgs.ianny}/bin/ianny";
        };
        partOf = [ "graphical-session.target" ];
        wantedBy = [ "graphical-session.target" ];
      };
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
    };
    services.dbus.packages = [
      pkgs.gcr
    ];

    home-manager.users."${vars.user}" = {
      # home manager services
      services = {
        gnome-keyring.enable = true;
        lxqt-policykit-agent.enable = true;
        swayidle = {
          enable = true;
          events = [
            {
              event = "before-sleep";
              command = "${lib.getExe pkgs.swaylock} -f";
            }
            {
              event = "lock";
              command = "${lib.getExe pkgs.swaylock} -f";
            }
            {
              event = "unlock";
              command = "${pkgs.procps}/bin/pkill -USR1 swaylock";
            }
          ];
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
              command = "${pkgs.systemd}/bin/systemctl suspend";
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
