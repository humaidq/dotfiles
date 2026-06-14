{
  lib,
  config,
  pkgs,
  ...
}:

let
  ipBlocklistUrls = [
    "https://cdn.jsdelivr.net/gh/hagezi/dns-blocklists@latest/ips/tif.txt"
    "https://feodotracker.abuse.ch/downloads/ipblocklist_recommended.txt"
  ];

  # Known DoH (DNS-over-HTTPS) endpoint IPs. Forwarded LAN->WAN traffic to these
  # on port 443 is dropped so clients cannot tunnel DNS past the router's
  # resolver and blocklists. The router itself is unaffected: it reaches its
  # upstream over DoT (853) from the output path, never forwarded and never 443.
  dohBlocklistUrls = [
    "https://cdn.jsdelivr.net/gh/hagezi/dns-blocklists@latest/ips/doh.txt"
  ];

  # Optional whitelists
  allow4 = [ ];
  allow6 = [ ];
  cfg = config.sifr.router;

  # Feeds processed by the update service. Each entry maps a pair of nftables
  # sets to its source URLs and a minimum-size sanity guard that rejects
  # obviously broken / truncated downloads.
  feeds = [
    {
      set4 = "remote_block4";
      set6 = "remote_block6";
      urls = ipBlocklistUrls;
      minEntries = 1000;
    }
    {
      set4 = "doh_block4";
      set6 = "doh_block6";
      urls = dohBlocklistUrls;
      minEntries = 100;
    }
  ];
