{
  lib,
  config,
  pkgs,
  ...
}:

let
  hageziTifUrl = "https://cdn.jsdelivr.net/gh/hagezi/dns-blocklists@latest/ips/tif.txt";

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

        if [ -s "$STATE_DIRECTORY/hagezi-tif.nft" ]; then
          nft -f "$STATE_DIRECTORY/hagezi-tif.nft"
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
        tmpnft="$(mktemp)"
        trap 'rm -f "$tmp" "$tmpnft"' EXIT

        curl --fail --silent --show-error --location \
          "${hageziTifUrl}" \
          -o "$tmp"

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

        for line in src.read_text().splitlines():
            s = line.split("#", 1)[0].strip()
            if not s:
                continue
            try:
                net = ipaddress.ip_network(s, strict=False)
            except ValueError:
                continue

            if net.version == 4:
                if str(net) not in allow4:
                    v4.append(str(net))
            else:
                if str(net) not in allow6:
                    v6.append(str(net))

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

        install -Dm0644 "$tmp"    "$STATE_DIRECTORY/hagezi-tif.txt"
        install -Dm0644 "$tmpnft" "$STATE_DIRECTORY/hagezi-tif.nft"
      '';
    };

    systemd.timers.nft-blocklists-update = {
      description = "Periodic nftables blocklist refresh";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "5min";
        OnUnitActiveSec = "6h";
        RandomizedDelaySec = "30min";
        Persistent = true;
      };
    };
  };
}
