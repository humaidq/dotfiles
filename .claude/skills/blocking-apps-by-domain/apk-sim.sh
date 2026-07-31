#!/usr/bin/env bash
# Run an Android package under an emulator and print the hosts it contacts.
#
#   apk-sim.sh <android.package.name>
#   apk-sim.sh -l <file.apk>            # already have the file
#   apk-sim.sh -t 240 -d 10.10.0.16 <pkg>
#
# Needs adb, tshark and a JDK:
#   nix shell nixpkgs#android-tools nixpkgs#wireshark-cli nixpkgs#jdk17_headless
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

# Guarantee the emulator never outlives the script. Under set -e, a wait_boot
# timeout or a failed snapshot save aborts the script before the explicit
# stop_emulator call in ensure_avd runs, which would otherwise orphan
# qemu-system holding port 5556 and break the next run. stop_emulator is a
# no-op once emu_pid is already cleared, so running it again here on the
# ordinary success path is harmless.
cleanup() {
	local status=$?
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
	adb -s "$serial" root
	adb -s "$serial" wait-for-device
	adb -s "$serial" shell "tcpdump -i any -s 0 -w /data/local/tmp/cap.pcap" &
	tcpdump_pid=$!
	sleep 60
	adb -s "$serial" shell pkill -INT tcpdump || true
	sleep 2
	kill "$tcpdump_pid" 2>/dev/null || true
	adb -s "$serial" pull /data/local/tmp/cap.pcap "$cache/spike.pcap"
	stop_emulator
	echo "wrote $cache/spike.pcap ($(stat -c %s "$cache/spike.pcap" 2>/dev/null || echo 0) bytes)" >&2
	exit 0
fi
