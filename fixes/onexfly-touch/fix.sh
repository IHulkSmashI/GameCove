#!/bin/sh
# GameCove fix: on the OneXFly F1 the touchscreen is turned 90 degrees in Gaming Mode.
# usage: fix.sh install|remove|status|set on|off
#
# gamescope-session-plus's device-quirks start gamescope with PANEL_TYPE=external for the OneXFly F1
# (its panel is mounted sideways). gamescope then turns the picture but not the touch input, so taps
# land in the wrong place (Bazzite issue 5581). Telling it the panel is internal fixes touch and keeps
# the picture right; confirmed on the device, upstream fix ChimeraOS/gamescope-session PR 128 (open
# since 2026-08-24). Once device-quirks stops saying "external" this reports os-fixed.
#
# Each session client gets a small file in /etc/gamescope-session-plus/sessions.d/ (read after
# device-quirks): GameCove's own session, and Steam's (steam, ogui-steam) where no other file is
# there. The files check the DMI product name themselves, so another handheld booting the same drive
# is untouched. Takes effect at the next session start.
set -eu
NAME=onexfly-touch
DEVICES="onexplayer-onexfly-f1"
SESSIONS=/etc/gamescope-session-plus/sessions.d
QUIRKS=/usr/share/gamescope-session-plus/device-quirks
FILES="$SESSIONS/gamecove"
# shellcheck source=fixes/lib/gcfix.sh
. "$(cd "$(dirname "$0")/../lib" && pwd)/gcfix.sh"
# Steam's clients only where nobody else has a file (an existing one is never touched).
for c in steam ogui-steam; do
	if [ ! -e "$ROOT$SESSIONS/$c" ] || gc_ours "$SESSIONS/$c"; then
		FILES="$FILES $SESSIONS/$c"
	fi
done

file_text() {
	cat <<EOF
$GC_MARK
# OneXFly F1: treat the sideways panel as internal so gamescope turns touch input with the picture.
# Remove with: gamecove-fix $NAME remove
case "\$(cat /sys/class/dmi/id/product_name 2>/dev/null)" in
"ONEXPLAYER F1" | "ONEXPLAYER F1 EVA-01") PANEL_TYPE=internal ;;
esac
EOF
}

# The quirk block for the 120 Hz OneXFly still says PANEL_TYPE=external.
quirk_external() {
	[ -f "$ROOT$QUIRKS" ] || return 1
	sed -n '/^OXP_120_LIST=/,/^fi/p' "$ROOT$QUIRKS" | grep -q 'PANEL_TYPE=external'
}

# Only the F1 models in that quirk list (the OLED one isn't there).
hw_present() {
	case "$(cat "$ROOT/sys/class/dmi/id/product_name" 2>/dev/null)" in
	"ONEXPLAYER F1" | "ONEXPLAYER F1 EVA-01") ;;
	*) return 1 ;;
	esac
	[ -f "$ROOT$QUIRKS" ]
}

# Fixed upstream: device-quirks exists but no longer marks the panel external.
os_fixed() { [ -f "$ROOT$QUIRKS" ] && ! quirk_external; }

gc_main "$@"
