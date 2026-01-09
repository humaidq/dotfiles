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
        "youtube.com"
        "youtu.be"
        "m.youtube.com"
        "www.youtube.com"
        "reddit.com"
        "www.reddit.com"
        "old.reddit.com"
        "twitter.com"
        "x.com"
        "xcancel.com"
        "mobile.twitter.com"
        "netflix.com"
        "www.netflix.com"
        "news.ycombinator.com"
        "lobste.rs"
        "apple.com"
        "gulfnews.com"
        "www.khaleejtimes.com"
        "www.timeoutdubai.com"
        "www.bloomberg.com"
        "archive.is"
        "archive.ph"
        "reuters.com"
        "thenationalnews.com"
        "gulfbusiness.com"
        "arstechnica.com"
        "9to5google.com"
        "www.theverge.com"
        "9to5mac.com"
        "www.macrumors.com"
        "investing.com"
        "www.ft.com"
        "gulftoday.ae"
        "omgubuntu.co.uk"
        "www.linux.com"
        "lwn.net"
        "www.phoronix.com"
        "hackaday.com"
        "www.quora.com"
        "distrowatch.com"
        "www.amazon.ae"
        "www.amazon.com"
        "www.amazon.co.uk"
        "www.qrz.com"
        "www.wsj.com"
        "en.wikipedia.org"
        "grokipedia.com"
        "www.wired.com"
        "web.archive.org"
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

    # Optional: Add a cleanup service that runs on boot to clean stale state
    systemd.services.focus-mode-boot-cleanup = {
      description = "Clean up stale focus mode state on boot";
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${pkgs.bash}/bin/bash -c 'rm -f /var/lib/focus-mode/active /var/lib/focus-mode/blocked-ips.txt /var/lib/focus-mode/bandwidth'";
        RemainAfterExit = false;
      };
    };
  };
}
