#!/bin/sh
# testbed: by-name-only (needs the owner; run it with: check <name>)
# The real charger: the owner unplugs (and plugs back) while this watches the power nodes.
# GC_UNPLUG_WAIT seconds per step (default 90). Needs the owner's hands.
. "$(dirname "$0")/lib.sh"
w="${GC_UNPLUG_WAIT:-90}"
start="$(ac_online)"
[ "$start" = unknown ] && { skip ac "no charger node in /sys/class/power_supply"; exit 0; }
# shellcheck disable=SC2046
snap ac-before $(power_nodes)
if [ "$start" = yes ]; then
	manual unplug "Unplug the charger now (waiting ${w}s)"
	if wait_ac no "$w"; then
		sleep "${GC_SETTLE:-5}"
		# shellcheck disable=SC2046
		snap ac-unplugged $(power_nodes)
		pass unplug "seen unplugged; changed: $(snap_diff ac-before ac-unplugged | tr '\n' ' ')"
		manual replug "Plug the charger back in (waiting ${w}s)"
		if wait_ac yes "$w"; then
			sleep "${GC_SETTLE:-5}"
			# shellcheck disable=SC2046
			snap ac-replugged $(power_nodes)
			pass replug "seen plugged; changed: $(snap_diff ac-unplugged ac-replugged | tr '\n' ' ')"
		else
			fail replug "not plugged back within ${w}s"
		fi
	else
		fail unplug "not unplugged within ${w}s"
	fi
else
	info ac "on battery now: plug in and run this again to test unplugging"
fi
manual profile-follow "With battery/AC profiles set in GameCove: the TDP in the quick menu follows the charger within a few seconds"
