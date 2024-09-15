{
  config,
  pkgs,
  lib,
  vars,
  ...
}:
let
  cfg = config.sifr.graphics;
in
{
  options.sifr.graphics = {
    gnome.enable = lib.mkEnableOption "GNOME desktop environment";
  };

  config = lib.mkIf cfg.gnome.enable {
    services.xserver.desktopManager.gnome.enable = true;
    services.gnome.gnome-online-accounts.enable = false;

    # Exclude some packages we don't want
    environment.gnome.excludePackages = with pkgs; [
      cheese
      epiphany
      geary
      gnome-contacts
      gnome-music
      gnome-tour
      orca
      seahorse
      simple-scan
    ];
    environment.systemPackages = with pkgs; [ dconf-editor ];

    home-manager.users."${vars.user}" =
      { lib, ... }:
      let
        inherit (lib.hm.gvariant) mkTuple;
      in
      {
        # dconf (gsettings) for Gnome applications
        dconf.settings = {
          "org/gnome/shell" = {
            favorite-apps = [
              "firefox-esr.desktop"
              "org.gnome.Console.desktop"
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
            #gtk-theme = "Adwaita-dark";
            clock-format = "12h";
            show-battery-percentage = true;
            clock-show-weekday = true;
            color-scheme = "prefer-dark";
            document-font-name = "Merriweather 11";
            font-name = "IBM Plex Sans 11";
            monospace-font-name = "JetBrainsMono Nerd Font 13";
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
            sources = [
              (mkTuple [
                "xkb"
                "us"
              ])
              (mkTuple [
                "xkb"
                "ara"
              ])
              (mkTuple [
                "xkb"
                "fi"
              ])
            ];
            xkb-options = [ "caps:ctrl_modifier" ];
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
