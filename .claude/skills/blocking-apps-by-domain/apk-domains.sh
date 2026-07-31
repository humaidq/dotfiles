#!/usr/bin/env bash
# Download an Android package and print the host-like strings it contains.
#
#   apk-domains.sh <android.package.name> [workdir]
#   apk-domains.sh -l <file.apk>            # already have the file
#
# Needs curl, unzip and strings:
#   nix shell nixpkgs#curl nixpkgs#unzip nixpkgs#binutils
#
# Output is one host per line, with Java package names and known third-party SDK
# infrastructure filtered out. It is a candidate list, not a blocklist: always
# run check-domains.sh over it before adding anything.
set -euo pipefail

local_file=""
if [ "${1:-}" = "-l" ]; then
	local_file="${2:?usage: apk-domains.sh -l <file.apk>}"
	pkg="$(basename "$local_file" .apk)"
	shift 2
else
	pkg="${1:?usage: apk-domains.sh <android.package.name> [workdir]}"
	shift
fi
work="${1:-${TMPDIR:-/tmp}/apk-domains}/$pkg"
mkdir -p "$work"

apk="$work/app.apk"
if [ -n "$local_file" ]; then
	cp -f "$local_file" "$apk"
elif [ ! -s "$apk" ]; then
	echo "fetching $pkg ..." >&2
	# See apk-sim.sh: /b/APK/ can silently omit a split the manifest marks
	# as required. /b/XAPK/ always returns the full set when one is
	# needed, and a byte-identical plain APK when it isn't.
	curl -sSL --max-time 300 \
		-A "Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36" \
		-o "$apk" "https://d.apkpure.com/b/XAPK/$pkg?version=latest"
fi

case "$(file -b "$apk")" in
*"Android package"* | *"Zip archive"*) ;;
*)
	echo "$pkg: not an APK/XAPK (site may have returned an error page)" >&2
	exit 1
	;;
esac

# XAPK bundles wrap the real APK plus per-ABI splits, so unpack one level down.
tree="$work/x"
rm -rf "$tree"
mkdir -p "$tree"
unzip -qq -o "$apk" -d "$tree" 2>/dev/null || true
find "$tree" -maxdepth 1 -name '*.apk' -print0 |
	while IFS= read -r -d '' inner; do
		unzip -qq -o "$inner" -d "$tree/inner-$(basename "$inner" .apk)" 2>/dev/null || true
	done

# Verify the mirror served the app we asked for. Some of them hand back their
# own store client instead, and its string table looks perfectly plausible —
# an unchecked run once produced 800 ad-tech domains from a consent SDK.
# Package names live in the binary manifest as UTF-16, hence -e l.
# Collected once: piping into `grep -q` would SIGPIPE the producer, and under
# `set -o pipefail` that reads as "not found" for every app, not just wrong ones.
manifest_pkgs="$(
	find "$tree" -name 'AndroidManifest.xml' -print0 |
		xargs -0 -r strings -a -e l -n 4 2>/dev/null |
		grep -xE '[a-z][a-z0-9_]*(\.[a-z0-9_]+){1,4}' |
		grep -vE '^(android|androidx|kotlin|java|javax|com\.google|com\.android)' |
		sort -u || true
)"
if [ -z "$local_file" ] && ! grep -qxF "$pkg" <<<"$manifest_pkgs"; then
	echo "ERROR: $pkg does not appear in any AndroidManifest." >&2
	echo "       The mirror served a different app. Packages found:" >&2
	head -5 <<<"$manifest_pkgs" | sed 's/^/         /' >&2
	exit 1
fi

dex=$(find "$tree" -name 'classes*.dex' | wc -l)
bytes=$(find "$tree" -name 'classes*.dex' -printf '%s\n' | awk '{s+=$1} END {print s+0}')
echo "$pkg: $dex dex, $((bytes / 1024)) KiB of bytecode" >&2
if [ "$dex" -le 1 ] && [ "$bytes" -lt 500000 ]; then
	echo "WARNING: tiny dex — the app is probably packed, so strings will be" >&2
	echo "         useless. Fall back to brand domains and DNS query logs." >&2
fi

# Anything whose first label is a TLD or framework prefix is a Java package
# name (com.foo.bar), not a host.
javapkg='^(com|org|net|io|de|nl|dk|br|ch|jp|uk|fr|it|es|ru|cn|in|us|me|co|tv|app|android|androidx|kotlin|kotlinx|java|javax|libcore|camerax|omx|okio|okhttp|retrofit|che|msg|rtc|context|this|window|vnd|sun|e|l|u|s|t|i|r|n)\.'

# Shared SDK, CDN, CA and analytics infrastructure. Blocking these breaks
# unrelated apps, so they are never candidates.
# Shared with pcap-domains.sh: one list, two consumers.
noise="$(cat "$(dirname "$0")/noise-zones.txt")"
# Build artefacts and resource identifiers that survive the Java-package filter.
noise="$noise"'|\.pb\.cc$|gnu\.gold|materialcomponents|materialcalendar|shapeappearance|textappearance|exostyledcontrols|widget\.material'

find "$tree" \( -name 'classes*.dex' -o -name 'resources.arsc' -o -path '*/assets/*' \
	-o -path '*/res/raw/*' -o -name '*.so' -o -name '*.json' -o -name '*.js' \) -type f -print0 |
	xargs -0 -r strings -n 8 2>/dev/null |
	grep -oiE '(https?://)?[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+\.(com|net|org|live|tv|app|io|me|cc|xyz|top|club|vip|link|site|online|info|co|us|sg|hk|in|cn|video|chat|fun|pro|world|space|shop|store|life|icu|art|mobi|one|win|asia|gold|today)\b' |
	sed -E 's#^https?://##' | tr '[:upper:]' '[:lower:]' | sort -u |
	grep -viE "$javapkg" | grep -viE "$noise"
