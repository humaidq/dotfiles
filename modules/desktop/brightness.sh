# shellcheck shell=bash
# sifr-brightness — route the brightness keys to whichever panel is actually in front of the
# user: the Apple Studio Display when it is plugged in, the internal panel
# otherwise. The probe is a glob over sysfs -- no fork, no process spawned --
# so a held-down brightness key still repeats smoothly.
#
# 05AC:1114 is the Studio Display's HID interface, which is what asdbctl
# talks to. It appears as soon as the display enumerates over USB, well
# before anything is drawn on it, so docking is picked up immediately.
asd_present() {
	local dev
	for dev in /sys/bus/hid/devices/*:05AC:1114.*; do
		[ -e "$dev" ] && return 0
	done
	return 1
}

usage() {
	cat >&2 <<-EOF
		usage: sifr-brightness up|down [STEP] | set PERCENT | get

		Acts on the Apple Studio Display when one is connected, otherwise on
		the internal backlight. STEP is a percentage, default 5.
	EOF
	exit 1
}

action="${1:-}"
arg="${2:-}"
step="${arg:-5}"

case "$action" in
up | down | get) ;;
set) [ -n "$arg" ] || usage ;;
*) usage ;;
esac

if asd_present; then
	case "$action" in
	up) asdbctl up --step "$step" ;;
	down) asdbctl down --step "$step" ;;
	set) asdbctl set "$arg" ;;
	# asdbctl prints the percentage inside a sentence; reduce it to the
	# bare number so both backends answer `get` the same way.
	get) asdbctl get | grep -oE '[0-9]+' | head -n1 ;;
	esac || {
		# The display can be asleep, or its hidraw node not yet permitted.
		# Say so rather than silently dimming the panel nobody is facing.
		notify-send -u critical "Brightness" "Apple Studio Display did not respond"
		exit 1
	}
else
	case "$action" in
	up) brightnessctl -q set "$step%+" ;;
	down) brightnessctl -q set "$step%-" ;;
	set) brightnessctl -q set "$arg%" ;;
	get) brightnessctl -m | cut -d, -f4 | tr -d '%' ;;
	esac
fi
