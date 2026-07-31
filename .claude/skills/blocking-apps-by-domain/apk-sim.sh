#!/usr/bin/env bash
# Run an Android package under an emulator and print the hosts it contacts.
#
#   apk-sim.sh <android.package.name>
#   apk-sim.sh -l <file.apk>            # already have the file
#   apk-sim.sh -t 240 -d 10.10.0.16 <pkg>
#
# Needs adb, tshark, a JDK, curl and file:
#   nix shell nixpkgs#android-tools nixpkgs#wireshark-cli nixpkgs#jdk17_headless \
#     nixpkgs#curl nixpkgs#file
#
# Where apk-domains.sh answers "what hostnames are in the package", this
# answers "what did the app actually dial" — which survives obfuscation,
# packing and runtime-assembled URLs. It stops at the login wall by design.
#
# One host per line on stdout, ready for check-domains.sh. The annotated
# table showing how each host was seen goes to stderr.
set -euo pipefail

cache="${XDG_CACHE_HOME:-$HOME/.cache}/apk-sim"
sdk="$cache/sdk/libexec/android-sdk"

# The emulator is a disposable investigation tool, so it is deliberately kept
# out of the flake. Building it from an expression in the cache still pins it
# to the flake registry's nixpkgs, without putting a multi-GB system image
# anywhere `nix flake check` will look at it.
ensure_sdk() {
	[ -x "$sdk/emulator/emulator" ] && return 0
	mkdir -p "$cache"
	cat >"$cache/sdk.nix" <<-'NIX'
		(import (builtins.getFlake "nixpkgs").outPath {
		  config.allowUnfree = true;
		  config.android_sdk.accept_license = true;
		}).androidenv.composeAndroidPackages {
		  platformVersions = [ "34" ];
		  abiVersions = [ "x86_64" ];
		  systemImageTypes = [ "google_apis" ];
		  includeSystemImages = true;
		  includeEmulator = true;
		}
	NIX
	echo "building the Android SDK — first run only, several GB ..." >&2
	nix build --impure -f "$cache/sdk.nix" androidsdk -o "$cache/sdk"
}

avd_home="$cache/avd"
avd_name="apk-sim"
image="system-images;android-34;google_apis;x86_64"
serial="emulator-5556"
emu_pid=""
capture_pid=""
cap_dest=""

export ANDROID_SDK_ROOT="$sdk" ANDROID_HOME="$sdk" ANDROID_AVD_HOME="$avd_home"

