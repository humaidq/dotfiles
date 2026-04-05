{
  bemenu,
  libnotify,
  slurp,
  wf-recorder,
  writeShellApplication,
  xdg-user-dirs,
}:
writeShellApplication {
  name = "recorder";
  runtimeInputs = [
    bemenu
    libnotify
    slurp
    wf-recorder
    xdg-user-dirs
  ];
  text = ''
    function notify() {
      notify-send "sifrOS" "$1"
    }

    pidfile=/tmp/wf-recorder.pid

    # Check if already recording
    if [[ -f "$pidfile" ]]; then
      # Stop recording
      pid=$(cat "$pidfile")
      if kill -SIGINT "$pid" 2>/dev/null; then
        rm "$pidfile"
        notify "Recording stopped!"
      else
        rm "$pidfile"
        notify "No active recording found"
      fi
      exit 0
    fi

    # Start recording
    dir=$(xdg-user-dir HOME)/inbox/screens
    mkdir -p "$dir"
    file=$dir/$(date +'%Y%m%d-%H%M%S_rec.mp4')

    sel=$(printf "select area\\nfull screen\\nquit" | bemenu -p Recording)
    if [[ "$sel" == "quit" ]]; then
       exit 0
    fi

    case "$sel" in
         "select area")
           geometry=$(slurp)
           if [[ -n "$geometry" ]]; then
             wf-recorder -g "$geometry" -f "$file" &
             echo $! > "$pidfile"
             notify "Recording started! Press Ctrl+PrintScr to stop."
           fi
           ;;
         "full screen")
           wf-recorder -f "$file" &
           echo $! > "$pidfile"
           notify "Recording started! Press Ctrl+PrintScr to stop."
           ;;
    esac
  '';
}
