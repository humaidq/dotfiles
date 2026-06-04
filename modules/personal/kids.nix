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
  starfallLauncher = pkgs.writeShellScriptBin "starfall" ''
    exec ${pkgs.chromium}/bin/chromium \
      --app=${url} \
      --user-data-dir="$HOME/.local/share/chromium-starfall" \
      --class=Starfall \
      --name=Starfall \
      --no-first-run \
      --disable-translate \
      --disable-features=Translate
  '';

  starfallDesktop = pkgs.makeDesktopItem {
    name = "starfall";
    desktopName = "Starfall";
    genericName = "Educational website";
    comment = "Open Starfall.com";
    categories = [ "Education" ];
    icon = "applications-games";

    exec = "${starfallLauncher}/bin/starfall";
  };

  hideDesktopIds =
    ids:
    lib.genAttrs (map (id: lib.removeSuffix ".desktop" id) ids) (id: {
      name = id;
      exec = "${pkgs.coreutils}/bin/true";
      settings.Hidden = "true";
    });
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

    environment.xfce.excludePackages = with pkgs; [
      xfce4-screenshooter
      xfce4-terminal
      xfce4-appfinder
    ];

    environment.systemPackages = with pkgs; [
      xfce4-panel
      xfce4-panel-profiles
      xfce4-whiskermenu-plugin
      #thunar
      #thunar-archive-plugin
      #thunar-volman
      #mousepad
      #ristretto
      #parole
      #orage
      #xfce4-dict

      bibata-cursors

      chromium
      foot

      # Pre-school
      starfallDesktop
      kdePackages.kapman
      kdePackages.bovo
      kdePackages.blinken
      kdePackages.palapeli
      kdePackages.ktuberling
      gcompris
      tuxpaint
    ];
    services.xserver = {
      enable = true;
      desktopManager = {
        xterm.enable = false;
        xfce = {
          enable = true;
          noDesktop = true;
          enableXfwm = false;
          enableScreensaver = false;
        };
      };
    };
    programs.xfconf.enable = true;
    environment.sessionVariables = {
      XCURSOR_THEME = lib.mkForce "Bibata-Modern-Classic";
      XCURSOR_SIZE = lib.mkForce "48";
    };

    home-manager.users.${user} = {
      home.stateVersion = "23.05";
      xdg.desktopEntries = hideDesktopIds [
        "btop.desktop"
        "cups.desktop"
        "xterm.desktop"
      ];
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
          # Whisker menu favourites
          "plugins/plugin-1/favorites" = [
            "starfall.desktop"
          ];
          "plugins/plugin-1/show-command-lockscreen" = false;
          "plugins/plugin-1/show-command-logout" = false;

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

    };
  };
}