wait_boot() {
	adb -s "$serial" wait-for-device
	for _ in $(seq 1 180); do
		if [ "$(adb -s "$serial" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = "1" ]; then
			return 0
		fi
		sleep 1
	done
	echo "ERROR: emulator did not finish booting within 180s" >&2
	return 1
}

# Always -s emulator-5556: a phone plugged into this workstation would
# otherwise be a valid adb target, and this script installs and drives apps.
boot_emulator() {
	"$sdk/emulator/emulator" -avd "$avd_name" -port 5556 \
		-no-window -no-audio -no-boot-anim -gpu swiftshader_indirect \
		"$@" >"$cache/emulator.log" 2>&1 &
	emu_pid=$!
	wait_boot
}

stop_emulator() {
	[ -n "$emu_pid" ] || return 0
	adb -s "$serial" emu kill >/dev/null 2>&1 || true
	local waited=0
	while kill -0 "$emu_pid" 2>/dev/null; do
		if [ "$waited" -ge 10 ]; then
			kill -9 "$emu_pid" 2>/dev/null || true
			break
		fi
		sleep 1
		waited=$((waited + 1))
	done
	wait "$emu_pid" 2>/dev/null || true
	emu_pid=""
}

# Guest-side capture. Host-side `-tcpdump` cannot see this AVD's outbound
# traffic (see the note above capture_flags), so capture instead runs inside
# the guest and is pulled off before anything stops the emulator. Task 5
# calls these two functions rather than re-deriving the adb sequence.
#
#   start_capture                    # begin capturing, after boot_emulator
#   finish_capture <destination-path> # stop, and pull the pcap to this path
#
# start_capture leaves the local `adb shell tcpdump ...` client's pid in
# capture_pid so cleanup can reap it if the script aborts mid-capture.
start_capture() {
	if ! adb -s "$serial" root >/dev/null; then
		echo "ERROR: adb root failed — guest tcpdump needs root (Play Store images can't grant this)" >&2
		return 1
	fi
	adb -s "$serial" wait-for-device
	adb -s "$serial" shell "rm -f /data/local/tmp/cap.pcap"
	adb -s "$serial" shell "tcpdump -i any -s 0 -w /data/local/tmp/cap.pcap" &
	capture_pid=$!
}

# Signals tcpdump to stop and flush, waits (bounded) for it to actually exit
# on the device so the pcap trailer isn't truncated, then pulls the file.
#
# If tcpdump doesn't exit gracefully within the bound, it is force-killed so
# this can't hang forever — but a forced kill can truncate the pcap trailer,
# and a truncated capture silently yields a *short* domain list that looks
# just like "this app doesn't contact much" instead of "the capture was cut
# short". That distinction matters too much to lose quietly, so the pull
# still happens (a truncated capture beats none), but the timeout branch is
# loud about it on stderr instead of pretending the capture is trustworthy.
finish_capture() {
	local dest="$1" waited=0 graceful=1
	adb -s "$serial" shell pkill -INT tcpdump >/dev/null 2>&1 || true
	while adb -s "$serial" shell 'pgrep tcpdump >/dev/null 2>&1'; do
		if [ "$waited" -ge 10 ]; then
			graceful=0
			adb -s "$serial" shell pkill -KILL tcpdump >/dev/null 2>&1 || true
			break
		fi
		sleep 1
		waited=$((waited + 1))
	done
	adb -s "$serial" pull /data/local/tmp/cap.pcap "$dest"
	if [ "$graceful" -eq 0 ]; then
		echo "WARNING: tcpdump did not exit within ${waited}s of SIGINT and was force-killed (SIGKILL)." >&2
		echo "WARNING: $dest may have a truncated pcap trailer as a result — this is NOT a clean capture." >&2
		echo "WARNING: any host list derived from $dest may be INCOMPLETE. A short list here can mean" >&2
		echo "WARNING: 'the capture got cut off', not 'this app contacts few domains' — do not trust it" >&2
		echo "WARNING: as a block/allow signal without re-running the capture." >&2
	fi
	if [ ! -s "$dest" ]; then
		echo "ERROR: $dest is missing or empty after pull — the capture did not just truncate, it failed entirely." >&2
	fi
	if [ -n "$capture_pid" ]; then
		kill "$capture_pid" 2>/dev/null || true
		wait "$capture_pid" 2>/dev/null || true
		capture_pid=""
	fi
}

# Wraps `install-multiple` so an ABI mismatch is classified instead of
# surfacing as a bare adb failure. Reads $install_apks (built by the caller's
# ABI-filter, below) and $pkg.
#
# Capture is already running by the time this is called (start_capture runs
# right after boot, before install, so nothing at first launch is missed).
# On failure this deliberately does NOT call stop_emulator itself — cap_dest
# is still set, so the plain `exit 1` at the call site routes through the
# EXIT trap's cleanup, which salvages the in-flight capture before it tears
# the emulator down. Calling stop_emulator here first would kill the guest
# out from under that salvage. org.wikipedia (an armeabi-v7a-only native
# split against this AVD's x86_64/arm64-v8a image) is the reproducer for
# INSTALL_FAILED_MISSING_SPLIT; NO_MATCHING_ABIS is handled as its own arm
# rather than folded into the same message, because it is a different
# string from a different adb/image combination — same practical meaning
# for the app (it cannot run here), but not the same failure, so the
# write-up should say which one actually happened.
install_apk() {
	local out
	if out="$(adb -s "$serial" install-multiple -r -g "${install_apks[@]}" 2>&1)"; then
		echo "$out" >&2
		return 0
	fi
	echo "$out" >&2
	case "$out" in
	*INSTALL_FAILED_MISSING_SPLIT*)
		echo "ERROR: $pkg's split APK set is missing a library this image needs" >&2
		echo "       (INSTALL_FAILED_MISSING_SPLIT). The mirror likely served an" >&2
		echo "       armeabi-v7a-only native split, and this image is x86_64/arm64-v8a." >&2
		echo "       This is an ABI mismatch, not a finding about $pkg — say so." >&2
		;;
	*NO_MATCHING_ABIS*)
		echo "ERROR: $pkg ships no native library for any ABI this image supports" >&2
		echo "       (NO_MATCHING_ABIS). This is an ABI mismatch, not a finding" >&2
		echo "       about $pkg — say so." >&2
		;;
	*) echo "ERROR: installing $pkg failed." >&2 ;;
	esac
	return 1
}

