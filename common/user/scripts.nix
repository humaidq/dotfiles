{ pkgs, lib, ... }:

let
  script = text: {
    executable = true;
    text = ''
      #!/usr/bin/env bash
      ${text}
    '';
  };
  wallpaper = ./wallhaven-13mk9v.jpg;
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
      hn "*click!* Screenshot copied to clipboard!"
    '';
    ".bin/hn" = script "dunstify \"hsys\" \"$1\"";
    # Screenshot which asks for prompts.
    ".bin/screen-sel" = script ''
      name=$(date +%s)
      sel=$(printf "select area\\ncurrent window\\nfull screen\\nquit" | rofi -dmenu -p Screenshot)
      if [[ "$sel" == "quit" ]]; then
         exit 0
      fi
      del=$(printf "0" | rofi -dmenu -p "Delay (s)")
      sleep $del
      case "$sel" in
           "select area") maim -s ${screensDir}/$name.png ;;
           "current window") maim -i $(xdotool getactivewindow) ${screensDir}/$name.png ;;
           "full screen") maim ${screensDir}/$name.png ;;
      esac
      hn "*click!* Screenshot taken!"
      edit=$(printf "no\\npinta\\ngimp" | rofi -dmenu -p Edit?)
      if [[ "$edit" != "no" ]]; then
         hn "Launching editor... Image will be copied when the editor exits."
      fi
      case "$edit" in
           "pinta") pinta ${screensDir}/$name.png ;;
           "gimp") gimp -n -s ${screensDir}/$name.png ;;
      esac
      xclip -selection clipboard -t image/png -i ${screensDir}/$name.png
      hn "Screenshot copied to clipboard!"
    '';
    ".bin/emoji" = script ''
    sel=$(rofimoji -a copy)
    if [[ "$sel" != "" ]]; then
       hn "Emoji copied to clipboard!"
    fi
    '';
    # Check a LaTeX document through languagetool.
    ".bin/lacheck" = script ''
      pandoc $1 -f latex -t plain -o /tmp/lacheck.txt
      languagetool /tmp/lacheck.txt
    '';
    # Lenovo Fan speed setter script.
    ".bin/fan" = script "echo level $1 | doas tee /proc/acpi/ibm/fan";
    # Binary alias to open wiki.
    ".bin/wiki" = script "emacsclient -c $HOME/wiki/main.org";
    # Prompts ascii arts to pick from.
    ".bin/ascii-art" = script ''
      sel=$(cat ${../assets/looks.txt} | rofi -dmenu -p "Pick a look!")
      echo -n "$sel" | xclip -selection clipboard
    '';
    ".bin/htype" = script ''
      xdotool key Ctrl+a && xdotool key Ctrl+x
      text=$(xclip -o -selection clipboard)
      
      # Text expandments
      text=$(printf "$text" | sed "s/\\\h/Hey/g")
      text=$(printf "$text" | sed "s/\\\gm/Good morning/g")
      text=$(printf "$text" | sed "s/\\\ln/This might help you:/g")
      text=$(printf "$text" | sed "s/\\\lm/Let me know if you need help/g")
      text=$(printf "$text" | sed "s/\\\sy/See you/g")
      text=$(printf "$text" | sed "s/\\\np/No problem/g")
      #text=$(echo "$text" | sed "s/\\\cf/https:\\\/\\\/confluence.example.com\\\/x\\\//g")


      xdotool type "$text"
    '';
  };
}
