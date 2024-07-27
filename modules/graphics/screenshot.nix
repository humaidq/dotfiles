{
  dmenu,
  gimp,
  grim,
  libnotify,
  pinta,
  slurp,
  wl-clipboard,
  writeShellApplication,
  xdg-user-dirs,
}:
writeShellApplication {
  name = "screen";
  runtimeInputs = [
    dmenu
    grim
    libnotify
    slurp
    wl-clipboard
    xdg-user-dirs

    # editors
    gimp
    pinta
  ];
  text = ''
    function notify() {
      notify-send "sifrOS" "$1"
    }
    dir=$(xdg-user-dir HOME)/inbox/screens
    mkdir -p "$dir"
    file=$dir/$(date +'%_scrn.png')

    sel=$(printf "select area\\ncurrent window\\nfull screen\\nquit" | dmenu -p Screenshot)
    if [[ "$sel" == "quit" ]]; then
       exit 0
    fi

    del=$(printf "0" | dmenu -p "Delay (s)")
    sleep "$del"

    case "$sel" in
         "select area") grim -g "$(slurp)" "$file" ;;
         "current window") grim -g "$(swaymsg -t get_tree | jq -j '.. | select(.type?) | select(.focused).rect | "\(.x),\(.y) \(.width)x\(.height)"')" "$file" ;;
         "full screen") grim "$file" ;;
    esac

    notify "*click!* Screenshot taken!"
    edit=$(printf "no\\npinta\\ngimp" | dmenu -p Edit?)
    if [[ "$edit" != "no" ]]; then
       notify "Launching editor... Image will be copied when the editor exits."
    fi
    case "$edit" in
         "pinta") pinta "$file" ;;
         "gimp") gimp -n -s "$file" ;;
    esac
    wl-copy < "$file"
    notify "Screenshot copied to clipboard!"
  '';
}