in
{

  config = lib.mkIf cfg.enable {
    networking.nftables.enable = true;

    networking.nftables.tables.router-blocklists = {
      family = "inet";
      content = ''
        set remote_block4 {
          type ipv4_addr
          flags interval
        }

        set remote_block6 {
          type ipv6_addr
          flags interval
        }

        set doh_block4 {
          type ipv4_addr
          flags interval
        }

        set doh_block6 {
          type ipv6_addr
          flags interval
        }

        chain forward_blocklists {
          type filter hook forward priority -10; policy accept;

          # Blocks LAN clients from reaching listed IPs
          ip daddr @remote_block4 drop comment "block forwarded IPv4 destinations"
          ip6 daddr @remote_block6 drop comment "block forwarded IPv6 destinations"
        }

        chain forward_doh {
          type filter hook forward priority -10; policy accept;

          # Block LAN clients from tunnelling DNS over HTTPS to known DoH
          # endpoints. Scoped to LAN->WAN on 443 (TCP and UDP/QUIC) so the
          # router's own DoT upstream is untouched.
          iifname "${cfg.lan0}" oifname "${cfg.ppp}" tcp dport 443 ip daddr @doh_block4 drop comment "Block LAN DoH bypass (IPv4)"
          iifname "${cfg.lan0}" oifname "${cfg.ppp}" tcp dport 443 ip6 daddr @doh_block6 drop comment "Block LAN DoH bypass (IPv6)"
          iifname "${cfg.lan0}" oifname "${cfg.ppp}" udp dport 443 ip daddr @doh_block4 drop comment "Block LAN DoH over QUIC (IPv4)"
          iifname "${cfg.lan0}" oifname "${cfg.ppp}" udp dport 443 ip6 daddr @doh_block6 drop comment "Block LAN DoH over QUIC (IPv6)"
        }

        chain output_blocklists {
          type filter hook output priority -10; policy accept;

          # Blocks the router itself from reaching listed IPs
          ip daddr @remote_block4 drop comment "block router IPv4 destinations"
          ip6 daddr @remote_block6 drop comment "block router IPv6 destinations"
        }

        # drop traffic from listed IPs:
        chain input_blocklists {
          type filter hook input priority -10; policy accept;
          ip saddr @remote_block4 drop
          ip6 saddr @remote_block6 drop
        }
      '';
    };

    systemd.services.nft-blocklists-restore = {
      description = "Restore cached nftables blocklists";
      wantedBy = [ "multi-user.target" ];
      after = [ "nftables.service" ];
      wants = [ "nftables.service" ];

      serviceConfig = {
        Type = "oneshot";
        StateDirectory = "nft-blocklists";
      };

      path = [
        pkgs.nftables
        pkgs.coreutils
      ];

      script = ''
        set -euo pipefail

        if [ -s "$STATE_DIRECTORY/ip-blocklists.nft" ]; then
          nft -f "$STATE_DIRECTORY/ip-blocklists.nft"
        fi
      '';
    };

    systemd.services.nft-blocklists-update = {
      description = "Download and apply nftables blocklists";
      after = [
        "network-online.target"
        "nftables.service"
        "nft-blocklists-restore.service"
      ];
      wants = [ "network-online.target" ];

      serviceConfig = {
        Type = "oneshot";
        StateDirectory = "nft-blocklists";
      };

      path = [
        pkgs.curl
        pkgs.python3
        pkgs.nftables
        pkgs.coreutils
      ];

      script = ''
        set -euo pipefail

        downloads="$(mktemp -d)"
        tmpnft="$(mktemp)"
        alltxt="$(mktemp)"
        trap 'rm -rf "$downloads"; rm -f "$tmpnft" "$alltxt"' EXIT

        : > "$tmpnft"
        : > "$alltxt"
        ok=0
        failed=0

        ${lib.concatMapStringsSep "\n" (feed: ''
          feedtxt="$(mktemp)"
          : > "$feedtxt"
          feedok=0
          ${lib.concatMapStringsSep "\n" (url: ''
            if curl --fail --silent --show-error --location \
                 "${url}" \
                 -o "$downloads/${builtins.hashString "sha256" url}.txt"; then
              cat "$downloads/${builtins.hashString "sha256" url}.txt" >> "$feedtxt"
              printf '\n' >> "$feedtxt"
              ok=$((ok + 1))
              feedok=$((feedok + 1))
            else
              failed=$((failed + 1))
              echo "nft-blocklists-update: feed download failed, skipping: ${url}" >&2
            fi
          '') feed.urls}

          # Only rebuild this feed's sets if at least one of its URLs
          # downloaded; otherwise leave the sets at their cached values.
          if [ "$feedok" -gt 0 ]; then

          python3 - "$feedtxt" "$tmpnft" "${feed.set4}" "${feed.set6}" "${toString feed.minEntries}" <<'PY'
          import ipaddress
          import pathlib
          import sys

          src = pathlib.Path(sys.argv[1])
          dst = pathlib.Path(sys.argv[2])
          set4 = sys.argv[3]
          set6 = sys.argv[4]
          min_entries = int(sys.argv[5])

          allow4 = set(filter(None, """${lib.concatStringsSep "\n" allow4}""".splitlines()))
          allow6 = set(filter(None, """${lib.concatStringsSep "\n" allow6}""".splitlines()))

          v4 = []
          v6 = []
          seen4 = set()
          seen6 = set()

          for line in src.read_text().splitlines():
              s = line.split("#", 1)[0].strip()
              if not s:
                  continue
              try:
                  net = ipaddress.ip_network(s, strict=False)
              except ValueError:
                  continue

              if net.version == 4:
                  net_str = str(net)
                  if net_str not in allow4 and net_str not in seen4:
                      seen4.add(net_str)
                      v4.append(net_str)
              else:
                  net_str = str(net)
                  if net_str not in allow6 and net_str not in seen6:
                      seen6.add(net_str)
                      v6.append(net_str)

          # Sanity guard: refuse obviously broken / truncated downloads
          if len(v4) + len(v6) < min_entries:
              raise SystemExit(f"refusing suspiciously small blocklist for {set4}/{set6}")

          with dst.open("a") as f:
              f.write(f"flush set inet router-blocklists {set4}\n")
              if v4:
                  f.write(f"add element inet router-blocklists {set4} {{\n")
                  for i, elem in enumerate(v4):
                      comma = "," if i + 1 < len(v4) else ""
                      f.write(f"  {elem}{comma}\n")
                  f.write("}\n")

              f.write(f"flush set inet router-blocklists {set6}\n")
              if v6:
                  f.write(f"add element inet router-blocklists {set6} {{\n")
                  for i, elem in enumerate(v6):
                      comma = "," if i + 1 < len(v6) else ""
                      f.write(f"  {elem}{comma}\n")
                  f.write("}\n")
          PY

          cat "$feedtxt" >> "$alltxt"
          else
            echo "nft-blocklists-update: no URLs downloaded for ${feed.set4}/${feed.set6}, leaving sets unchanged" >&2
          fi
          rm -f "$feedtxt"
        '') feeds}

        if [ "$ok" -eq 0 ]; then
          echo "nft-blocklists-update: all $failed feed(s) failed to download, keeping cached blocklist" >&2
          exit 1
        fi
        if [ "$failed" -gt 0 ]; then
          echo "nft-blocklists-update: continuing with $ok of $((ok + failed)) feed(s)" >&2
        fi

        # Validate then apply atomically
        nft -c -f "$tmpnft"
        nft -f "$tmpnft"

        install -Dm0644 "$alltxt"  "$STATE_DIRECTORY/ip-blocklists.txt"
        install -Dm0644 "$tmpnft" "$STATE_DIRECTORY/ip-blocklists.nft"
      '';
    };

    systemd.timers.nft-blocklists-update = {
      description = "Periodic nftables blocklist refresh";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "5min";
        OnUnitActiveSec = "10min";
        RandomizedDelaySec = "2min";
        Persistent = true;
      };
    };
  };
}
