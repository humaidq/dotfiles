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

  # Optional whitelists
  allow4 = [ ];
  allow6 = [ ];
  cfg = config.sifr.router;
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

        chain forward_blocklists {
          type filter hook forward priority -10; policy accept;

          # Blocks LAN clients from reaching listed IPs
          ip daddr @remote_block4 drop comment "block forwarded IPv4 destinations"
          ip6 daddr @remote_block6 drop comment "block forwarded IPv6 destinations"
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

        tmp="$(mktemp)"
        downloads="$(mktemp -d)"
        tmpnft="$(mktemp)"
        trap 'rm -rf "$downloads"; rm -f "$tmp" "$tmpnft"' EXIT

        : > "$tmp"
        ${lib.concatMapStringsSep "\n" (url: ''
          curl --fail --silent --show-error --location \
            "${url}" \
            -o "$downloads/${builtins.hashString "sha256" url}.txt"
          cat "$downloads/${builtins.hashString "sha256" url}.txt" >> "$tmp"
          printf '\n' >> "$tmp"
        '') ipBlocklistUrls}

        python3 - "$tmp" "$tmpnft" <<'PY'
        import ipaddress
        import pathlib
        import sys

        src = pathlib.Path(sys.argv[1])
        dst = pathlib.Path(sys.argv[2])

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
        if len(v4) + len(v6) < 1000:
            raise SystemExit("refusing suspiciously small blocklist")

        with dst.open("w") as f:
            f.write("flush set inet router-blocklists remote_block4\n")
            if v4:
                f.write("add element inet router-blocklists remote_block4 {\n")
                for i, elem in enumerate(v4):
                    comma = "," if i + 1 < len(v4) else ""
                    f.write(f"  {elem}{comma}\n")
                f.write("}\n")

            f.write("flush set inet router-blocklists remote_block6\n")
            if v6:
                f.write("add element inet router-blocklists remote_block6 {\n")
                for i, elem in enumerate(v6):
                    comma = "," if i + 1 < len(v6) else ""
                    f.write(f"  {elem}{comma}\n")
                f.write("}\n")
        PY

        # Validate then apply atomically
        nft -c -f "$tmpnft"
        nft -f "$tmpnft"

        install -Dm0644 "$tmp"    "$STATE_DIRECTORY/ip-blocklists.txt"
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
