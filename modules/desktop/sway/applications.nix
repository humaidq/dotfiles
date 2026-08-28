{
  config,
  pkgs,
  lib,
  vars,
  ...
}:
let
  cfg = config.sifr.desktop.sway;
  gfxCfg = config.sifr.desktop;
  desktopEntry = name: command: {
    executable = true;
    text = ''
      [Desktop Entry]
      Type=Application
      Name=${name}
      Exec=${command}
    '';
  };

  # fuzzel ranks launcher entries by launch count, read from
  # $XDG_CACHE_HOME/fuzzel as "<desktop-id>|<count>" lines.  Where counts tie it
  # falls back to .desktop scan order, which is why "Emacs" lands above "Emacs
  # (Client)" and "Thunar Preferences" above "Thunar File Manager".  ~/.cache
  # isn't persisted, so every boot starts from an all-zero tie; seed the entries
  # that should always sort first and let fuzzel count up from there.
  fuzzelPinned = {
    "emacsclient.desktop" = 99;
    "thunar.desktop" = 99;
  };
  fuzzelCacheSeed = pkgs.writeText "fuzzel-cache-seed" (
    lib.concatMapStrings (line: line + "\n") (
      lib.mapAttrsToList (id: count: "${id}|${toString count}") fuzzelPinned
    )
  );
  seedFuzzelCache = pkgs.writeShellScript "seed-fuzzel-cache" ''
    cache="''${XDG_CACHE_HOME:-$HOME/.cache}/fuzzel"
    mkdir -p "$(dirname "$cache")"
    touch "$cache"
    # Raise pinned entries to at least their seeded count, leaving other entries
    # -- and any higher count fuzzel has since learned -- untouched.  Written as
    # a merge rather than an overwrite so a mid-session rebuild is harmless.
    ${pkgs.gawk}/bin/awk -F'|' -v OFS='|' '
      NR == FNR { want[$1] = $2; next }
      { if ($1 in want) { if ($2 < want[$1]) $2 = want[$1]; delete want[$1] } print }
      END { for (id in want) print id, want[id] }
    ' ${fuzzelCacheSeed} "$cache" >"$cache.new" && mv "$cache.new" "$cache"
  '';
in
{
  config = lib.mkIf cfg.enable {
    systemd.user.services.fuzzel-cache-seed = {
      enable = true;
      description = "Seed fuzzel's launcher popularity cache";
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${seedFuzzelCache}";
      };
      partOf = [ "graphical-session.target" ];
      wantedBy = [ "graphical-session.target" ];
    };

    home-manager.users."${vars.user}" = {
      # home manager packages
      home.packages = with pkgs; [
        imv
        j4-dmenu-desktop
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
            colors-dark = {
              background = "282a36";
              foreground = "f8f8f2";
              regular0 = "21222c";
              regular1 = "ff5555";
              regular2 = "50fa7b";
              regular3 = "f1fa8c";
              regular4 = "bd93f9";
              regular5 = "ff79c6";
              regular6 = "8be9fd";
              regular7 = "f8f8f2";
              bright0 = "6272a4";
              bright1 = "ff6e6e";
              bright2 = "69ff94";
              bright3 = "ffffa5";
              bright4 = "d6acff";
              bright5 = "ff92df";
              bright6 = "a4ffff";
              bright7 = "ffffff";
              selection-foreground = "ffffff";
              selection-background = "44475a";
              urls = "8be9fd";
            };
          };
        };
        fuzzel = {
          enable = true;
          settings = {
            main = {
              tabs = 4;
              terminal = "${lib.getExe pkgs.foot} -e";
              # Launch every entry into its own scope under
              # app-graphical.slice instead of inheriting the compositor's
              # unit, so systemd-oomd can kill one app rather than the session
              # (see ../uwsm.nix). fuzzel exports DESKTOP_ENTRY_ID and friends
              # for exactly this hook, and app2unit reads them to name the
              # unit after the entry -- so scopes come out as
              # app-<entry-id>@<random>.scope and are legible in systemd-cgls.
              "launch-prefix" = "${lib.getExe pkgs.app2unit} --";
              layer = "overlay";
              width = 40;
              "exit-on-keyboard-focus-loss" = "no";
              font = if gfxCfg.berkeley.enable then "Berkeley Mono:size=14" else "Fira Code:size=14";
              "dpi-aware" = "yes";
              "inner-pad" = 10;
              "vertical-pad" = 15;
              "horizontal-pad" = 15;
            };
            colors = {
              background = "130e24ff";
              text = "eeeeeeff";
              prompt = "bbbbbbff";
              input = "eeeeeeff";
              match = "eeeeeeff";
              selection = "1d2e86ff";
              "selection-match" = "eeeeeeff";
              "selection-text" = "eeeeeeff";
              border = "10245fff";
            };
            border = {
              width = 2;
              radius = 0;
            };
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
            pinentry = pkgs.pinentry-gnome3;
          };
        };
      };

      # Set default applications
      xdg = {
        enable = true;
        dataFile."applications/browser.desktop" = desktopEntry "Browser" "${lib.getExe pkgs.helium} %U";
        dataFile."applications/file.desktop" = desktopEntry "File Manager" "${pkgs.thunar}/bin/thunar %U";
        dataFile."applications/img.desktop" = desktopEntry "Image Viewer" "${pkgs.imv}/bin/imv %U";
        dataFile."applications/mail.desktop" =
          desktopEntry "Mail" "${lib.getExe pkgs.foot} -e ${pkgs.aerc}/bin/aerc %u";
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
