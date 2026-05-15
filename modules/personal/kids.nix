{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.sifr.personal.kids;
  user = "user";
  url = "https://starfall.com";
  chromiumKiosk = pkgs.writeShellScript "chromium-kiosk" ''
    while ! ${pkgs.systemd}/bin/systemctl --user show-environment | ${pkgs.gnugrep}/bin/grep -q '^WAYLAND_DISPLAY='; do
      sleep 1
    done

    while IFS= read -r line; do
      export "$line"
    done < <(
      ${pkgs.systemd}/bin/systemctl --user show-environment \
        | ${pkgs.gnugrep}/bin/grep -E '^(WAYLAND_DISPLAY|DISPLAY|XDG_CURRENT_DESKTOP)='
    )

    exec ${pkgs.chromium}/bin/chromium \
      --ozone-platform=wayland \
      --kiosk \
      --no-first-run \
      --no-default-browser-check \
      --disable-session-crashed-bubble \
      ${url}
  '';
in
{
  options.sifr.personal.kids.enable = lib.mkEnableOption "kids desktop";

  config = lib.mkIf cfg.enable {
    sifr.desktop.labwc.enable = true;

    services.greetd.settings.initial_session = {
      command = lib.getExe pkgs.labwc;
      inherit user;
    };

    users.users.${user} = {
      isNormalUser = true;
      description = "VM User";
      extraGroups = [
        "audio"
        "networkmanager"
        "video"
        "wheel"
      ];
      hashedPassword = "";
      hashedPasswordFile = lib.mkForce null;
    };

    environment.systemPackages = with pkgs; [
      xfce.xfce4-panel
      xfce.xfce4-panel-profiles
      xfce.xfce4-whiskermenu-plugin
      xfce.thunar
      xfce.thunar-archive-plugin
      xfce.thunar-volman
      xfce.mousepad
      xfce.ristretto
      xfce.parole
      xfce.orage
      xfce.xfce4-dict

      chromium
      foot
    ];
    services.xserver = {
      enable = true;
      desktopManager = {
        xterm.enable = false;
        xfce = {
          enable = true;
          noDesktop = true;
          enableXfwm = false;
        };
      };
    };
    programs.xfconf.enable = true;

    home-manager.users.${user} = {
      home.stateVersion = "23.05";
      gtk = {
        enable = true;
        iconTheme = {
          name = "elementary-Xfce";
          package = pkgs.elementary-xfce-icon-theme;
        };
        theme = {
          name = "zukitre";
          package = pkgs.zuki-themes;
        };
        gtk3.extraConfig = {
          Settings = ''
            gtk-application-prefer-dark-theme=1
          '';
        };
        gtk4.extraConfig = {
          Settings = ''
            gtk-application-prefer-dark-theme=1
          '';
        };
      };

      xfconf.settings = {
        xfce4-panel = {
          # Make sure panel 1 exists
          "panels" = [ 1 ];

          # Panel basics
          "panels/panel-1/size" = 32;
          "panels/panel-1/length" = 100;
          "panels/panel-1/position" = "p=10;x=0;y=0";
          "panels/panel-1/position-locked" = true;

          # Plugin order
          "panels/panel-1/plugin-ids" = [
            1 # whisker menu
            2 # task list / window buttons
            3 # expanding separator
            4 # clock
          ];

          # 1. Whisker menu
          "plugins/plugin-1" = "whiskermenu";

          # 2. Task list: running apps/windows
          "plugins/plugin-2" = "tasklist";

          # Show labels/titles, not icons only
          "plugins/plugin-2/show-labels" = true;

          # Optional: show windows from all workspaces or only current
          "plugins/plugin-2/all-workspaces" = false;

          # Optional: grouping behaviour
          # 0 = never group, 1 = group when space is limited, 2 = always group
          "plugins/plugin-2/grouping" = 0;

          # 3. Separator that expands, pushing clock to the right
          "plugins/plugin-3" = "separator";
          "plugins/plugin-3/expand" = true;
          "plugins/plugin-3/style" = 0;

          # 4. Clock / date-time
          "plugins/plugin-4" = "clock";

          # Common clock settings
          # Layout 3 is often digital/custom-ish depending on XFCE version.
          "plugins/plugin-4/mode" = 2;

          # Date/time format. Example: Sat 02 May, 18:30
          "plugins/plugin-4/digital-format" = "%a %d %b, %H:%M";
        };
      };

      systemd.user.services.chromium-kiosk = {
        Unit = {
          Description = "Chromium kiosk for kids";
          PartOf = [ "graphical-session.target" ];
        };

        Service = {
          Type = "simple";
          ExecStart = chromiumKiosk;
          #Restart = "always";
          #RestartSec = "2s";
        };

        Install = {
          WantedBy = [ "default.target" ];
        };
      };
    };
  };
}
