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
      # home manager packages
      home.packages = with pkgs; [
        imv
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
            width-factor = 0.3;
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
        mimeApps.enable = true;
        mimeApps.defaultApplications = {
          # PDF files
          "application/pdf" = [ "org.pwmt.zathura.desktop" ];
          "application/postscript" = [ "org.pwmt.zathura.desktop" ];
          "application/x-bzpdf" = [ "org.pwmt.zathura.desktop" ];
          "application/x-gzpdf" = [ "org.pwmt.zathura.desktop" ];
          "application/x-xzpdf" = [ "org.pwmt.zathura.desktop" ];

          # Image files
          "image/png" = [ "imv.desktop" ];
          "image/jpeg" = [ "imv.desktop" ];
          "image/jpg" = [ "imv.desktop" ];
          "image/gif" = [ "imv.desktop" ];
          "image/bmp" = [ "imv.desktop" ];
          "image/svg+xml" = [ "imv.desktop" ];
          "image/tiff" = [ "imv.desktop" ];
          "image/webp" = [ "imv.desktop" ];

          # Text files - open with emacsclient
          "text/plain" = [ "emacsclient.desktop" ];
          "text/x-shellscript" = [ "emacsclient.desktop" ];
          "text/x-python" = [ "emacsclient.desktop" ];
          "text/x-c" = [ "emacsclient.desktop" ];
          "text/x-c++src" = [ "emacsclient.desktop" ];
          "text/x-java" = [ "emacsclient.desktop" ];
          "text/x-lisp" = [ "emacsclient.desktop" ];
          "text/x-markdown" = [ "emacsclient.desktop" ];
          "text/x-org" = [ "emacsclient.desktop" ];
          "application/json" = [ "emacsclient.desktop" ];
          "application/x-yaml" = [ "emacsclient.desktop" ];
          "application/xml" = [ "emacsclient.desktop" ];

          # Web browser
          "text/html" = [ "chromium-browser.desktop" ];
          "application/xhtml+xml" = [ "chromium-browser.desktop" ];
          "x-scheme-handler/http" = [ "chromium-browser.desktop" ];
          "x-scheme-handler/https" = [ "chromium-browser.desktop" ];
          "x-scheme-handler/about" = [ "chromium-browser.desktop" ];
          "x-scheme-handler/unknown" = [ "chromium-browser.desktop" ];
        };
      };
    };
  };
}
