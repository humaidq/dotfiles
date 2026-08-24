{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.sifr.router;
  inherit (cfg) ont;
  full = cfg.fullReboot;

  # State that has to outlive the router restarting itself, which is the whole
  # difficulty of this sequence: the thing driving it is the thing being
  # rebooted. A marker file here is what turns "reboot the access points too"
  # from an instruction held in memory into one held on disk.
  stateDir = "/var/lib/router-fullreboot";
  marker = "${stateDir}/reboot-access-points";

  # What the sequence did, one tab-separated step per line:
  #
  #   run<TAB>when<TAB>phase<TAB>outcome<TAB>detail
  #
  # run is the epoch second the sequence began and is what groups the steps of
  # one run together across the reboot in the middle of it — which is why it is
  # carried in the marker file rather than held anywhere in memory.
  #
  # A flat text file rather than the uplink database: this is written by root
  # shell scripts on either side of a reboot, and read by a web process that
  # must not be able to write it. A file with a mode is the whole access
  # control, and there is nothing here worth a schema.
  history = "${stateDir}/history.tsv";

  # Present while the sequence is running. The uplink prober reads it and stops
  # recording events for the duration, because the session drop it is about to
  # see is one this router caused on purpose — see inMaintenance in web/uplink.go.
  # Bounded by its own mtime on the reading side, so a marker orphaned by a
  # crash cannot silence the event log indefinitely.
  maintenance = "${stateDir}/maintenance";

  # Written by router-web, watched by the path unit below. Inside router-web's
  # own state directory because that is the one place the DynamicUser service
  # can write, and it is persisted, so a request cannot be lost between the
  # click and the unit noticing.
  requestFile = "/var/lib/private/router-web/full-reboot.request";

  routerWeb = pkgs.callPackage ./web/package.nix { };

  rebootONT = pkgs.writeShellApplication {
    name = "router-fullreboot-ont";
    runtimeInputs = with pkgs; [
      openssh
      sshpass
      iputils
      systemd
      coreutils
    ];
    text = ''
      set -euo pipefail

      # World readable: router-web renders this timeline and runs as a
      # DynamicUser, so it can read the directory but must never be able to
      # write it. 0644 files under a 0755 directory is that boundary.
      umask 022
      install -d -m 0755 ${stateDir}

      run="$(date +%s)"
      note() {
        printf '%s\t%s\t%s\t%s\t%s\n' \
          "$run" "$(date +%s)" "$1" "$2" "$3" >> ${history}
      }

      note requested ok "requested from the status page"

      # Before the first thing that breaks the line, not after. The fibre
      # terminal goes down seconds from here and the prober is still running
      # and watching; without this it records a session drop for every press of
      # the button, and "drops in the last 24 hours" stops meaning anything.
      : > ${maintenance}

      # Same login and the same legacy-algorithm dance as the optical
      # collector; see modules/router/ont.nix for why both are needed.
      user="$(cat ${ont.usernameFile})"
      # Quoted because the Kex list contains commas, which shellcheck would
      # otherwise read as array separators (SC2054).
      ssh_opts=(
        "-oHostKeyAlgorithms=+ssh-rsa"
        "-oKexAlgorithms=+diffie-hellman-group14-sha1,diffie-hellman-group1-sha1"
        "-oStrictHostKeyChecking=no"
        "-oUserKnownHostsFile=/dev/null"
        "-oGlobalKnownHostsFile=/dev/null"
        "-oLogLevel=ERROR"
        "-oConnectTimeout=10"
      )

      echo "full-reboot: rebooting the fibre terminal at ${ont.address}"
      # The ONT drops the connection as it goes down, so ssh returning
      # non-zero here is the expected case rather than a failure.
      sshpass -f ${ont.passwordFile} ssh "''${ssh_opts[@]}" \
        "$user@${ont.address}" reboot || true

      # Give it a moment to actually go down before waiting for it to come
      # back, or the first probe answers from the box that has not restarted
      # yet and the wait ends immediately.
      sleep 20

      echo "full-reboot: waiting up to ${toString full.ontTimeout}s for the fibre terminal"
      started=$SECONDS
      deadline=$(( SECONDS + ${toString full.ontTimeout} ))
      until ping -c 1 -W 2 ${ont.address} >/dev/null 2>&1; do
        if [ "$SECONDS" -ge "$deadline" ]; then
          echo "full-reboot: the fibre terminal did not come back; stopping here" >&2
          echo "full-reboot: this router has been left running deliberately" >&2
          note fibre failed "did not come back within ${toString full.ontTimeout}s; sequence stopped"
          # The sequence stops here, so the quiet window has to stop with it:
          # from this moment any further loss is the line's own and worth
          # recording.
          rm -f ${maintenance}
          exit 1
        fi
        sleep 5
      done
      note fibre ok "back after $(( SECONDS - started ))s"

      echo "full-reboot: fibre terminal is back, arming the access point phase"
      # The run id rides across the reboot in the marker, so the steps recorded
      # on the far side join the ones recorded here instead of looking like a
      # second run that started by itself.
      printf '%s\n' "$run" > ${marker}
      note router started "rebooting this router"
      sync

      echo "full-reboot: rebooting this router"
      systemctl reboot
    '';
  };

  rebootAPs = pkgs.writeShellApplication {
    name = "router-fullreboot-aps";
    runtimeInputs = with pkgs; [
      coreutils
      iproute2
    ];
    text = ''
      set -euo pipefail

      [ -e ${marker} ] || exit 0

      umask 022
      run="$(cat ${marker})"
      note() {
        printf '%s\t%s\t%s\t%s\t%s\n' \
          "$run" "$(date +%s)" "$1" "$2" "$3" >> ${history}
      }

      # Clear the marker first. A crash in the phase below must not leave the
      # estate rebooting its access points on every subsequent boot, which is
      # a far worse failure than one missed round.
      rm -f ${marker}

      note router ok "router back up"

      echo "full-reboot: waiting for the uplink to settle"
      deadline=$(( SECONDS + ${toString full.settleTimeout} ))
      until ip -br addr show ${cfg.ppp} 2>/dev/null | grep -q '[0-9]'; do
        if [ "$SECONDS" -ge "$deadline" ]; then
          echo "full-reboot: no uplink yet; rebooting the access points anyway" >&2
          break
        fi
        sleep 5
      done

      # The access points answer the LAN, not the WAN, so this is not waiting
      # on the uplink so much as on this router having finished bringing
      # everything up around it. They also need to have finished booting
      # themselves after the power-cycle they did not get — they stayed up
      # throughout, so this is only about the router's own readiness.
      sleep ${toString full.settleDelay}

      echo "full-reboot: rebooting access points"
      if rebooted="$(${routerWeb}/bin/router-web --reboot-aps 2>&1 | tail -1)"; then
        note access-points ok "$rebooted"
      else
        note access-points failed "$rebooted"
      fi

      # The estate is back; events mean something again.
      rm -f ${maintenance}

      # Keep the timeline from growing without bound. Five steps per run, so
      # this is roughly the last eighty runs, which on a control used a handful
      # of times a year is more history than anyone will scroll.
      if [ "$(wc -l < ${history})" -gt 400 ]; then
        tail -n 400 ${history} > ${history}.tmp && mv ${history}.tmp ${history}
      fi
    '';
  };
in
{
  options.sifr.router.fullReboot = {
    enable = lib.mkEnableOption ''
      the whole-estate reboot control on the status page.

      Restarts the fibre terminal, then this router, then every access point
      with credentials, in that order and each waiting on the one before it.
      Requires sifr.router.ont, whose credentials it reuses
    '';

    ontTimeout = lib.mkOption {
      type = lib.types.ints.positive;
      default = 300;
      description = ''
        Seconds to wait for the fibre terminal to answer again before giving
        up. On expiry the sequence stops and this router is deliberately left
        running: a router rebooted on top of a dead ONT removes the LAN, the
        mesh and the status page, which are the three things needed to work
        out what went wrong.
      '';
    };

    settleTimeout = lib.mkOption {
      type = lib.types.ints.positive;
      default = 180;
      description = ''
        Seconds to wait after boot for the PPP session before rebooting the
        access points. On expiry they are rebooted anyway — they serve the LAN
        and do not need the WAN to be useful, so a slow uplink should not cost
        the last phase of the sequence.
      '';
    };

    settleDelay = lib.mkOption {
      type = lib.types.ints.positive;
      default = 60;
      description = ''
        Extra seconds after the uplink is up before the access points are
        rebooted, so they are not restarted into a router that is still
        finishing its own startup.
      '';
    };
  };

  config = lib.mkIf (cfg.enable && full.enable) {
    assertions = [
      {
        assertion = full.enable -> ont.enable;
        message = ''
          sifr.router.fullReboot.enable needs sifr.router.ont.enable: the
          sequence starts by rebooting the fibre terminal, and the credentials
          for it come from the ONT module.
        '';
      }
    ];

    environment.systemPackages = [ rebootONT ];

    # The privilege boundary. router-web runs under DynamicUser and holds no
    # credential for the ONT — deliberately, see web/ont.go — so it cannot do
    # any of this itself. It writes a file; this notices and runs the sequence
    # as root. Nothing about the web process's own privileges changes.
    systemd.paths.router-fullreboot = {
      description = "Watch for a full-reboot request from the status page";
      wantedBy = [ "multi-user.target" ];
      pathConfig = {
        PathExists = requestFile;
        Unit = "router-fullreboot.service";
      };
    };

    systemd.services.router-fullreboot = {
      description = "Reboot the fibre terminal, then this router";
      serviceConfig = {
        Type = "oneshot";
        # Removed before the work starts rather than after: the sequence ends
        # in `systemctl reboot`, so there is no "after" in which to clean up,
        # and a request file surviving the reboot would start the whole thing
        # again on the next boot.
        ExecStartPre = "${pkgs.coreutils}/bin/rm -f ${requestFile}";
        ExecStart = lib.getExe rebootONT;
        # Root, and unsandboxed on purpose: it reads the sops secrets, reaches
        # the ONT on the WAN link, writes the marker, and reboots the machine.
        StateDirectory = "router-fullreboot";
      };
    };

    systemd.services.router-fullreboot-aps = {
      description = "Reboot the access points after a full reboot";
      wantedBy = [ "multi-user.target" ];
      after = [
        "network-online.target"
        "router-web.service"
      ];
      wants = [ "network-online.target" ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = lib.getExe rebootAPs;
        # The AP list is the same secret router-web reads, and may be group
        # readable rather than world readable.
        SupplementaryGroups = lib.optional (cfg.accessPoints.file != null) "router-ap";
      };
      environment = lib.optionalAttrs (cfg.accessPoints.file != null) {
        ROUTER_AP_FILE = cfg.accessPoints.file;
      };
    };
  };
}
