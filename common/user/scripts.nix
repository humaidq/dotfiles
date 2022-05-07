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
  dmenu_cmd = "dmenu -fn cherry:size=10 -nb \"#130e24\" -nf \"#bbbbbb\" -sb \"#1d2e86\" -sf \"#eeeeee\"";
  screensDir = "~/inbox/screens";
in
{
  home.file = {
    # This script is used for loading programs for dwm, this runs
    # every time dwm loads. This script is called from dwm.c.
    ".bin/dwmload" = script ''
      xidlehook --not-when-fullscreen --not-when-audio --timer 180 'slock' \'\' &
      xwallpaper --center ${wallpaper} &
      picom --vsync --dbus --backend glx &
      setxkbmap -option caps:ctrl_modifier -layout us,ar,fi -option grp:win_space_toggle &
      hstatus &
    '';
    # Simple tool that tells you which process uses a specific port.
    ".bin/whoseport" = script ''
      lsof -i ":$1" | grep LISTEN
    '';
    # Basic selection to clipboard.
    ".bin/screen" = script ''
      name=$(date +%s)
      maim -s ${screensDir}/$name.png
      xclip -selection clipboard -t image/png -i ${screensDir}/$name.png
    '';
    # Screenshot which asks for prompts.
    ".bin/screen-sel" = script ''
      name=$(date +%s)
      sel=$(printf "select area\\ncurrent window\\nfull screen\\nquit" | rofi -dmenu -p Screenshot)
      del=$(printf "0" | rofi -dmenu -p "Delay (s)")
      sleep $del
      case "$sel" in
           "select area") maim -s ${screensDir}/$name.png ;;
           "current window") maim -i $(xdotool getactivewindow) ${screensDir}/$name.png ;;
           "full screen") maim ${screensDir}/$name.png ;;
           "quit") exit 0 ;;
      esac
      edit=$(printf "no\\npinta\\ngimp" | rofi -dmenu -p Edit?)
      case "$edit" in
           "pinta") pinta ${screensDir}/$name.png ;;
           "gimp") gimp -s ${screensDir}/$name.png ;;
      esac
      xclip -selection clipboard -t image/png -i ${screensDir}/$name.png
    '';
    ".bin/lacheck" = script ''
      pandoc $1 -f latex -t plain -o /tmp/lacheck.txt
      languagetool /tmp/lacheck.txt
    '';
    ".bin/fan" = script "echo level $1 | doas tee /proc/acpi/ibm/fan";
    ".bin/wiki" = script "emacsclient -c $HOME/wiki/main.org";
    ".bin/ascii-art" = script ''
      sel=$(cat ${../assets/looks.txt} | ${dmenu_cmd})
      echo -n "$sel" | xclip -selection clipboard
    '';
  };
}
