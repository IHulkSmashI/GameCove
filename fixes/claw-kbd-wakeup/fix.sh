#!/bin/sh
# GameCove fix: the volume buttons wake every MSI Claw from sleep.
# usage: fix.sh install|remove|status|set on|off
#
# The Claw's volume buttons are keys on its i8042 (AT) keyboard, and that keyboard is a wakeup
# source, so a knock on a volume button in a bag wakes the handheld. Handheld Daemon used to switch
# it off at start; Bazzite moved the Claw to InputPlumber, which doesn't, and the kernel quirk for
# it was turned down in favour of a udev rule (Dmitry Torokhov, LKML 2025-06). This is that rule,
# for MSI Claw boards only. The power button is an ACPI button and still wakes it. See fixes/README.md.
set -eu
NAME=claw-kbd-wakeup
DEVICES="msi-claw-a1m msi-claw-7-ai-plus msi-claw-8-ai-plus msi-claw-8-ex msi-claw-a8 msi-claw-family"
RULE=/etc/udev/rules.d/60-gamecove-claw-kbd-wakeup.rules
FILES="$RULE"
RELOAD=udev
# shellcheck source=fixes/lib/gcfix.sh
. "$(cd "$(dirname "$0")/../lib" && pwd)/gcfix.sh"

file_text() {
	cat <<EOF
$GC_MARK
# The volume buttons are part of the i8042 keyboard and must not wake the Claw from sleep.
# Remove with: gamecove-fix $NAME remove
ACTION=="add|change", SUBSYSTEM=="serio", DRIVERS=="atkbd", ATTR{[dmi/id]board_vendor}=="Micro-Star International Co., Ltd.", ATTR{[dmi/id]board_name}=="MS-1T*", ATTR{power/wakeup}="disabled"
EOF
}

# The i8042 keyboard ports (serio devices driven by atkbd) that can wake the system, as real paths.
kbd_ports() {
	for d in "$ROOT"/sys/bus/serio/devices/serio*; do
		[ -f "$d/power/wakeup" ] || continue
		[ "$(basename "$(readlink "$d/driver" 2>/dev/null || echo none)")" = atkbd ] || continue
		printf '%s\n' "${d#"$ROOT"}"
	done
}

hw_present() { [ -n "$(kbd_ports)" ]; }

# Fixed by the system: a rule of its own for this, or the kernel quirk (keyboard wakeup already off
# while our rule isn't there).
os_fixed() {
	gc_rule_elsewhere 'serio' 'power/wakeup' 'MS-1T' && return 0
	gc_installed && return 1
	ports="$(kbd_ports)"
	[ -n "$ports" ] || return 1
	for p in $ports; do
		[ "$(cat "$ROOT$p/power/wakeup" 2>/dev/null)" = disabled ] || return 1
	done
	return 0
}

apply_now() {
	for p in $(kbd_ports); do
		save_value "$p/power/wakeup"
		write_value "$p/power/wakeup" disabled
	done
}

gc_main "$@"
