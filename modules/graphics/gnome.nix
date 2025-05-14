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
    #services.gnome.gnome-online-accounts.enable = false;
    services.gnome.gnome-keyring.enable = lib.mkForce false;

    programs.ssh.enableAskPassword = true;

    # Exclude some packages we don't want
    environment.gnome.excludePackages = with pkgs; [
      gnome-music
      gnome-tour
      epiphany
      orca
    ];
    environment.systemPackages = with pkgs; [
      dconf-editor
      gnome-pomodoro
    ];

    home-manager.users."${vars.user}" =
      { lib, ... }:
      let
        inherit (lib.hm.gvariant) mkTuple;
      in
      {
        services.gnome-keyring.enable = true;
        home.packages = [ pkgs.gcr ];

        # dconf (gsettings) for Gnome applications
        dconf.settings = {
          "org/gnome/shell" = {
            favorite-apps = [
              "chromium-browser.desktop"
              "com.mitchellh.ghostty.desktop"
              "org.gnome.Nautilus.desktop"
            ];
            welcome-dialog-last-shown-version = "9999";
          };
          "org/gnome/mutter" = {
            edge-tiling = true;
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
            enable-hot-corners = true;
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

          # Folders
          "org/gnome/desktop/app-folders" = {
            folder-children = [
              "Office"
              "Graphics"
              "Security"
              "Radio"
              "Development"
              "System"
              "Misc"
              "Internet"
              "Devices"
            ];
          };
          "org/gnome/desktop/app-folders/folders/Office" = {
            name = "Office";
            categories = [ "Office" ];
          };
          "org/gnome/desktop/app-folders/folders/Graphics" = {
            name = "Graphics";
            categories = [ "Graphics" ];
          };
          "org/gnome/desktop/app-folders/folders/System" = {
            name = "System";
            apps = [
              "org.gnome.Firmware.desktop"
              "org.gnome.Shell.Extensions.desktop"
              "org.gnome.Extensions.desktop"
              "yelp.desktop"
              "org.gnome.baobab.desktop"
              "ca.desrt.dconf-editor.desktop"
              "org.gnome.DiskUtility.desktop"
              "org.gnome.Logs.desktop"
              "nixos-manual.desktop"
              "org.gnome.SystemMonitor.desktop"
              "org.gnome.font-viewer.desktop"
              "org.gnome.Connections.desktop"
            ];
          };
          "org/gnome/desktop/app-folders/folders/Devices" = {
            name = "Devices";
            apps = [
              "PrusaGcodeviewer.desktop"
              "PrusaSlicer.desktop"
              "org.raspberrypi.rpi-imager.desktop"
            ];
          };
          "org/gnome/desktop/app-folders/folders/Security" = {
            name = "Security";
            apps = [
              "bitwarden.desktop"
              "org.gnome.seahorse.Application.desktop"
              "com.yubico.authenticator.desktop"
            ];
          };
          "org/gnome/desktop/app-folders/folders/Development" = {
            name = "Development";
            apps = [
              "com.mardojai.ForgeSparks.desktop"
              "com.github.finefindus.eyedropper.desktop"
              "dev.zed.Zed.desktop"
              "gaphor.desktop"
              "Helix.desktop"
              "emacs.desktop"
              "io.gitlab.liferooter.TextPieces.desktop"
              "emacsclient.desktop"
            ];
          };
          "org/gnome/desktop/app-folders/folders/Radio" = {
            name = "Amateur Radio";
            apps = [
              "direwolf.desktop"
              "flrig.desktop"
              "flarq.desktop"
              "fldigi.desktop"
              "dk.gqrx.gqrx.desktop"
              "qlog.desktop"
              "wsjtx.desktop"
              "sdrpp.desktop"
              "gpredict.desktop"
              "js8call.desktop"
              "gridtracker.desktop"
              "org.arrl.trustedqsl.desktop"
              "message_aggregator.desktop"
            ];
          };

          "org/gnome/desktop/app-folders/folders/Internet" = {
            name = "Internet";
            apps = [
              "dev.geopjr.Tuba.desktop"
              "org.gnome.Fractal.desktop"
              "de.haeckerfelix.Fragments.desktop"
              "LocalSend.desktop"
              "org.gnome.Geary.desktop"
              "org.gnome.Weather.desktop"
              "org.gnome.Maps.desktop"
            ];
          };
          "org/gnome/desktop/app-folders/folders/Misc" = {
            name = "Misc";
            apps = [
              "htop.desktop"
              "lf.desktop"
              "fish.desktop"
              "cups.desktop"
            ];
          };
        };

        xdg = {
          enable = true;
          mimeApps.enable = true;
          mimeApps.defaultApplications = {
            "inode/directory" = [ "org.gnome.Nautilus.desktop" ];
            #
            ## Images
            "image/png" = [ "org.gnome.Loupe.desktop" ];
            "image/jpeg" = [ "org.gnome.Loupe.desktop" ];
            "image/gif" = [ "org.gnome.Loupe.desktop" ];
            "image/bmp" = [ "org.gnome.Loupe.desktop" ];
            "image/svg+xml" = [ "org.gnome.Loupe.desktop" ];
            "image/tiff" = [ "org.gnome.Loupe.desktop" ];
            "image/webp" = [ "org.gnome.Loupe.desktop" ];

            ## Text
            "text/x-shellscript" = [ "org.gnome.TextEditor.desktop" ];
            "text/x-c" = [ "org.gnome.TextEditor.desktop" ];
            "text/x-lisp" = [ "org.gnome.TextEditor.desktop" ];
            "text/html" = [ "chromium-browser.desktop" ];
            "text/plain" = [ "org.gnome.TextEditor.desktop" ];

            ## PDF
            "application/pdf" = [ "org.gnome.Evince.desktop" ];
            "application/postscript" = [ "org.gnome.Evince.desktop" ];
            "application/epub+zip" = "calibre-ebook-viewer.desktop";
            "application/x-mobipocket-ebook" = "calibre-ebook-viewer.desktop";

            ## Videos
            "video/mp4" = [ "org.gnome.Totem.desktop" ];
            "video/x-msvideo" = [ "org.gnome.Totem.desktop" ];
            "video/quicktime" = [ "org.gnome.Totem.desktop" ];
            "video/mpeg" = [ "org.gnome.Totem.desktop" ];
            "video/ogg" = [ "org.gnome.Totem.desktop" ];
            "video/mpv" = [ "org.gnome.Totem.desktop" ];

            # Audio
            "audio/mpeg" = [ "org.gnome.Decibels.desktop" ];
            "audio/ogg" = [ "org.gnome.Decibels.desktop" ];
            "audio/mp4" = [ "org.gnome.Decibels.desktop" ];
            "audio/vorbis" = [ "org.gnome.Decibels.desktop" ];
            "audio/vnd.wav" = [ "org.gnome.Decibels.desktop" ];
            "audio/mid" = [ "org.gnome.Decibels.desktop" ];
          };
        };

      };
  };
}
