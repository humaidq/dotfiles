{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.sifr.productivity.focusMode;

  # Convert blocklist to space-separated string for bash script
  blocklistStr = lib.concatStringsSep " " cfg.blocklist;

  # Create the focus command script
  focusScript = pkgs.writeShellApplication {
    name = "focus";
    runtimeInputs = with pkgs; [
      dnsutils # dig
      iptables # iptables, ip6tables
      systemd # systemd-run
      coreutils # date, mkdir, chmod, etc.
      gnugrep # grep
      bc # for floating point arithmetic
      iproute2 # tc (traffic control), ip link
      kmod # modprobe for loading ifb kernel module
      util-linux # logger for syslog
    ];
    text =
      lib.replaceStrings [ "@blocklist@" "@slow_bandwidth@" ] [ blocklistStr cfg.slowBandwidthLimit ]
        (builtins.readFile ./focus-script.bash);
  };
in
{
  options.sifr.productivity.focusMode = {
    enable = lib.mkOption {
      description = "Enable focus mode command for blocking distracting websites";
      type = lib.types.bool;
      default = false;
    };

    blocklist = lib.mkOption {
      description = "List of domains to block during focus mode";
      type = lib.types.listOf lib.types.str;
      default = [
        "9to5google.com"
        "9to5mac.com"
        "alternativeto.net"
        "apple.com"
        "archive.is"
        "archive.ph"
        "arstechnica.com"
        "bsky.app"
        "distrowatch.com"
        "dxwatch.com"
        "en.wikipedia.org"
        "finance.yahoo.com"
        "grokipedia.com"
        "gulfbusiness.com"
        "gulfnews.com"
        "gulftoday.ae"
        "hackaday.com"
        "hamspots.net"
        "investing.com"
        "lifehacker.com"
        "lobste.rs"
        "lwn.net"
        "m.youtube.com"
        "mas.to"
        "mashable.com"
        "masto.ai"
        "mastodon.social"
        "medium.com"
        "mobile.twitter.com"
        "netflix.com"
        "news.ycombinator.com"
        "old.reddit.com"
        "omgubuntu.co.uk"
        "reddit.com"
        "reuters.com"
        "slashdot.org"
        "thenationalnews.com"
        "tiktok.com"
        "twitter.com"
        "web.archive.org"
        "www.amazon.ae"
        "www.amazon.co.uk"
        "www.amazon.com"
        "www.androidauthority.com"
        "www.bloomberg.com"
        "www.dxengineering.com"
        "www.eham.net"
        "www.ft.com"
        "www.hamradio.com"
        "www.huffpost.com"
        "www.khaleejtimes.com"
        "www.linkedin.com"
        "www.linux.com"
        "www.macrumors.com"
        "www.makeuseof.com"
        "www.marketwatch.com"
        "www.netflix.com"
        "www.phoronix.com"
        "www.producthunt.com"
        "www.qrz.com"
        "www.quora.com"
        "www.reddit.com"
        "www.reversebeacon.net"
        "www.theverge.com"
        "www.timeoutdubai.com"
        "www.tradingview.com"
        "www.wired.com"
        "www.wsj.com"
        "www.youtube.com"
        "x.com"
        "xcancel.com"
        "youtube.com"

      ];
    };

    slowBandwidthLimit = lib.mkOption {
      description = "Bandwidth limit when --slow flag is used (e.g., '1mbit', '5mbit', '512kbit')";
      type = lib.types.str;
      default = "1mbit";
      example = "512kbit";
    };
  };

  config = lib.mkIf cfg.enable {
    # Install the focus command
    environment.systemPackages = [ focusScript ];

    # Create state directory using systemd tmpfiles
    systemd.tmpfiles.rules = [
      "d /var/lib/focus-mode 0755 root root -"
    ];

    # Cleanup service that checks if focus mode has expired and cleans up
    # This runs on boot and can be triggered on resume
    systemd.services.focus-mode-cleanup-check = {
      description = "Check and clean up expired focus mode";
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart =
          let
            cleanupScript = pkgs.writeShellScript "focus-cleanup-check" ''
              STATE_DIR="/var/lib/focus-mode"
              ACTIVE_FLAG="$STATE_DIR/active"

              # If no active flag, nothing to clean
              if [ ! -f "$ACTIVE_FLAG" ]; then
                echo "No active focus mode, nothing to clean"
                exit 0
              fi

              expiry_ts=$(cat "$ACTIVE_FLAG" 2>/dev/null || echo "0")
              current_ts=$(date +%s)

              # If expired or invalid, run cleanup
              if ! [[ "$expiry_ts" =~ ^[0-9]+$ ]] || [ "$current_ts" -ge "$expiry_ts" ]; then
                echo "Focus mode expired or invalid, running cleanup..."
                # Run the full cleanup using the focus script
                ${focusScript}/bin/focus _cleanup
              else
                remaining=$((expiry_ts - current_ts))
                echo "Focus mode still active, $remaining seconds remaining"
              fi
            '';
          in
          "${cleanupScript}";
        RemainAfterExit = false;
      };
    };

    # Use system-sleep hook to run cleanup check on resume
    # This is the reliable way to catch resume events
    powerManagement.resumeCommands = ''
      # Check if focus mode has expired after resume from suspend
      ${pkgs.systemd}/bin/systemctl start --no-block focus-mode-cleanup-check.service
    '';
  };
}
