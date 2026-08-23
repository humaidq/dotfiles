{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.sifr.router;
  inherit (cfg) ont;

  # Shared with the o11y client module, which points node_exporter's textfile
  # collector at the same path. Kept as a plain string in both places for the
  # same reason as in qos-metrics.nix.
  textfileDir = "/var/lib/prometheus-node-exporter-text-files";

  # The ONT stores these as IEEE-754 single-precision floats but cfgcli prints
  # the raw storage word as a signed decimal integer, so every reading comes
  # back as a nine- or ten-digit number that has to be reinterpreted rather
  # than parsed. Python for that reason: struct.unpack is one line, and the
  # shell equivalent is a hand-rolled bit-twiddling exercise.
  ontTextfile = pkgs.writers.writePython3Bin "ont-textfile" { flakeIgnore = [ "E501" ]; } ''
    """Collect GPON ONT optical diagnostics into a Prometheus textfile.

    The uplink prober answers "is the line slow"; this answers "is the fibre
    itself going". They are different failures with different remedies, and
    the anchors in sifr.router.uplink cannot distinguish them: a dirty
    connector and a congested peering both show up there as latency.

    One source, read over SSH from the ONT's own configuration manager:

        cfgcli -G InternetGatewayDevice.WANDevice.1.X_CT-COM_GponInterfaceConfig.

    which is read-only and, unlike the `omcli console datastore` route, neither
    writes a file full of subscriber credentials to the ONT's /tmp nor blinks
    every LED on the front panel while it runs.
    """

    import os
    import struct
    import subprocess
    import sys
    import tempfile

    ONT_HOST = "${ont.address}"
    USER_FILE = "${ont.usernameFile}"
    PASS_FILE = "${ont.passwordFile}"
    OUT = "${ont.metricsFile}"

    CFGCLI_PATH = "InternetGatewayDevice.WANDevice.1.X_CT-COM_GponInterfaceConfig."

    # These two ONTs run a 2022 Nokia build on a 3.4 kernel, and the Dropbear
    # in it predates every algorithm modern OpenSSH will negotiate by default:
    # one of the pair offers nothing newer than ssh-rsa host keys and SHA-1
    # group exchange. The "+" forms re-enable those for this one destination
    # without touching the router's own ssh_config.
    #
    # Host-key checking is off, which is worth being explicit about rather than
    # quiet: the ONT is a directly attached layer-2 neighbour on a dedicated
    # point-to-point link with exactly one other device on it, so there is no
    # position from which to interpose. Pinning would mean carrying a
    # per-unit key that changes on any firmware push from the operator, and
    # failing the scrape when it does.
    SSH_OPTS = [
        "-oHostKeyAlgorithms=+ssh-rsa",
        "-oKexAlgorithms=+diffie-hellman-group14-sha1,diffie-hellman-group1-sha1",
        "-oStrictHostKeyChecking=no",
        "-oUserKnownHostsFile=/dev/null",
        "-oGlobalKnownHostsFile=/dev/null",
        "-oLogLevel=ERROR",
        "-oBatchMode=no",
        "-oConnectTimeout=10",
    ]

    # (cfgcli name, metric suffix, help text, extra labels)
    #
    # "SupplyVottage" is spelled that way in the ONT's data model. It is a
    # vendor typo, not one here, and correcting it would simply fail to match.
    READINGS = [
        ("RXPower", "rx_power_dbm", "Received optical power at 1490 nm", {}),
        ("TXPower", "tx_power_dbm", "Transmitted optical power at 1310 nm", {}),
        ("TransceiverTemperature", "transceiver_temperature_celsius", "Optical module temperature", {}),
        ("SupplyVottage", "supply_voltage_volts", "Optical module supply voltage", {}),
        ("BiasCurrent", "bias_current_amperes", "Laser bias current", {}),
        ("RXPowerLower", "rx_power_threshold_dbm", "Configured receive power alarm threshold", {"bound": "lower"}),
        ("RXPowerUpper", "rx_power_threshold_dbm", "Configured receive power alarm threshold", {"bound": "upper"}),
    ]


    class Metrics:
        """Accumulates samples and emits them grouped under one HELP/TYPE."""

        def __init__(self):
            self.meta = {}
            self.samples = {}

        def add(self, name, help_text, kind, labels, value):
            if name not in self.meta:
                self.meta[name] = (help_text, kind)
                self.samples[name] = []
            rendered = ",".join(f'{k}="{v}"' for k, v in sorted(labels.items()))
            suffix = f"{{{rendered}}}" if rendered else ""
            self.samples[name].append(f"{name}{suffix} {value}")

        def render(self):
            lines = []
            for name in sorted(self.meta):
                help_text, kind = self.meta[name]
                lines.append(f"# HELP {name} {help_text}")
                lines.append(f"# TYPE {name} {kind}")
                lines.extend(sorted(self.samples[name]))
            return "\n".join(lines) + "\n"


    def read_secret(path):
        """Read a sops-provisioned secret, tolerating a trailing newline."""
        try:
            with open(path, "r") as fh:
                return fh.read().strip()
        except OSError as err:
            print(f"ont-textfile: cannot read {path}: {err}", file=sys.stderr)
            return None


    def fetch():
        """Return cfgcli's output for the GPON interface object, or None."""
        username = read_secret(USER_FILE)
        if username is None:
            return None

        argv = ["sshpass", "-f", PASS_FILE, "ssh"]
        argv += SSH_OPTS
        argv += [f"{username}@{ONT_HOST}", f"/sbin/cfgcli -G {CFGCLI_PATH}"]
        try:
            done = subprocess.run(argv, capture_output=True, text=True, timeout=30)
        except (OSError, subprocess.TimeoutExpired) as err:
            print(f"ont-textfile: ssh to {ONT_HOST} failed: {err}", file=sys.stderr)
            return None
        if done.returncode != 0:
            print(f"ont-textfile: cfgcli exited {done.returncode}", file=sys.stderr)
            return None
        return done.stdout


    def parse(text):
        """Turn cfgcli's aligned "Name = Value" block into a dict."""
        fields = {}
        for line in text.splitlines():
            if "=" not in line:
                continue
            name, _, value = line.partition("=")
            fields[name.strip()] = value.strip()
        return fields


    def as_float(raw):
        """Reinterpret cfgcli's decimal storage word as a float32.

        Returns None for values that are not a 32-bit integer, and for the
        non-finite ones. An unprovisioned threshold reads as -8388608, which is
        the bit pattern 0xFF800000 -- negative infinity -- and Prometheus has no
        way to represent that which is not a lie about the reading.
        """
        try:
            word = int(raw)
        except ValueError:
            return None
        try:
            value = struct.unpack(">f", struct.pack(">i", word))[0]
        except struct.error:
            return None
        if value != value or value in (float("inf"), float("-inf")):
            return None
        return value


    def collect(metrics, fields):
        """Add every readable optical value. Returns True if any was."""
        found = False
        for name, suffix, help_text, labels in READINGS:
            if name not in fields:
                continue
            value = as_float(fields[name])
            if value is None:
                continue
            metrics.add(f"router_ont_{suffix}", help_text, "gauge", labels, value)
            found = True
        return found


    def main():
        metrics = Metrics()
        text = fetch()
        fields = parse(text) if text else {}

        ok = collect(metrics, fields) if fields else False

        # Separate from collector_success on purpose. The PON can be down while
        # the scrape itself works perfectly, and that is the single most
        # interesting minute this collector will ever record -- it must not be
        # indistinguishable from the router failing to log in.
        if "Status" in fields:
            metrics.add(
                "router_ont_pon_up",
                "Whether the ONT reports its GPON uplink as up",
                "gauge",
                {},
                1 if fields["Status"].lower() == "up" else 0,
            )

        metrics.add(
            "router_ont_collector_success",
            "Whether the ONT collector produced any samples on this run",
            "gauge",
            {},
            1 if ok else 0,
        )

        # Written through a temporary file in the same directory and renamed,
        # for the reason spelled out in qos-metrics.nix: a half-written file is
        # a parse error that discards every metric in the directory.
        directory = os.path.dirname(OUT)
        try:
            handle, tmp = tempfile.mkstemp(dir=directory, suffix=".tmp")
            with os.fdopen(handle, "w") as fh:
                fh.write(metrics.render())
            os.chmod(tmp, 0o644)
            os.replace(tmp, OUT)
        except OSError as err:
            print(f"ont-textfile: cannot write {OUT}: {err}", file=sys.stderr)
            return 1
        return 0


    sys.exit(main())
  '';
in
{
  options.sifr.router.ont = {
    enable = lib.mkEnableOption ''
      reading optical diagnostics from the ISP's GPON ONT.

      The ONT is the fibre terminal upstream of the WAN port. It is not a
      router here -- it bridges the Internet service to this machine as
      untagged PPPoE and does the operator's VLAN work internally -- but it
      does hold the only measurement of the physical line: received and
      transmitted optical power, module temperature, and laser bias current.
      Nothing else on this network can see whether the fibre is degrading
    '';

    address = lib.mkOption {
      type = lib.types.str;
      default = "192.168.1.254";
      description = ''
        Management address of the ONT, on its own subnet on the WAN link.
        Reachable only because routerAddress below puts this machine on that
        subnet; it is not part of the PPPoE service and no traffic to it
        leaves the cable between the two devices.
      '';
    };

    routerAddress = lib.mkOption {
      type = lib.types.str;
      default = "192.168.1.2/24";
      description = ''
        Address this machine takes on the WAN link in order to talk to the
        ONT, with prefix length.

        An RFC1918 address on the WAN interface looks wrong at first glance
        and is not: the WAN port carries PPPoE, which is a different
        EtherType, so ordinary IPv4 to the ONT and the PPP session coexist on
        the same wire without interacting. Every route the Internet uses is
        on ${cfg.ppp}, and this subnet is unreachable from the LAN -- see the
        forward drops this module installs.
      '';
    };

    usernameFile = lib.mkOption {
      type = lib.types.path;
      description = ''
        File holding the ONT management username. A secret rather than an
        option value because this repository is public and the account is a
        root shell on carrier equipment.
      '';
    };

    passwordFile = lib.mkOption {
      type = lib.types.path;
      description = ''
        File holding the ONT management password, passed to sshpass. Same
        reasoning as usernameFile.
      '';
    };

    metricsFile = lib.mkOption {
      type = lib.types.str;
      default = "${textfileDir}/ont.prom";
      description = ''
        Where the collector publishes and where the status page reads.

        One option rather than the same string in two modules, because they
        have to agree: node_exporter scrapes the directory this sits in, and
        router-web reads the file itself to render the optical section. The
        file is world-readable by design — router-web runs under DynamicUser
        and has no credential of its own, so reading what the collector left
        behind is how it sees the ONT without being able to reach it.
      '';
    };

    interval = lib.mkOption {
      type = lib.types.str;
      default = "5min";
      description = ''
        How often to read the ONT, as a systemd time span.

        Deliberately far slower than the 15s qos-textfile uses. Each sample
        costs a full SSH handshake against a 2011-era MIPS CPU, and what is
        being measured moves over weeks: connectors oxidise and splices drift,
        they do not step. A fibre problem sharp enough to matter inside five
        minutes takes the PPP session with it, and the uplink prober already
        watches that at a much finer grain.
      '';
    };
  };

  config = lib.mkIf (cfg.enable && ont.enable) (
    lib.mkMerge [
      {
        # The address that makes the ONT reachable at all. Declared here rather
        # than added by hand after every reboot, which is how this started.
        #
        # Merges into the "10-wan" network defined in default.nix. The client
        # specialisation replaces systemd.network.networks wholesale with mkForce,
        # so this correctly disappears there along with pppd.
        systemd.network.networks."10-wan".address = [ ont.routerAddress ];

        # Only this machine may reach the ONT.
        #
        # Strictly this is already true: filterForward defaults the forward chain
        # to drop and the one accept in it is ${cfg.lan0} -> ${cfg.ppp}, so a LAN
        # client's packet to the ONT has nothing to match. That is an argument
        # from the absence of a rule, though, and the thing being protected is a
        # root shell on the operator's equipment. One added accept elsewhere --
        # for the travel VPN, say, or a future second LAN -- would open it
        # silently and nothing would fail visibly enough to notice.
        #
        # A separate base chain at a lower priority than the main filter, so it
        # decides first and the guarantee does not depend on rule ordering inside
        # the NixOS firewall's chain. `policy accept` is correct here: an accept
        # in one base chain does not terminate the others, so this chain can only
        # ever subtract.
        #
        # Both directions of the WAN interface are dropped rather than just the
        # ONT's subnet, and that is not overreach: forwarded traffic belongs on
        # ${cfg.ppp}. Nothing is ever routed in or out of ${cfg.wan} itself.
        networking.nftables.tables.router-ont = {
          family = "inet";
          content = ''
            chain ont-isolate {
              type filter hook forward priority -10; policy accept;

              oifname "${cfg.wan}" counter drop comment "No forwarding to the ONT link; management is router-only"
              iifname "${cfg.wan}" counter drop comment "No forwarding from the ONT link"
            }
          '';
        };
      }

      # The collector, but only where something scrapes it. The directory it
      # writes into is created by the o11y client module, which is also what
      # points node_exporter at it -- the same gate qos-metrics.nix uses, and for
      # the same reason. The access and isolation above are deliberately outside
      # it: reaching the ONT by hand is useful on a router with no metrics stack.
      (lib.mkIf config.sifr.personal.o11y.client.enable {
        systemd.services.ont-textfile = {
          description = "Collect GPON ONT optical diagnostics into a Prometheus textfile";

          path = with pkgs; [
            openssh
            sshpass
          ];

          serviceConfig = {
            Type = "oneshot";
            ExecStart = lib.getExe ontTextfile;

            # ssh wants somewhere to call home even when every known-hosts file is
            # /dev/null. PrivateTmp gives it a private one.
            Environment = "HOME=/tmp";

            # Opens one TCP connection and writes one file. No capabilities at all
            # -- unlike qos-textfile it never touches netlink.
            CapabilityBoundingSet = [ "" ];
            AmbientCapabilities = [ "" ];
            NoNewPrivileges = true;
            ProtectSystem = "strict";
            ProtectHome = true;
            PrivateTmp = true;
            PrivateDevices = true;
            ReadWritePaths = [ textfileDir ];
            RestrictAddressFamilies = [
              "AF_UNIX"
              "AF_INET"
            ];

            # A wedged SSH to an unresponsive ONT must not hold the unit open past
            # the next timer tick. The script's own subprocess timeout is 30s;
            # this is the backstop for ssh hanging somewhere it cannot see.
            TimeoutStartSec = "60s";
          };
        };

        systemd.timers.ont-textfile = {
          description = "Sample ONT optical diagnostics regularly";
          wantedBy = [ "timers.target" ];
          timerConfig = {
            OnBootSec = "2min";
            OnUnitActiveSec = ont.interval;
            AccuracySec = "10s";
          };
        };
      })
    ]
  );
}