# An app that vanishes seconds after launch has almost certainly detected the
# emulator — its domain list is incomplete and must be presented as such, not
# as a clean result. But the emulator itself can die independently (confirmed
# via coredumpctl: monkey-fuzzing com.duckduckgo.mobile.android SIGSEGVs qemu
# at roughly 48s), and once it has, every adb call below fails too — a naive
# "is $pkg's process gone" check cannot tell "the app detected the emulator"
# apart from "the emulator crashed and adb is now just failing on everything,
# including its own pidof". Blaming the app for a host-side crash sends
# whoever reads the write-up hunting for anti-emulator code that isn't there.
#
# Two earlier versions of this function tried to rule out an emulator crash
# *before* trusting pidof, first with a single liveness check, then with a
# second one in front of pidof too. Both still misclassified: there is
# always another gap between "checked" and "the call that matters", so
# checking beforehand can never close it — it only moves it. The fix is to
# stop trying to prove the emulator was healthy in advance and instead
# confirm, only once pidof's answer is already ambiguous, whether it still
# is. Nothing can happen "after" that confirmation that changes what the
# ambiguous answer meant, so there is no gap left to race.
#
# So: run pidof first. A non-empty answer is unambiguous — the app is
# alive, full stop, no emulator check needed. Only an empty-or-failed
# answer needs disambiguating, and it's disambiguated after the fact:
#   - qemu itself gone (`pgrep qemu`, comm-only, no `-f` — `pgrep -f
#     qemu-system` matches its own command line, which mentions
#     "qemu-system", and falsely reports a live process) -> the emulator
#     crashed, full stop; it does not matter whether that happened before,
#     during or after the pidof call, the run is void either way.
#   - qemu present but `adb get-state` won't say "device" -> adb itself is
#     wedged talking to a still-running qemu; genuinely indeterminate,
#     not app death and not a crash, so neither is claimed.
#   - qemu present and adb answers "device" -> pidof's emptiness is now
#     positive evidence about $pkg specifically, not an artifact of a
#     dead or wedged transport. Only now is "probable emulator detection"
#     said.
# get-state is deliberately not used as an up-front gate: it can report
# something other than "device" transiently during normal operation, and
# gating on it there would void perfectly good runs. It only earns its
# keep here, disambiguating a result that is already suspicious.
#
# Every adb call is `timeout`-bounded, the same convention cleanup()
# already uses for its own salvage attempts, so a wedged transport can
# make this function report INDETERMINATE but never makes it hang.
#
# Returns 0 if $pkg's process is found (unambiguous — emulator must be
# answering for pidof to have found anything at all). Returns 1 if pidof
# came back empty and the emulator is confirmed alive and answering
# (probable emulator detection — caller still prints hosts). Returns 2 if
# the emulator is gone (the run is void, not a finding about $pkg — caller
# must not print hosts). Returns 3 if adb cannot get a straight answer out
# of a qemu that is still there (indeterminate — also void, also no
# hosts).
check_alive() {
	if [ -n "$(timeout 5 adb -s "$serial" shell pidof "$pkg" 2>/dev/null | tr -d '\r')" ]; then
		return 0
	fi

	# pidof came back empty or the call itself failed. That alone proves
	# nothing about $pkg — it's exactly what a dead or wedged emulator
	# would also produce — so find out which situation this actually is
	# before saying anything about the app.
	if ! pgrep --quiet qemu; then
		echo >&2
		echo "ERROR: the emulator process is gone (crashed, or was killed outside" >&2
		echo "       this script). This run is void — it is a host-side failure," >&2
		echo "       not a finding about $pkg. Retry the capture; do not trust" >&2
		echo "       anything captured so far as a description of $pkg's behavior." >&2
		echo >&2
		return 2
	fi

	local state
	state="$(timeout 5 adb -s "$serial" get-state 2>/dev/null | tr -d '\r')"
	if [ "$state" != "device" ]; then
		echo >&2
		echo "ERROR: adb cannot get a straight answer from the emulator" >&2
		echo "       (get-state reported '${state:-nothing}'), but the qemu process" >&2
		echo "       is still running. This is INDETERMINATE — neither a confirmed" >&2
		echo "       app death nor a confirmed emulator crash. Do not report" >&2
		echo "       anything below as a finding about $pkg; retry the capture." >&2
		echo >&2
		return 3
	fi

	echo >&2
	echo "WARNING: $pkg is no longer running." >&2
	timeout 5 adb -s "$serial" logcat -d -t 200 2>/dev/null |
		grep -iE "FATAL EXCEPTION|emulator|rooted|$pkg.*died" | tail -5 >&2 || true
	echo "         Probable emulator detection. Treat the hosts below as" >&2
	echo "         incomplete and unreliable, and say so in the write-up." >&2
	echo >&2
	return 1
}

