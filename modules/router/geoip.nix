{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.sifr.router;

  converter = pkgs.writers.writePython3Bin "geoip-convert" { } (builtins.readFile ./geoip-convert.py);

  stateDir = cfg.geoip.stateDir;
in
{
  options.sifr.router.geoip = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Fetch MaxMind's GeoLite2 Country database and let the peers page report
        where a peer actually is.

        Off by default because it needs a licence key. Without it the country
        column is simply empty; nothing else changes, and in particular nothing
        falls back to the ASN registration, which is the wrong answer this
        exists to replace.
      '';
    };

    licenseKeyFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = ''
        Path to a file holding a MaxMind licence key, normally a sops secret.
        The key is never passed on a command line — see the fetch unit.
      '';
    };

    accountId = lib.mkOption {
      type = lib.types.str;
      default = "";
      description = "MaxMind account ID, the username half of the download's basic auth.";
    };

    stateDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/geoip";
      readOnly = true;
      description = ''
        Where geoip-update writes country.tsv and asn.tsv.

        Read-only and stated here because three modules have to agree on it and
        two of them are not this one: web.nix names both files in router-web's
        environment, and modules/persist keeps the directory across the boot
        wipe. A path written out three times is a path that eventually differs
        in one of them.
      '';
    };
  };

  config = lib.mkIf (cfg.enable && cfg.geoip.enable) {
    assertions = [
      {
        assertion = cfg.geoip.licenseKeyFile != null && cfg.geoip.accountId != "";
        message = ''
          sifr.router.geoip.enable needs both licenseKeyFile and accountId.
          MaxMind's download endpoint authenticates with the pair, and a
          missing half fails at fetch time with a 401 that looks like a
          revoked key rather than a missing setting.
        '';
      }
    ];

    # Where the converted table lives. Not in the Nix store and not in this
    # repository: GeoLite2 is licensed, not redistributable, and this repo is
    # public. That is the whole reason this is a runtime fetch rather than a
    # checked-in file like ip2asn-combined.tsv beside it.
    systemd.tmpfiles.rules = [
      "d ${stateDir} 0755 root root -"
    ];

    systemd.services.geoip-update = {
      description = "Fetch and convert the GeoLite2 country database";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];

      serviceConfig = {
        Type = "oneshot";
        # Bounded like the STUN resolver's: a licence key that has been revoked
        # fails every time and would otherwise retry forever.
        Restart = "on-failure";
        RestartSec = "5m";
        RuntimeDirectory = "geoip-update";
      };

      startLimitIntervalSec = 3600;
      startLimitBurst = 4;

      path = with pkgs; [
        curl
        unzip
        coreutils
      ];

      script = ''
        set -euo pipefail

        work="$RUNTIME_DIRECTORY"

        # The key reaches curl through a config file on stdin, never through
        # argv. Everything on a command line is world-readable in ps for as
        # long as the process runs, and this key is shared across both routers.
        # One function for both editions. They differ only in the archive name,
        # the file the CSV directory is located by, and which converter mode
        # runs — everything else, including the credential handling, is
        # identical and must stay that way.
        fetch() {
          edition="$1" marker="$2" mode="$3" out="$4"

          # The key reaches curl through a config file on stdin, never through
          # argv. Everything on a command line is world-readable in ps for as
          # long as the process runs, and this key is shared across both
          # routers.
          {
            printf 'url = "%s"\n' \
              "https://download.maxmind.com/geoip/databases/$edition/download?suffix=zip"
            printf 'user = "%s:%s"\n' \
              ${lib.escapeShellArg cfg.geoip.accountId} \
              "$(cat ${lib.escapeShellArg (toString cfg.geoip.licenseKeyFile)})"
            printf 'output = "%s"\n' "$work/$edition.zip"
            printf 'location\nsilent\nshow-error\nfail\nretry = 3\nmax-time = 300\n'
          } | curl -K -

          rm -rf "$work/csv"
          unzip -q -o "$work/$edition.zip" -d "$work/csv"

          # The archive unpacks into a dated directory whose name changes with
          # every release, so the CSVs are found rather than assumed. Checked
          # before dirname, not after: dirname of an empty string is ".",
          # which passes a -n test and would send the converter looking for
          # CSVs in the working directory.
          found="$(find "$work/csv" -name "$marker" -print -quit)"
          [ -n "$found" ] || { echo "geoip-update: no $marker in $edition" >&2; exit 1; }

          ${converter}/bin/geoip-convert "$mode" "$(dirname "$found")" "$out"

          # ~50 MB of intermediate state per edition that nothing reads again.
          # RuntimeDirectory is tmpfs and systemd clears it at stop, but the
          # two editions should not both be unpacked at once on a box that is
          # also holding two range tables in router-web.
          rm -rf "$work/$edition.zip" "$work/csv"
        }

        fetch GeoLite2-Country-CSV GeoLite2-Country-Locations-en.csv \
          country ${stateDir}/country.tsv
        fetch GeoLite2-ASN-CSV GeoLite2-ASN-Blocks-IPv4.csv \
          asn ${stateDir}/asn.tsv
      '';
    };

    systemd.timers.geoip-update = {
      description = "Refresh the GeoLite2 country database";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        # GeoLite2 is republished twice a week. Weekly with a persistent timer
        # keeps the table within a few days of current without pulling 50 MB
        # more often than the data changes.
        OnCalendar = "weekly";
        Persistent = true;
        RandomizedDelaySec = "6h";
      };
    };

    # router-web's two table paths are set in web.nix, not here, and gated on
    # this option being on. They used to be set from this file, and that was a
    # bug worth recording: web.nix sets ROUTER_IP2ASN_FILE through
    # serviceConfig.Environment, a list, while this file set it through
    # services.router-web.environment, an attrset. Those are different options
    # that do not merge — both reached the unit, as two Environment= lines, and
    # systemd takes the last assignment, which was web.nix's. The mkForce here
    # won the Nix merge it was in and then lost the one that decided the answer,
    # silently, for as long as the file existed. One writer per variable.
  };
}
