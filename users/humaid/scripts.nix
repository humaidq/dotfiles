{
  pkgs,
  lib,
  ...
}: let
  script = text: {
    executable = true;
    text = ''
      #!/usr/bin/env bash
      ${text}
    '';
  };
  wallpaper = ./wallhaven-13mk9v.jpg;
  screensDir = "~/inbox/screens";
in {
  home.file = {
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
    ".bin/hn" = script "dunstify \"sifr\" \"$1\"";
    # Screenshot which asks for prompts.
    ".bin/screen-sel" = script ''
      name=$(date +%s)
      sel=$(printf "select area\\ncurrent window\\nfull screen\\nquit" | dmenu -p Screenshot)
      if [[ "$sel" == "quit" ]]; then
         exit 0
      fi
      del=$(printf "0" | dmenu -p "Delay (s)")
      sleep $del
      case "$sel" in
           "select area") maim -s ${screensDir}/$name.png ;;
           "current window") maim -i $(xdotool getactivewindow) ${screensDir}/$name.png ;;
           "full screen") maim ${screensDir}/$name.png ;;
      esac
      hn "*click!* Screenshot taken!"
      edit=$(printf "no\\npinta\\ngimp" | dmenu -p Edit?)
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
    # Check a LaTeX document through languagetool.
    ".bin/lacheck" = script ''
      pandoc $1 -f latex -t plain -o /tmp/lacheck.txt
      languagetool /tmp/lacheck.txt
    '';
    # Lenovo Fan speed setter script.
    ".bin/fan" = script "echo level $1 | doas tee /proc/acpi/ibm/fan";
    # Prompts ascii arts to pick from.
    ".bin/ascii-art" = script ''
      sel=$(cat ${./looks.txt} | dmenu -p "Pick a look!")
      echo -n "$sel" | xclip -selection clipboard
    '';
  };
}
