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

ensure_sdk
echo "SDK ready at $sdk" >&2
