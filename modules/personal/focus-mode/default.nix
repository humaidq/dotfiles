{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.sifr.personal.focusMode;

  blocklistStr = lib.concatStringsSep " " cfg.blocklist;
  whitelistStr = lib.concatStringsSep " " cfg.whitelist;

  focusScript = pkgs.writeShellApplication {
    name = "focus";
    runtimeInputs = with pkgs; [
      dnsutils
      iptables
      systemd
      coreutils
      gnugrep
      gnused
      bc
      util-linux
    ];
    text = lib.replaceStrings [ "@blocklist@" "@whitelist@" ] [ blocklistStr whitelistStr ] (
      builtins.readFile ./focus-script.bash
    );
  };
in
{
  options.sifr.personal.focusMode = {
    enable = lib.mkEnableOption "focus mode command for blocking distracting websites";

    blocklist = lib.mkOption {
      description = "List of domains to block during focus mode";
      type = lib.types.listOf lib.types.str;
      default = [
        "9to5google.com"
        "9to5mac.com"
        "aljazeera.com"
        "aljazeera.net"
        "alternativeto.net"
        "amazon.com"
        "amazon.ae"
        "apple.com"
        "archive.is"
        "archive.ph"
        "arstechnica.com"
        "bbc.com"
        "bleacherreport.com"
        "blockchain.info"
        "blogger.com"
        "bloomberg.com"
        "boingboing.net"
        "bsky.app"
        "break.com"
        "businessinsider.com"
        "buzzfeed.com"
        "cbssports.com"
        "cnet.com"
        "cnbc.com"
        "cnn.com"
        "coinbase.com"
        "coinmarketcap.com"
        "collegehumor.com"
        "craigslist.org"
        "cracked.com"
        "deviantart.com"
        "digg.com"
        "distrowatch.com"
        "dxwatch.com"
        "ebay.com"
        "economist.com"
        "english.aljazeera.net"
        "en.wikipedia.org"
        "engadget.com"
        "espn.com"
        "etsy.com"
        "facebook.com"
        "fark.com"
        "finance.yahoo.com"
        "forbes.com"
        "foxnews.com"
        "foxsports.com"
        "funnyordie.com"
        "gigaom.com"
        "gizmodo.com"
        "gmail.com"
        "grokipedia.com"
        "gulfbusiness.com"
        "gulfnews.com"
        "gulftoday.ae"
        "hackaday.com"
        "hamspots.net"
        "huffingtonpost.com"
        "hulu.com"
        "imdb.com"
        "imgur.com"
        "instagram.com"
        "investing.com"
        "lifehacker.com"
        "linkedin.com"
        "liveleak.com"
        "lobste.rs"
        "lwn.net"
        "macrumors.com"
        "mail.google.com"
        "mail.yahoo.com"
        "m.youtube.com"
        "m.aljazeera.net"
        "mas.to"
        "mashable.com"
        "masto.ai"
        "mastodon.social"
        "meetup.com"
        "metafilter.com"
        "medium.com"
        "mlb.com"
        "msnbc.com"
        "mobile.twitter.com"
        "nba.com"
        "netflix.com"
        "nbcnews.com"
        "news.google.com"
        "news.ycombinator.com"
        "nfl.com"
        "nhl.com"
        "noon.com"
        "npr.org"
        "nytimes.com"
        "old.reddit.com"
        "omgubuntu.co.uk"
        "pinterest.com"
        "popurls.com"
        "producthunt.com"
        "quora.com"
        "reddit.com"
        "readwrite.com"
        "recode.net"
        "reuters.com"
        "soundcloud.com"
        "slashdot.org"
        "techcrunch.com"
        "techmeme.com"
        "ted.com"
        "thenationalnews.com"
        "theguardian.com"
        "theonion.com"
        "theverge.com"
        "thenextweb.com"
        "time.com"
        "tiktok.com"
        "tmz.com"
        "tomshardware.com"
        "tumblr.com"
        "twitch.tv"
        "twitter.com"
        "usatoday.com"
        "venturebeat.com"
        "vice.com"
        "vimeo.com"
        "washingtonpost.com"
        "web.archive.org"
        "wired.com"
        "wsj.com"
        "www.amazon.ae"
        "www.amazon.co.uk"
        "www.amazon.com"
        "www.aljazeera.com"
        "www.aljazeera.net"
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
        "yahoo.com"
        "youtube.com"
        "zdnet.com"
      ];
    };

    whitelist = lib.mkOption {
      description = "Domains whose resolved IP addresses should stay reachable even if blocked domains share them";
      type = lib.types.listOf lib.types.str;
      default = [
        "google.com"
        "channels.nixos.org"
        "cache.nixos.org"
        "notebooklm.google.com"
        "outlook.cloud.microsoft"
        "teams.cloud.microsoft"
        "web.whatsapp.com"
        "google.ae"
        "www.google.com"
      ];
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ focusScript ];

    systemd.tmpfiles.rules = [
      "d /var/lib/focus-mode 0755 root root -"
    ];

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

              if [ ! -f "$ACTIVE_FLAG" ]; then
                echo "No active focus mode, nothing to clean"
                exit 0
              fi

              expiry_ts=$(cat "$ACTIVE_FLAG" 2>/dev/null || echo "0")
              current_ts=$(date +%s)

              if ! [[ "$expiry_ts" =~ ^[0-9]+$ ]] || [ "$current_ts" -ge "$expiry_ts" ]; then
                echo "Focus mode expired or invalid, running cleanup..."
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

    powerManagement.resumeCommands = ''
      ${pkgs.systemd}/bin/systemctl start --no-block focus-mode-cleanup-check.service
    '';
  };
}
