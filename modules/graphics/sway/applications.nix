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
  desktopEntry = name: command: {
    executable = true;
    text = ''
      [Desktop Entry]
      Type=Application
      Name=${name}
      Exec=${command}
    '';
  };
in
{
  config = lib.mkIf cfg.enable {
    home-manager.users."${vars.user}" = {
      # home manager packages
      home.packages = with pkgs; [
        imv
        mpv
      ];

      # home manager programs
      programs = {
        zathura = {
          enable = true;
          options = {
            "selection-clipboard" = "clipboard";
          };
          mappings = {
            "i" = "recolor";
            "r" = "reload";
            "R" = "rotate";
            "p" = "print";
            "u" = "scroll half-up";
            "d" = "scroll half-down";
            "D" = "toggle_page_mode";
            "g" = "goto top";
          };
        };
        foot = {
          enable = true;
          settings = {
            main = {
              term = "xterm-256color";
              dpi-aware = "yes";
              font = if gfxCfg.berkeley.enable then "Berkeley Mono:size=8" else "Fira Code:size=8";
            };
          };
        };
        bemenu = {
          enable = true;
          settings = {
            ignorecase = true;
            line-height = 28;
            prompt = "run";
            fb = "#130e24";
            ff = "#ffffff";
            nb = "#130e24";
            nf = "#ffffff";
            tb = "#130e24";
            hb = "#134dae";
            tf = "#ffffff";
            hf = "#ffffff";
            af = "#ffffff";
            ab = "#130e24";
            width-factor = 1;
            fn = if gfxCfg.berkeley.enable then "Berkeley Mono 14" else "Fira Code 14";
          };
        };
        swaylock = {
          enable = true;
          settings = {
            color = "130e24";
            line-color = "ffffff";
            show-failed-attempts = true;
          };
        };
        rbw = {
          enable = true;
          settings = {
            email = "me@huma.id";
            base_url = "https://vault.alq.ae";
            pinentry = pkgs.pinentry-gnome3;
          };
        };
      };

      # Set default applications
      xdg = {
        enable = true;
        dataFile."applications/browser.desktop" = desktopEntry "Browser" "${pkgs.chromium}/bin/chromium %U";
        dataFile."applications/file.desktop" =
          desktopEntry "File Manager" "${pkgs.xfce.thunar}/bin/thunar %U";
        dataFile."applications/img.desktop" = desktopEntry "Image Viewer" "${pkgs.imv}/bin/imv %U";
        dataFile."applications/mail.desktop" =
          desktopEntry "Mail" "${pkgs.ghostty}/bin/ghostty -e ${pkgs.aerc}/bin/aerc %u";
        dataFile."applications/media.desktop" = desktopEntry "Media Player" "${pkgs.mpv}/bin/mpv %U";
        dataFile."applications/pdf.desktop" = desktopEntry "PDF Viewer" "${pkgs.zathura}/bin/zathura %U";
        dataFile."applications/text.desktop" = desktopEntry "Text Editor" "emacsclient -c -n %F";
        mimeApps.enable = true;
        mimeApps.defaultApplications = {
          # Directories
          "inode/directory" = [ "file.desktop" ];

          # PDF files
          "application/pdf" = [ "pdf.desktop" ];
          "application/postscript" = [ "pdf.desktop" ];
          "application/x-bzpdf" = [ "pdf.desktop" ];
          "application/x-gzpdf" = [ "pdf.desktop" ];
          "application/x-xzpdf" = [ "pdf.desktop" ];

          # Image files
          "image/png" = [ "img.desktop" ];
          "image/jpeg" = [ "img.desktop" ];
          "image/jpg" = [ "img.desktop" ];
          "image/gif" = [ "img.desktop" ];
          "image/bmp" = [ "img.desktop" ];
          "image/svg+xml" = [ "img.desktop" ];
          "image/tiff" = [ "img.desktop" ];
          "image/webp" = [ "img.desktop" ];

          # Text files - open with emacsclient
          "application/json" = [ "text.desktop" ];
          "application/x-zerosize" = [ "text.desktop" ];
          "application/x-yaml" = [ "text.desktop" ];
          "application/xml" = [ "text.desktop" ];
          "text/plain" = [ "text.desktop" ];
          "text/x-c" = [ "text.desktop" ];
          "text/x-c++src" = [ "text.desktop" ];
          "text/x-java" = [ "text.desktop" ];
          "text/x-lisp" = [ "text.desktop" ];
          "text/x-markdown" = [ "text.desktop" ];
          "text/x-org" = [ "text.desktop" ];
          "text/x-python" = [ "text.desktop" ];
          "text/x-shellscript" = [ "text.desktop" ];

          # Office files
          "application/msword" = [ "writer.desktop" ];
          "application/rtf" = [ "writer.desktop" ];
          "application/vnd.oasis.opendocument.graphics" = [ "draw.desktop" ];
          "application/vnd.oasis.opendocument.graphics-template" = [ "draw.desktop" ];
          "application/vnd.oasis.opendocument.presentation" = [ "impress.desktop" ];
          "application/vnd.oasis.opendocument.presentation-template" = [ "impress.desktop" ];
          "application/vnd.oasis.opendocument.spreadsheet" = [ "calc.desktop" ];
          "application/vnd.oasis.opendocument.spreadsheet-template" = [ "calc.desktop" ];
          "application/vnd.oasis.opendocument.text" = [ "writer.desktop" ];
          "application/vnd.oasis.opendocument.text-template" = [ "writer.desktop" ];
          "application/vnd.ms-excel" = [ "calc.desktop" ];
          "application/vnd.ms-powerpoint" = [ "impress.desktop" ];
          "application/vnd.openxmlformats-officedocument.presentationml.presentation" = [ "impress.desktop" ];
          "application/vnd.openxmlformats-officedocument.presentationml.template" = [ "impress.desktop" ];
          "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet" = [ "calc.desktop" ];
          "application/vnd.openxmlformats-officedocument.spreadsheetml.template" = [ "calc.desktop" ];
          "application/vnd.openxmlformats-officedocument.wordprocessingml.document" = [ "writer.desktop" ];
          "application/vnd.openxmlformats-officedocument.wordprocessingml.template" = [ "writer.desktop" ];

          # 3D model files
          "application/prs.wavefront-obj" = [ "PrusaSlicer.desktop" ];
          "application/sla" = [ "PrusaSlicer.desktop" ];
          "application/vnd.ms-3mfdocument" = [ "PrusaSlicer.desktop" ];
          "model/3mf" = [ "PrusaSlicer.desktop" ];
          "model/obj" = [ "PrusaSlicer.desktop" ];
          "model/stl" = [ "PrusaSlicer.desktop" ];

          # G-code files
          "application/x-gcode" = [ "PrusaGcodeviewer.desktop" ];
          "model/gcode" = [ "PrusaGcodeviewer.desktop" ];
          "text/x-gcode" = [ "PrusaGcodeviewer.desktop" ];

          # Video files
          "application/ogg" = [ "media.desktop" ];
          "video/mp4" = [ "media.desktop" ];
          "video/mpeg" = [ "media.desktop" ];
          "video/ogg" = [ "media.desktop" ];
          "video/quicktime" = [ "media.desktop" ];
          "video/webm" = [ "media.desktop" ];
          "video/x-matroska" = [ "media.desktop" ];
          "video/x-msvideo" = [ "media.desktop" ];

          # Audio files
          "audio/aac" = [ "media.desktop" ];
          "audio/flac" = [ "media.desktop" ];
          "audio/mid" = [ "media.desktop" ];
          "audio/midi" = [ "media.desktop" ];
          "audio/mp4" = [ "media.desktop" ];
          "audio/mpeg" = [ "media.desktop" ];
          "audio/ogg" = [ "media.desktop" ];
          "audio/vnd.wav" = [ "media.desktop" ];
          "audio/vorbis" = [ "media.desktop" ];
          "audio/x-flac" = [ "media.desktop" ];
          "audio/x-wav" = [ "media.desktop" ];

          # Web browser
          "application/xhtml+xml" = [ "browser.desktop" ];
          "text/html" = [ "browser.desktop" ];
          "x-scheme-handler/about" = [ "browser.desktop" ];
          "x-scheme-handler/http" = [ "browser.desktop" ];
          "x-scheme-handler/https" = [ "browser.desktop" ];
          "x-scheme-handler/mailto" = [ "mail.desktop" ];
          "x-scheme-handler/unknown" = [ "browser.desktop" ];
        };
      };
    };
  };
}