# Guarantee the emulator never outlives the script. Under set -e, a wait_boot
# timeout or a failed snapshot save aborts the script before the explicit
# stop_emulator call in ensure_avd runs, which would otherwise orphan
# qemu-system holding port 5556 and break the next run. stop_emulator is a
# no-op once emu_pid is already cleared, so running it again here on the
# ordinary success path is harmless.
#
# cap_dest names where the in-flight capture belongs. Callers set it right
# after start_capture succeeds and clear it right after their own explicit
# finish_capture call returns, so it is non-empty for exactly the window
# where a capture is running but not yet finished. Anything that aborts in
# that window — install-multiple rejecting a bad split set, `am start`
# failing, an adb hiccup, all real, one of which (org.wikipedia's
# INSTALL_FAILED_MISSING_SPLIT) actually happened during Task 5 testing —
# used to tear the emulator down with the guest's only copy of the capture
# still on it. cleanup now salvages it first. This gap predates Task 5
# (cleanup itself is from Task 2); it only became consequential once install
# and launch — real failure-prone steps — started running inside the window.
#
# The salvage is bounded at every single adb call, not just the loop as a
# whole: cleanup may be racing a wedged emulator or a transport that is
# already gone, and it must fail loudly and quickly rather than hang the
# abort path. A failed salvage does not fail cleanup — stop_emulator still
# has to run, and the script still has to exit with whatever status caused
# the abort, not whatever the salvage attempt returned.
cleanup() {
	local status=$?
	if [ -n "$cap_dest" ]; then
		echo "WARNING: aborting with a capture still running — attempting to salvage it to $cap_dest ..." >&2
		timeout 5 adb -s "$serial" shell pkill -INT tcpdump >/dev/null 2>&1 || true
		local waited=0
		while timeout 3 adb -s "$serial" shell 'pgrep tcpdump >/dev/null 2>&1' 2>/dev/null; do
			[ "$waited" -ge 5 ] && break
			sleep 1
			waited=$((waited + 1))
		done
		if timeout 20 adb -s "$serial" pull /data/local/tmp/cap.pcap "$cap_dest" >&2 2>&1 && [ -s "$cap_dest" ]; then
			echo "Salvaged a partial capture to $cap_dest." >&2
		else
			echo "ERROR: could not salvage a capture to $cap_dest — the pull failed or produced nothing." >&2
		fi
		cap_dest=""
	fi
	if [ -n "$capture_pid" ]; then
		kill "$capture_pid" 2>/dev/null || true
		capture_pid=""
	fi
	stop_emulator
	exit "$status"
}
trap cleanup EXIT

# One cold boot, once. Every later run restores this snapshot instead, which
# takes seconds and guarantees no residue from the previously tested app.
ensure_avd() {
	local avdmanager
	[ -d "$avd_home/$avd_name.avd/snapshots/default_boot" ] && return 0
	mkdir -p "$avd_home"
	if [ ! -d "$avd_home/$avd_name.avd" ]; then
		avdmanager="$(find "$sdk/cmdline-tools" -name avdmanager -type f | head -1)"
		echo no | "$avdmanager" create avd -n "$avd_name" -k "$image" -d pixel_6 --force
		cat >>"$avd_home/$avd_name.avd/config.ini" <<-EOF
			hw.gpu.mode=swiftshader_indirect
			hw.ramSize=3072
			hw.keyboard=yes
			disk.dataPartition.size=6G
		EOF
	fi
	echo "cold boot to write the golden snapshot — this takes a few minutes ..." >&2
	boot_emulator -no-snapshot-load
	sleep 20 # let first-boot background work settle before snapshotting
	adb -s "$serial" shell input keyevent 82 || true
	adb -s "$serial" emu avd snapshot save default_boot
	stop_emulator
}

