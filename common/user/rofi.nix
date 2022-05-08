{ nixosConfig, config, pkgs, lib, ... }:
let
  graphical = nixosConfig.hsys.enableGnome || nixosConfig.hsys.enablei3;
in
{
  config = lib.mkIf graphical {
    programs.rofi = {
      enable = true;
      #font = "Spleen 8x16";
      location = "top";
      xoffset = -80;
      extraConfig = {
      modi = "run,drun,combi";
      combi-modi = "run,drun";
      };
      theme = let
      inherit (config.lib.formats.rasi) mkLiteral;
      in {
      "*" = {
          background-color = mkLiteral "rgba(0, 0, 0, 0%)";
          foreground-color = mkLiteral "#ffffff";
          normal-foreground = mkLiteral "#ffffff";
          selected-normal-background = mkLiteral "#1d2e86";
          selected-urgent-background = mkLiteral "@selected-normal-background";
          selected-active-background = mkLiteral "@selected-normal-background";
      };
      "#window" = {
          background-color = mkLiteral "#130e24";
      };
      "#element.selected.normal" = {
          background-color = mkLiteral "#1d2e86";
          border-color = mkLiteral "#1d2e86";
      };
      "#element.selected.active" = {
          background-color = mkLiteral "@selected-normal-background";
      };
      "#element.selected.urgent" = {
          background-color = mkLiteral "@selected-normal-background";
      };
      "#element-text" = {
          text-color = mkLiteral "@foreground-color";
      };
      "#textbox" = {
          text-color = mkLiteral "@foreground-color";
      };
      "#entry" = {
          text-color = mkLiteral "@foreground-color";
      };
      "#prompt" = {
          text-color = mkLiteral "@foreground-color";
          padding = mkLiteral "3 7 3 0";
      };
      "#textbox-prompt-colon" = {
          text-color = mkLiteral "@foreground-color";
      };
      };
    };
  };
}
