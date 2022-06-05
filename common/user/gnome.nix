{ nixosConfig, pkgs, lib, ... }:

let
  mkTuple = lib.hm.gvariant.mkTuple;
in
{
  config = lib.mkIf nixosConfig.hsys.enableGnome {
    # dconf (gsettings) for Gnome applications
    dconf.settings = {
      "org/gnome/shell" = {
        favorite-apps = [
          "firefox.desktop"
          "mozilla-thunderbird.desktop"
          "org.gnome.Terminal.desktop"
          "org.gnome.Nautilus.desktop"
        ];
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
        # Inter font
        document-font-name = "Inter 11";
        font-name = "Inter 11";
      };
      "org/gnome/desktop/background" = {
        picture-uri = "file://${./wallhaven-13mk9v.jpg}";
        picture-uri-dark = "file://${./wallhaven-13mk9v.jpg}";
        picture-options = "centered";
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
        sources = [ (mkTuple [ "xkb" "us" ]) (mkTuple [ "xkb" "ara" ]) (mkTuple [ "xkb" "fi" ]) ];
        xkb-options = [ "caps:escape" ];
      };
      "org/gnome/desktop/media-handling" = {
        # Don't mount devices when plugged in
        automount = false;
        automount-open = false;
        autorun-never = true;
      };
    };
  };
}
