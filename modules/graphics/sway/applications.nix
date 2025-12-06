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
    home-manager.users."${vars.user}" =
      let
        hm-config = config.home-manager.users."${vars.user}";
      in
      {
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
          rofi = {
            enable = true;
            font = if gfxCfg.berkeley.enable then "Berkeley Mono 14" else "Fira Code 14";
            terminal = lib.getExe pkgs.ghostty;
            theme =
              let
                inherit (hm-config.lib.formats.rasi) mkLiteral;
              in
              {
                "*" = {
                  background-color = mkLiteral "#130e24";
                  foreground-color = mkLiteral "#ffffff";
                  text-color = mkLiteral "#ffffff";
                  border-color = mkLiteral "#1d2e86";
                  width = 512;
                };
                "#inputbar" = {
                  children = map mkLiteral [
                    "prompt"
                    "entry"
                  ];
                };
                "#textbox-prompt-colon" = {
                  expand = false;
                  str = ":";
                  margin = mkLiteral "0px 0.3em 0em 0em";
                  text-color = mkLiteral "@foreground-color";
                };
                "element" = {
                  background-color = mkLiteral "transparent";
                  text-color = mkLiteral "@foreground-color";
                };
                "element selected" = {
                  background-color = mkLiteral "#1d2e86";
                  text-color = mkLiteral "#ffffff";
                  border = mkLiteral "2px";
                  border-color = mkLiteral "#2b3ea6";
                  border-radius = 6;
                };
                "element-text" = {
                  highlight = mkLiteral "underline #9fb3ff";
                };
                "element selected element-text" = {
                  highlight = mkLiteral "none";
                };
                "element alternate" = {
                  background-color = mkLiteral "#171233";
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
              base_url = "https://vault.alq.ae";
              pinentry = pkgs.pinentry-gnome3;
            };
          };
        };
      };
  };
}
