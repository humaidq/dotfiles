{
  config,
  pkgs,
  lib,
  vars,
  ...
}:
let
  cfg = config.sifr.graphics.sway;
  gfxCfg = config.sifr.graphics;
in
{
  config = lib.mkIf cfg.enable {
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
