{
  fuzzel,
  cliphist,
  libnotify,
  wl-clipboard,
  writeShellApplication,
}:
writeShellApplication {
  name = "clipboard-manager";
  runtimeInputs = [
    fuzzel
    cliphist
    libnotify
    wl-clipboard
  ];
  text = ''
    function notify() {
      notify-send "sifrOS" "$1"
    }

    # Show clipboard history and copy selected item
    selected=$(cliphist list | fuzzel --dmenu -p "Clipboard History" | cliphist decode)

    if [[ -n "$selected" ]]; then
      echo -n "$selected" | wl-copy
      notify "Copied to clipboard!"
    fi
  '';
}
