{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.sifr.personal.sdrNoise;

  # Shared with the o11y client module, which points node_exporter's textfile
  # collector at the same path. Kept as a plain string in both places for the
  # same reason as in modules/router/qos-metrics.nix.
  textfileDir = "/var/lib/prometheus-node-exporter-text-files";

  sdrNoiseTextfile =
    pkgs.writers.writePython3Bin "sdr-noise-textfile"
      {
        libraries = [ pkgs.python3Packages.websockets ];
        flakeIgnore = [ "E501" ];
      }
      ''
        """Sweep the HF noise floor on the house SDR into a Prometheus textfile.

        The receiver is a Web-888 running KiwiSDR-derived firmware on an MLA-30+
        loop. It already keeps its own noise history at /snr -- 168 hourly records
        over four fixed bands -- and that is collected here too, because it is free
        and it is the only source with any depth behind it. But four buckets spanning
        0-1.8, 1.8-10, 10-20 and 20-30 MHz cannot answer the question that actually
        gets asked, which is "something got noisy, what and where". A new switching
        supply lifting 200 kHz of spectrum somewhere around 7 MHz moves the 1.8-10
        bucket by a decibel and is otherwise invisible in it.

        So the sweep: retune a receiver channel across HF and read the S-meter, which
        is the same measurement the /snr collector makes, taken on a grid fine enough
        to localise a source.

        Two things make the reading meaningful rather than decorative:

          * AGC is turned off and manual gain pinned to 0 dB before every dwell. With
            AGC on, the S-meter reports the gain the AGC chose, which is a function
            of the loudest thing in the passband and not of the noise floor. This is
            the whole measurement -- an AGC-on sweep looks plausible and means
            nothing.

          * The floor is the 10th percentile of the dwell's samples, not the mean.
            HF is full of intermittent signals, and any average over a band that
            contains one is a measurement of that signal. A low percentile reports
            what the channel sounds like between bursts, which is the definition of
            the noise floor being asked for.

        What this deliberately does NOT do is claim an ITU-R P.372 external noise
        figure. The MLA-30+ has a built-in LNA whose gain is not de-embedded here, so
        the absolute dBm is offset by an unknown constant. Every use of these numbers
        is a comparison -- this band against that one, this week against last -- and
        those are all valid under a constant offset. Publishing an Fa would not be.

        The dBm figures are power in the ${toString cfg.bandwidth} Hz passband. For a
        noise density subtract 10*log10(bandwidth); sdr_noise_bandwidth_hz is exported
        so a dashboard can do that without the number being hardcoded in two places.
        """

        import asyncio
        import json
        import os
        import statistics
        import struct
        import sys
        import tempfile
        import time
        import urllib.request

        import websockets

        ADDRESS = "${cfg.address}"
        OUT = "${cfg.metricsFile}"

        START_KHZ = ${toString cfg.startKHz}
        STOP_KHZ = ${toString cfg.stopKHz}
        STEP_KHZ = ${toString cfg.stepKHz}

        BANDWIDTH = ${toString cfg.bandwidth}
        DWELL = ${toString cfg.dwell}
        DEADLINE = ${toString cfg.deadline}

        # Discarded after each retune. The receiver does not mute across a frequency
        # change, so the first few S-meter frames still describe the previous
        # channel, and at 0.5 MHz steps the previous channel is uncorrelated with
        # this one. Measured at roughly 0.2s on this unit; 0.45 is that with room.
        SETTLE = 0.45

        # Identifies the connection in the receiver's own user list. Without it the
        # sweep shows up as an anonymous listener retuning every two seconds, which
        # is indistinguishable from someone else misbehaving on a public SDR.
        IDENT = "noise-collector"


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


        def fetch(path):
            """GET one of the receiver's plain HTTP status endpoints."""
            try:
                with urllib.request.urlopen(f"http://{ADDRESS}/{path}", timeout=15) as resp:
                    return resp.read().decode("utf-8", "replace")
            except (OSError, ValueError) as err:
                print(f"sdr-noise-textfile: cannot fetch /{path}: {err}", file=sys.stderr)
                return None


        def collect_status(metrics):
            """Export the receiver's own health from /status.

            adc_ov matters more than it looks: an overloading ADC raises the apparent
            floor everywhere at once, so a sweep taken while it is set is a
            measurement of the front end and not of the band. Exported alongside so
            the two can never be read apart.
            """
            text = fetch("status")
            if text is None:
                metrics.add("sdr_up", "Whether the receiver answered its status endpoint", "gauge", {}, 0)
                return
            fields = {}
            for line in text.splitlines():
                key, sep, value = line.partition("=")
                if sep:
                    fields[key.strip()] = value.strip()

            metrics.add("sdr_up", "Whether the receiver answered its status endpoint", "gauge", {}, 1)

            numeric = [
                ("users", "sdr_users", "Listeners currently connected"),
                ("users_max", "sdr_users_max", "Receiver channel limit"),
                ("adc_ov", "sdr_adc_overflow", "ADC overflow flag; a sweep taken while set reads the front end, not the band"),
                ("ant_connected", "sdr_antenna_connected", "Whether the receiver detects its antenna"),
            ]
            for key, name, help_text in numeric:
                try:
                    metrics.add(name, help_text, "gauge", {}, int(fields[key]))
                except (KeyError, ValueError):
                    continue


        def collect_band_history(metrics):
            """Export the newest record of the receiver's built-in hourly /snr history.

            This is the receiver's measurement, not one made here, and it is kept
            because it is the only thing with seven days behind it on the very first
            scrape. Selected by max(seq) rather than by position: /snr is a ring
            buffer and the newest record is wherever the write pointer last was, not
            index 0 or -1.
            """
            text = fetch("snr")
            if text is None:
                return
            try:
                records = json.loads(text)
            except ValueError as err:
                print(f"sdr-noise-textfile: /snr is not JSON: {err}", file=sys.stderr)
                return
            if not records:
                return

            newest = max(records, key=lambda r: r.get("seq", 0))
            for band in newest.get("snr", []):
                try:
                    labels = {"lo_khz": int(band["lo"]), "hi_khz": int(band["hi"])}
                except (KeyError, TypeError, ValueError):
                    continue
                for key, name, help_text in [
                    ("p50", "sdr_band_noise_dbm", "Receiver's own median noise floor for the band"),
                    ("p95", "sdr_band_signal_dbm", "Receiver's own 95th percentile signal level for the band"),
                    ("snr", "sdr_band_snr_db", "Receiver's own reported SNR for the band"),
                ]:
                    if key in band:
                        metrics.add(name, help_text, "gauge", labels, band[key])


        async def sweep(metrics):
            """Retune across HF reading the S-meter. Returns the number of points."""
            edge = int(BANDWIDTH / 2)
            deadline = time.monotonic() + DEADLINE
            swept = 0

            # ping_interval=None because the receiver never answers a websocket ping.
            # Left at the library default the connection is torn down as a dead peer
            # roughly 20 seconds in -- mid-sweep, every time. Liveness is instead the
            # "SET keepalive" sent before each retune, which is the mechanism the
            # protocol actually has.
            uri = f"ws://{ADDRESS}/kiwi/{int(time.time())}/SND"
            async with websockets.connect(
                uri, max_size=None, open_timeout=20, ping_interval=None
            ) as ws:
                await ws.send("SET auth t=kiwi p=")

                # Drain the handshake chatter until the first audio frame, which is
                # the receiver saying the channel is live. Bounded, because a refused
                # auth is answered with a text message and then silence.
                limit = time.monotonic() + 5.0
                while time.monotonic() < limit:
                    try:
                        msg = await asyncio.wait_for(ws.recv(), timeout=1.0)
                    except asyncio.TimeoutError:
                        break
                    if isinstance(msg, bytes):
                        break
                    if "badp=1" in msg:
                        print("sdr-noise-textfile: receiver rejected auth", file=sys.stderr)
                        return 0

                await ws.send(f"SET ident_user={IDENT}")
                await ws.send("SET AR OK in=12000 out=48000")
                await ws.send("SET compression=0")
                await ws.send("SET squelch=0 max=0")

                for khz in range(START_KHZ, STOP_KHZ + 1, STEP_KHZ):
                    if time.monotonic() > deadline:
                        print("sdr-noise-textfile: deadline reached, sweep truncated", file=sys.stderr)
                        break

                    await ws.send("SET keepalive")
                    await ws.send(f"SET mod=usb low_cut=-{edge} high_cut={edge} freq={khz}.00")
                    # Re-sent every dwell rather than once at setup. A mode change
                    # resets the AGC block, so setting it only at connect time
                    # silently reverts to AGC-on after the first retune.
                    await ws.send("SET agc=0 hang=0 thresh=-130 slope=6 decay=1000 manGain=0")

                    samples = []
                    started = time.monotonic()
                    settled = started + SETTLE
                    while time.monotonic() - started < DWELL:
                        try:
                            msg = await asyncio.wait_for(ws.recv(), timeout=2.0)
                        except asyncio.TimeoutError:
                            break
                        if not isinstance(msg, bytes) or msg[0:3] != b"SND":
                            continue
                        body = msg[3:]
                        if len(body) < 7:
                            continue
                        if time.monotonic() < settled:
                            continue
                        # body[0] flags, body[1:5] sequence, body[5:7] S-meter.
                        # The meter is a big-endian half-word in tenths of a dB
                        # offset by 127, which is the receiver's wire format.
                        meter = struct.unpack(">H", body[5:7])[0]
                        samples.append(0.1 * meter - 127.0)

                    # Fewer than five usable frames means the dwell was mostly
                    # settling time or the stream stalled. Reporting a floor from
                    # one or two frames would be worse than reporting nothing,
                    # because nothing is visible as a gap and a bad point is not.
                    if len(samples) < 5:
                        continue

                    samples.sort()
                    labels = {"freq_khz": khz}
                    metrics.add(
                        "sdr_noise_floor_dbm",
                        "Noise floor, 10th percentile of the dwell, in the measurement passband",
                        "gauge", labels, round(samples[int(0.10 * len(samples))], 2),
                    )
                    metrics.add(
                        "sdr_noise_median_dbm",
                        "Median level over the dwell; above the floor when the channel is occupied",
                        "gauge", labels, round(statistics.median(samples), 2),
                    )
                    metrics.add(
                        "sdr_noise_peak_dbm",
                        "Strongest sample in the dwell",
                        "gauge", labels, round(samples[-1], 2),
                    )
                    metrics.add(
                        "sdr_noise_samples",
                        "S-meter frames the floor for this point was computed from",
                        "gauge", labels, len(samples),
                    )
                    swept += 1

            return swept


        def main():
            metrics = Metrics()
            started = time.monotonic()

            collect_status(metrics)
            collect_band_history(metrics)

            try:
                swept = asyncio.run(sweep(metrics))
            except (OSError, asyncio.TimeoutError, websockets.WebSocketException) as err:
                print(f"sdr-noise-textfile: sweep failed: {err}", file=sys.stderr)
                swept = 0

            metrics.add(
                "sdr_noise_bandwidth_hz",
                "Passband the per-frequency dBm figures are measured in; subtract 10*log10 of this for a density",
                "gauge", {}, BANDWIDTH,
            )
            metrics.add(
                "sdr_noise_points",
                "Frequency points the sweep produced a floor for",
                "gauge", {}, swept,
            )
            metrics.add(
                "sdr_noise_sweep_duration_seconds",
                "Wall time for the whole collection",
                "gauge", {}, round(time.monotonic() - started, 2),
            )
            # Separate from sdr_up on purpose, and for the same reason ont.nix keeps
            # pon_up apart from collector_success: the receiver can be answering HTTP
            # perfectly while every channel is taken, and that is a different fault
            # with a different remedy than the machine being unreachable.
            metrics.add(
                "sdr_noise_collector_success",
                "Whether the sweep produced any points on this run",
                "gauge", {}, 1 if swept else 0,
            )

            # Written through a temporary file in the same directory and renamed, for
            # the reason spelled out in qos-metrics.nix: node_exporter discards every
            # metric in the directory when any file in it fails to parse, so a
            # half-written file takes the unrelated collectors down with it.
            try:
                handle, tmp = tempfile.mkstemp(dir=os.path.dirname(OUT), suffix=".tmp")
                with os.fdopen(handle, "w") as fh:
                    fh.write(metrics.render())
                os.chmod(tmp, 0o644)
                os.replace(tmp, OUT)
            except OSError as err:
                print(f"sdr-noise-textfile: cannot write {OUT}: {err}", file=sys.stderr)
                return 1
            return 0


        sys.exit(main())
      '';
in
{
  options.sifr.personal.sdrNoise = {
    enable = lib.mkEnableOption ''
      sweeping the HF noise floor on the house SDR into Prometheus.

      Answers "is the band getting noisier, and where" with a frequency grid
      rather than the four fixed buckets the receiver keeps for itself. Enable
      on the host that can reach the receiver directly -- the collector talks to
      it over plain HTTP on the LAN, not through the public vhost
    '';

    address = lib.mkOption {
      type = lib.types.str;
      default = "10.20.0.164:8073";
      description = ''
        host:port of the receiver's own web service, on the LAN.

        Deliberately not sdr.huma.id. That name resolves to the VPS, which
        proxies over the nebula mesh back to this machine's nginx, which
        proxies here -- so using it would make an hourly local measurement
        depend on the uplink being up, and would drop the sweep exactly during
        the outages it is most interesting to have data across.
      '';
    };

    startKHz = lib.mkOption {
      type = lib.types.ints.positive;
      default = 500;
      description = ''
        First frequency of the sweep, in kHz. Below roughly 500 kHz the loop's
        response falls away and the reading describes the antenna rather than
        the band.
      '';
    };

    stopKHz = lib.mkOption {
      type = lib.types.ints.positive;
      default = 30000;
      description = "Last frequency of the sweep, in kHz. The receiver ends at 30 MHz.";
    };

    stepKHz = lib.mkOption {
      type = lib.types.ints.positive;
      default = 500;
      description = ''
        Grid spacing, in kHz.

        60 points at the default, which is one Prometheus series per point per
        metric -- small enough to ignore, and fine enough to place a noise
        source in a band. Halving this doubles both the series count and the
        sweep's wall time, and the wall time is what holds a receiver channel
        open, so it is the constraint that binds first.

        A fixed grid rather than a hand-picked list of quiet frequencies: a
        point that always lands on the same broadcast carrier reads high
        forever, but it reads high *consistently*, and consistency is what a
        trend needs. A curated list drifts as the broadcasters do.
      '';
    };

    bandwidth = lib.mkOption {
      type = lib.types.ints.positive;
      default = 1000;
      description = ''
        Measurement passband in Hz. Exported as sdr_noise_bandwidth_hz so a
        dashboard can convert the dBm figures to a density without the number
        being written down twice.
      '';
    };

    dwell = lib.mkOption {
      type = lib.types.str;
      default = "1.6";
      description = ''
        Seconds spent on each frequency, of which the first 0.45 is discarded
        as settling. The remainder yields roughly 28 S-meter frames, enough for
        a 10th percentile to mean something.
      '';
    };

    deadline = lib.mkOption {
      type = lib.types.ints.positive;
      default = 240;
      description = ''
        Seconds after which the sweep stops early and publishes what it has.

        The default grid needs about 105s, so this is not a budget but a
        backstop against a receiver that accepts the connection and then
        delivers frames slowly enough to run into the next timer tick.
      '';
    };

    metricsFile = lib.mkOption {
      type = lib.types.str;
      default = "${textfileDir}/sdr-noise.prom";
      description = "Where the collector publishes, inside the directory node_exporter scrapes.";
    };

    interval = lib.mkOption {
      type = lib.types.str;
      default = "1h";
      description = ''
        How often to sweep, as a systemd time span.

        Hourly because that is the rate the interesting things move at: the
        diurnal cycle, and a new noise source appearing and staying. It also
        matches the cadence of the receiver's own /snr history, so the two
        series line up. The cost is one of the receiver's twelve channels held
        for about two minutes in every sixty.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = config.sifr.personal.o11y.client.enable;
        message = ''
          sifr.personal.sdrNoise.enable needs sifr.personal.o11y.client.enable on
          the same host: the client is what creates the textfile directory this
          publishes into and what points node_exporter at it. Without it the
          sweep runs hourly and nothing ever reads the result.
        '';
      }
    ];

    systemd.services.sdr-noise-textfile = {
      description = "Sweep the HF noise floor on the SDR into a Prometheus textfile";

      serviceConfig = {
        Type = "oneshot";
        ExecStart = lib.getExe sdrNoiseTextfile;

        # Opens one TCP connection and writes one file.
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

        # Backstop above the script's own deadline, for the case where it wedges
        # somewhere the deadline is not checked -- inside connect(), mostly.
        TimeoutStartSec = "${toString (cfg.deadline + 120)}s";
      };
    };

    systemd.timers.sdr-noise-textfile = {
      description = "Sweep the SDR noise floor regularly";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "5min";
        OnUnitActiveSec = cfg.interval;
        AccuracySec = "30s";
        # A sweep missed across a reboot is worth taking late. The series is a
        # trend, and a gap in it is the one thing that cannot be recovered
        # afterwards.
        Persistent = true;
      };
    };
  };
}
