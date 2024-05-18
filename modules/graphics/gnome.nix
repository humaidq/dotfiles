{
  config,
  pkgs,
  lib,
  vars,
  ...
}:
with lib; let
  cfg = config.sifr.graphics;
in {
  options.sifr.graphics.gnome.enable = mkOption {
    description = "Enables gnome";
    type = types.bool;
    default = false;
  };

  config = mkIf cfg.gnome.enable {
    services.xserver.desktopManager.gnome.enable = true;
    services.gnome.core-os-services.enable = true;
    # Disable some core-os-services we don't want
    services.gnome.evolution-data-server.enable = lib.mkForce false;
    services.gnome.gnome-online-accounts.enable = false;
    services.gnome.gnome-online-miners.enable = lib.mkForce false;
    services.gnome.tracker.enable = lib.mkForce false;

    # Exclude some packages we don't want
    environment.gnome.excludePackages = with pkgs;
    with gnome; [
      baobab
      cheese
      epiphany
      geary
      gnome-calendar
      gnome-clocks
      gnome-connections
      gnome-contacts
      gnome-maps
      gnome-music
      gnome-tour
      gnome-weather
      orca
      seahorse
      simple-scan
      totem
      yelp
    ];
    environment.systemPackages = with pkgs; [
      gnome.dconf-editor
    ];

    home-manager.users."${vars.user}" = {lib, ...}: let
      mkTuple = lib.hm.gvariant.mkTuple;
    in {
      # dconf (gsettings) for Gnome applications
      dconf.settings = {
        "org/gnome/shell" = {
          favorite-apps = [
            "firefox.desktop"
            "Alacritty.desktop"
            "org.gnome.Nautilus.desktop"
          ];
          welcome-dialog-last-shown-version = "9999";
        };
        "org/gnome/desktop/privacy" = {
          remember-app-usage = false;
          remember-recent-files = true;
        };
        "org/gnome/desktop/search-providers" = {
          disable-external = true;
        };
        "org/gnome/desktop/interface" = {
          gtk-theme = "Adwaita-dark";
          clock-format = "12h";
          show-battery-percentage = true;
          clock-show-weekday = true;
          color-scheme = "prefer-dark";
          # Inter font
          document-font-name = "Inter 11";
          font-name = "Inter 11";
        };
        "org/gnome/desktop/background" = {
          picture-uri = "file://${./wallhaven-13mk9v.jpg}";
          picture-uri-dark = "file://${./wallhaven-13mk9v.jpg}";
          picture-options = "zoom";
          primary-color = "#134dae";
          secondary-color = "#134dae";
          show-desktop-icons = false;
        };
        "org/gnome/calendar".show-weekdate = true;
        "org/gnome/desktop/sound" = {
          allow-volume-above-100-percent = true;
        };
        "org/gnome/desktop/wm/preferences" = {
          # Add minimise button, use Inter font
          button-layout = "appmenu:minimize,close";
          titlebar-font = "Inter Semi-Bold 11";
        };
        "org/gnome/desktop/input-sources" = {
          # Add three keyboad layouts (en, ar, fi)
          sources = [(mkTuple ["xkb" "us"]) (mkTuple ["xkb" "ara"]) (mkTuple ["xkb" "fi"])];
          xkb-options = ["caps:escape"];
        };
        "org/gnome/desktop/media-handling" = {
          # Don't mount devices when plugged in
          automount = false;
          automount-open = false;
          autorun-never = true;
        };
      };
    };
  };
}
