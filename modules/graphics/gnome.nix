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
    gnome.enableRemoteDesktop = lib.mkEnableOption "GNOME remote desktop service";
  };

  config = lib.mkIf cfg.gnome.enable {
    services.xserver.desktopManager.gnome.enable = true;
    #services.gnome.gnome-online-accounts.enable = false;
    #services.gnome.gnome-keyring.enable = lib.mkForce false;

    programs.ssh.enableAskPassword = true;

    # enable the remote desktop service
    services.gnome.gnome-remote-desktop.enable = cfg.gnome.enableRemoteDesktop;
    systemd.services.gnome-remote-desktop.wantedBy = lib.mkIf cfg.gnome.enableRemoteDesktop [
      "graphical.target"
    ];
    networking.firewall.allowedTCPPorts = lib.mkIf cfg.gnome.enableRemoteDesktop [ 3389 ];
    networking.firewall.allowedUDPPorts = lib.mkIf cfg.gnome.enableRemoteDesktop [ 3389 ];

    # Exclude some packages we don't want
    environment.gnome.excludePackages = with pkgs; [
      gnome-music
      gnome-tour
      epiphany
      orca
      evince # replace with papers
      totem # replace with showtime
    ];
    environment.systemPackages =
      with pkgs;
      [
        dconf-editor
        #gnome-pomodoro
        gnome-solanum
        halftone
        resources
        gnome-epub-thumbnailer
        #gradia # not yet available in nixpkgs
        #bouncer # not yet available in nixpkgs, this needs networkmanager and firewalld
      ]
      ++ lib.optional cfg.gnome.enableRemoteDesktop gnome-remote-desktop;

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
              "google-chrome.desktop"
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
            color-scheme = "prefer-light";
            document-font-name = "Adwaita Sans 11";
            font-name = "Adwaita Sans 11";
            monospace-font-name = "Adwaita Mono 11";
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
            button-layout = ":minimize,maximize,close";
            titlebar-font = "Adwaita Sans Bold 11";
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
            "text/plain" = [ "org.gnome.TextEditor.desktop" ];
            "application/x-zerosize" = [ "org.gnome.TextEditor.desktop" ];
            "text/x-shellscript" = [ "org.gnome.TextEditor.desktop" ];
            "text/x-c" = [ "org.gnome.TextEditor.desktop" ];
            "text/x-lisp" = [ "org.gnome.TextEditor.desktop" ];
            "text/html" = [ "google-chrome.desktop" ];
            "text/x-python" = [ "org.gnome.TextEditor.desktop" ];
            "text/x-markdown" = [ "org.gnome.TextEditor.desktop" ];
            "text/x-c++src" = [ "org.gnome.TextEditor.desktop" ];
            "text/x-java" = [ "org.gnome.TextEditor.desktop" ];
            # org mode opens emacs standalone
            "text/x-org" = [ "emacs.desktop" ];

            ## PDF
            "application/pdf" = [
              "org.gnome.Papers.desktop"
              "google-chrome.desktop"
            ];
            "application/x-bzpdf" = [ "org.gnome.Papers.desktop" ];
            "application/x-gzpdf" = [ "org.gnome.Papers.desktop" ];
            "application/x-xzpdf" = [ "org.gnome.Papers.desktop" ];
            "application/postscript" = [ "org.gnome.Papers.desktop" ];
            "application/epub+zip" = [ "org.gnome.Papers.desktop" ];
            "application/x-mobipocket-ebook" = [ "org.gnome.Papers.desktop" ];
            "application/x-cbr" = [ "org.gnome.Papers.desktop" ];
            "application/x-cbz" = [ "org.gnome.Papers.desktop" ];
            #"image/tiff" = [ "org.gnome.Papers.desktop" ];
            "image/vnd.djvu" = [ "org.gnome.Papers.desktop" ];
            "image/vnd.djvu+multipage" = [ "org.gnome.Papers.desktop" ];
            "application/x-ext-djvu" = [ "org.gnome.Papers.desktop" ];
            "application/x-ext-djv" = [ "org.gnome.Papers.desktop" ];

            ## Videos
            "video/mp4" = [ "org.gnome.Showtime.desktop" ];
            "video/x-msvideo" = [ "org.gnome.Showtime.desktop" ];
            "video/quicktime" = [ "org.gnome.Showtime.desktop" ];
            "video/mpeg" = [ "org.gnome.Showtime.desktop" ];
            "video/ogg" = [ "org.gnome.Showtime.desktop" ];
            "video/mpv" = [ "org.gnome.Showtime.desktop" ];
            "video/webm" = [ "org.gnome.Showtime.desktop" ];

            # Audio
            "audio/mpeg" = [ "org.gnome.Decibels.desktop" ];
            "audio/ogg" = [ "org.gnome.Decibels.desktop" ];
            "audio/mp4" = [ "org.gnome.Decibels.desktop" ];
            "audio/vorbis" = [ "org.gnome.Decibels.desktop" ];
            "audio/vnd.wav" = [ "org.gnome.Decibels.desktop" ];
            "audio/mid" = [ "org.gnome.Decibels.desktop" ];
            "audio/x-wav" = [ "org.gnome.Decibels.desktop" ];
            "audio/x-flac" = [ "org.gnome.Decibels.desktop" ];

          };
        };

      };
  };
}
