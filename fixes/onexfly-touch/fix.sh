#!/bin/sh
# GameCove fix: touch turned 90 degrees in Gaming Mode on sideways panels started as "external".
# usage: fix.sh install|remove|status|set on|off
#
# gamescope-session-plus's device-quirks start gamescope with PANEL_TYPE=external for the OneXFly F1
# (its panel is mounted sideways). gamescope then turns the picture but not the touch input, so taps
# land in the wrong place (Bazzite issue 5581). Telling it the panel is internal fixes touch and keeps
# the picture right; confirmed on the device, upstream fix ChimeraOS/gamescope-session PR 128 (open
# since 2026-08-24). Once device-quirks stops saying "external" this reports os-fixed.
# The same device-quirks pattern (PANEL_TYPE=external, ORIENTATION=left) covers the OneXPlayer 2 /
# 2 Pro, AOKZOE A1 / A1 Pro and OneXPlayer X1 A / X1 mini, so it is offered there too (trait
# session_quirk in devices.json; the handhelds come from fixes/lib/fix-devices.txt).
#
# Each session client gets a small file in /etc/gamescope-session-plus/sessions.d/ (read after
# device-quirks): GameCove's own session, and Steam's (steam, ogui-steam) where no other file is
# there. The files check the DMI product name themselves (every handheld the fix is for), so
# another handheld booting the same drive is untouched. Takes effect at the next session start.
set -eu
NAME=onexfly-touch
DEVICES="@"  # fixes/lib/fix-devices.txt, from the trait selectors in app/data/fixes.json
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

# "P1" | "P2" ...: the product names of every handheld the fix is for (from devices.txt).
case_products() {
	gc_products | awk 'NF { printf "%s\"%s\"", (n++ ? " | " : ""), $0 }'
}

file_text() {
	cat <<EOF
$GC_MARK
# Sideways panel started as external: treat it as internal so gamescope turns touch with the picture.
# Remove with: gamecove-fix $NAME remove
case "\$(cat /sys/class/dmi/id/product_name 2>/dev/null)" in
$(case_products)) PANEL_TYPE=internal ;;
esac
EOF
}

# What device-quirks does for this product: "external" (a block it is listed in sets
# PANEL_TYPE=external), "listed" (listed, never external), or "none".
quirk_for_product() {
	[ -f "$ROOT$QUIRKS" ] || { echo none; return 0; }
	awk -v p="$(cat "$ROOT/sys/class/dmi/id/product_name" 2>/dev/null)" '
		/^[A-Z0-9_]*_LIST="/ {
			v = $0; sub(/^[^"]*"/, "", v); sub(/".*$/, "", v)
			n = split(v, a, ":"); for (i = 1; i <= n; i++) if (a[i] == p && p != "") { hit = 1; listed = 1 }
			next
		}
		hit && /^[[:space:]]*PANEL_TYPE=external/ { ext = 1 }
		/^fi/ { hit = 0 }
		END { print (ext ? "external" : (listed ? "listed" : "none")) }
	' "$ROOT$QUIRKS"
}

# Needed: device-quirks starts this panel as external.
hw_present() { [ "$(quirk_for_product)" = external ]; }

# Fixed upstream: the product is still listed but no block makes it external any more.
os_fixed() { [ "$(quirk_for_product)" = listed ]; }

gc_main "$@"
