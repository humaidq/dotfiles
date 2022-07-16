{ nixosConfig, pkgs, lib, ... }:

let
  mkTuple = lib.hm.gvariant.mkTuple;
in
{
  config = lib.mkIf nixosConfig.hsys.enableMate {
    # dconf (gsettings) for mate applications
    dconf.settings = {
      "org/mate/desktop/wm/preferences" = {
        "titlebar-font" = "Inter Semi-Bold 11";
      };
      "org/mate/desktop/background" = {
        show-desktop-icons = false;
        picture-filename = "${./wallhaven-13mk9v.jpg}";
        picture-options = "zoom";
      };
      "org/mate/desktop/applications/terminal" = {
        "exec" = "st";
      };
      "org/mate/interface" = {
        "font-name" = "Inter 10";
        "document-font-name" = "Inter 10";
        "monospace-font-name" = "Source Code Pro 10";
      };
      "org/mate/macro/general" = {
        "titlebar-font" = "Inter Semi-Bold 10";
      };
      "org/mate/caja/desktop" = {
        "font" = "Inter 10";
      };
      "org/mate/desktop/interface" = {
        "gtk-theme" = "TraditionalOak";
        "icon-theme" = "mate";
        "font-name" = "Inter 10";
        "document-font-name" = "Inter 10";
        "monospace-font-name" = "Source Code Pro 10";
      };
      "org/mate/panel/objects/clock/prefs" = {
        "format" = "12-hour";
      };
      "org/mate/desktop/peripherals/touchpad" = {
        "natural-scroll" = true;
      };
    };
  };
}
