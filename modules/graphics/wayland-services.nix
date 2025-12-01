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
      libnotify
      dunst # notification daemon
    ];

    systemd.user.services = {
      ianny = {
        enable = true;
        description = "ianny daemon";
        serviceConfig = {
          Type = "simple";
          ExecStart = "${pkgs.ianny}/bin/ianny";
        };
        partOf = [ "graphical-session.target" ];
        wantedBy = [ "graphical-session.target" ];
      };
    };

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
              timeout = 250;
              command = ''${pkgs.libnotify}/bin/notify-send -t 30000 --urgency critical -- "Screen will lock soon..."'';
            }
            {
              timeout = 300;
              command = "${pkgs.swaylock}/bin/swaylock -f";
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