capture_flags=(-snapshot default_boot -no-snapshot-save -read-only)

ensure_sdk
ensure_avd

# Spike: boot with capture on and let the platform generate its own traffic.
# A google_apis image performs captive-portal checks and Play Services sync on
# boot, so no app is needed to prove the capture path works.
#
# Host-side `-tcpdump` was proven NOT to work here and is deliberately not
# used: this AVD build routes Wi-Fi traffic through a "netsim" localhost RPC
# channel ("Successfully initialized netsim WiFi" in emulator.log) instead of
# the classic slirp/eth0 path that -tcpdump taps, so a passive 60s capture
# only ever picks up mDNS noise. Adding `-feature -Wifi` does not fix it
# either — on a `-snapshot default_boot` restore, wlan0 was already attached
# when the golden snapshot was saved, so the override can't remove it from
# the restored hardware. What does work is capturing inside the guest with
# `tcpdump -i any`, which sees every interface's traffic regardless of how
# the emulator backend ships it to the host.
if [ "${1:-}" = "--spike" ]; then
	rm -f "$cache/spike.pcap"
	boot_emulator "${capture_flags[@]}"
	start_capture
	cap_dest="$cache/spike.pcap"
	sleep 60
	finish_capture "$cache/spike.pcap"
	cap_dest=""
	stop_emulator
	echo "wrote $cache/spike.pcap ($(stat -c %s "$cache/spike.pcap" 2>/dev/null || echo 0) bytes)" >&2
	exit 0
fi

window=120
resolver="10.20.0.1"
local_file=""
while [ $# -gt 0 ]; do
	case "$1" in
	-l)
		local_file="${2:?usage: apk-sim.sh -l <file.apk>}"
		shift 2
		;;
	-t)
		window="${2:?usage: apk-sim.sh -t <seconds>}"
		shift 2
		;;
	-d)
		resolver="${2:?usage: apk-sim.sh -d <resolver>}"
		shift 2
		;;
	*) break ;;
	esac
done
if [ -n "$local_file" ]; then
	pkg="$(basename "$local_file" .apk)"
else
	pkg="${1:?usage: apk-sim.sh <android.package.name>}"
fi

# Same cache and same mirror as apk-domains.sh, so running both tools on one
# package costs one download.
work="${TMPDIR:-/tmp}/apk-domains/$pkg"
mkdir -p "$work"
apk="$work/app.apk"
if [ -n "$local_file" ]; then
	cp -f "$local_file" "$apk"
elif [ ! -s "$apk" ]; then
	echo "fetching $pkg ..." >&2
	curl -sSL --max-time 300 \
		-A "Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36" \
		-o "$apk" "https://d.apkpure.com/b/APK/$pkg?version=latest"
fi
case "$(file -b "$apk")" in
*"Android package"* | *"Zip archive"*) ;;
*)
	echo "$pkg: not an APK (the mirror may have returned an error page)" >&2
	exit 1
	;;
esac

# apkpure frequently serves an XAPK bundle instead of a plain APK: a zip
# containing a base .apk, one or more per-ABI native-library splits, and
# density/locale splits, plus a manifest.json adb knows nothing about. A
# plain APK has AndroidManifest.xml at its own root; a bundle's payload is
# nested *.apk files instead. install_apks is fed to `install-multiple`
# below either way, so a plain APK (a one-element array) takes the same path.
#
# The listing is collected into a variable before grep runs over it, rather
# than piped straight in: `grep -q` exits after its first match and closes
# the pipe, so `unzip -l` would receive SIGPIPE and exit non-zero — which
# `pipefail` turns into "not found" for every plain APK, not just bundles.
install_apks=("$apk")
listing="$(unzip -l "$apk" 2>/dev/null || true)"
if ! grep -q ' AndroidManifest\.xml$' <<<"$listing"; then
	bundle="$work/bundle"
	rm -rf "$bundle"
	mkdir -p "$bundle"
	unzip -qq -o "$apk" -d "$bundle" '*.apk' >/dev/null
	install_apks=()
	while IFS= read -r -d '' f; do
		install_apks+=("$f")
	done < <(find "$bundle" -maxdepth 1 -name '*.apk' -print0)
	if [ "${#install_apks[@]}" -eq 0 ]; then
		echo "$pkg: bundle contained no inner .apk files" >&2
		exit 1
	fi
