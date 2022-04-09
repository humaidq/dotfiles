{ pkgs, lib, ... }:

let
  script = text: {
    executable = true;
    text = ''
      #!/bin/sh
      ${text}
      '';
  };
  wallpaper = ./wallhaven-13mk9v.jpg;
in
{
  home.file = {
    ".bin/dwmload" = script ''
      xwallpaper --center ${wallpaper} &
      picom --vsync --dbus --backend glx &
      setxkbmap -option caps:swapescape &
    '';
    ".bin/mkcd" = script ''
      #!/bin/sh
      mkdir -p $1 && cd $1
    '';
    ".bin/whoseport" = script ''
      lsof -i ":$1" | grep LISTEN
    '';
    ".bin/lacheck" = script ''
      pandoc $1 -f latex -t plain -o /tmp/lacheck.txt
      languagetool /tmp/lacheck.txt
    '';
    ".bin/fan" = script "echo level $1 | doas tee /proc/acpi/ibm/fan";
  };
}