fi

cap="$work/capture.pcap"
rm -f "$cap"

# The router, not a clean upstream: blocked names answer 0.0.0.0, so the app's
# failover fires and reveals the rotation service it would otherwise hide.
echo "booting emulator (resolver $resolver) ..." >&2
boot_emulator "${capture_flags[@]}" -dns-server "$resolver"

# Guest-side capture starts right after boot, before install, so nothing the
# app does at first launch — including its very first DNS lookups — is
# missed. SECONDS is reset here so the window below is measured from the
# start of capture, not from the end of the monkey run.
start_capture
cap_dest="$cap"
SECONDS=0

echo "installing $pkg ..." >&2
# This AVD's x86_64 google_apis image has no ARM native-bridge, so an ABI
# split it cannot execute (e.g. config.armeabi_v7a.apk) must be dropped
# rather than handed to install-multiple, which would otherwise reject the
# whole set as mismatched. Density/locale splits carry no ABI in the name
# and pass through untouched.
if [ "${#install_apks[@]}" -gt 1 ]; then
	abilist="$(adb -s "$serial" shell getprop ro.product.cpu.abilist | tr -d '\r')"
	filtered=()
	for f in "${install_apks[@]}"; do
		case "$(basename "$f")" in
		config.arm64_v8a.apk | config.armeabi_v7a.apk | config.armeabi.apk | config.mips*.apk | config.x86.apk | config.x86_64.apk)
			abi="$(basename "$f" .apk | sed 's/^config\.//')"
			grep -qF "$abi" <<<"$abilist" || continue
			;;
		esac
		filtered+=("$f")
	done
	install_apks=("${filtered[@]}")
fi
# -g grants runtime permissions up front so no dialog blocks the launch.
# install_apk keeps adb's own output (including its "Success" line, which
# lands on stdout) off of this script's stdout, and classifies ABI failures
# instead of letting them surface as a bare adb error.
if ! install_apk; then
	exit 1
fi

activity="$(adb -s "$serial" shell cmd package resolve-activity --brief "$pkg" |
	tr -d '\r' | tail -1)"
echo "launching $activity ..." >&2
# >&2: same reason — `am start` echoes "Starting: Intent { ... }" to stdout.
adb -s "$serial" shell am start -n "$activity" >&2

# Seeded, so two runs of the same app take the same path through the UI.
# --pct-syskeys 0 stops it pressing Home and wandering out of the app.
adb -s "$serial" shell monkey -p "$pkg" --pct-syskeys 0 --throttle 200 \
	--ignore-crashes --ignore-timeouts -s 42 300 >/dev/null 2>&1 || true

# check_alive's warning (return 1) qualifies the result but must not
# suppress it — whatever hosts got captured before $pkg died are still
# printed below, with the caveat already on stderr. Its emulator-crash
# (return 2) and indeterminate (return 3) cases are different in kind: the
# run is void either way, so this exits before any hosts are printed at
# all. exit here (not stop_emulator+exit) so the EXIT trap's cleanup
# salvages the in-flight capture first.
alive_rc=0
check_alive || alive_rc=$?
case "$alive_rc" in
2 | 3) exit 1 ;;
esac

# Total capture time is $window measured from start_capture, not $window
# tacked on after the monkey run — sleep only whatever is left of it.
remaining=$((window - SECONDS))
if [ "$remaining" -gt 0 ]; then
	echo "capturing for the remaining ${remaining}s of the ${window}s window ..." >&2
	sleep "$remaining"
else
	echo "monkey run alone used the full ${window}s window" >&2
fi

finish_capture "$cap"
cap_dest=""
stop_emulator

"$(dirname "$0")/pcap-domains.sh" "$cap"
