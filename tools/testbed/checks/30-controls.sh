#!/bin/sh
# Every control GameCove offers on this device (the quick-menu tabs): detected or the
# plain reason, then each safe one changed through the real Controls, read back from the
# system (sysfs / D-Bus / gamescope) and put back. Before/after snapshots of the power,
# display and LED nodes go to out/controls/. GC_PROBE="id id" limits the probe.
. "$(dirname "$0")/lib.sh"

if ! controls list >"$CHECK_OUT/list.txt"; then
	skip list "GameCove isn't installed (no $GC_APP)"
	exit 0
fi
total=0
avail=0
while IFS="$(printf '\t')" read -r _ id group kind available value _root _pg _shape reason; do
	total=$((total + 1))
	case "$available" in
	available=yes) avail=$((avail + 1)); pass "$id" "$group $kind ${value#value=}" ;;
	*) info "$id" "unavailable: ${reason#reason=}" ;;
	esac
done <"$CHECK_OUT/list.txt"
[ "$total" -gt 0 ] && pass list "$avail of $total controls available on this device" || fail list "the controls CLI listed nothing"

# Not probed automatically: actions, anything that cuts the network or the screen,
# sleeps, needs the admin password (smt, cores, sleep mode, MCU), or lives only in the
# process that set it (keep awake). Those are manual steps in the plan.
deny='system.sleep system.screenshot system.keep_awake network.airplane network.wifi network.bluetooth
display.refresh_rate display.refresh_unlock display.rotation display.hdr display.hdr_itm
power.smt power.cpu_cores power.sleep_mode power.mcu_powersave power.fan_curve
controller.reset_layout controller.rumble_test perf.clear_shader_cache perf.upscale_recommended perf.upscale_undo
perf.wrapper_remove_all perf.launch_wrapper perf.proton controller.desktop_mode'
ids="${GC_PROBE:-}"
if [ -z "$ids" ]; then
	while IFS="$(printf '\t')" read -r _ id _group kind available _rest; do
		[ "$available" = available=yes ] || continue
		case "$kind" in slider | choice | toggle | color) ;; *) continue ;; esac
		case " $(echo "$deny" | tr '\n' ' ') " in *" $id "*) continue ;; esac
		ids="$ids $id"
	done <"$CHECK_OUT/list.txt"
fi
# shellcheck disable=SC2046  # globbed node list
snap before $(power_nodes)
for id in $ids; do
	# shellcheck disable=SC2046
	snap "pre-$id" $(power_nodes)
	line="$(controls probe "$id" | grep '^probe' | head -n 1)"
	# shellcheck disable=SC2046
	snap "post-$id" $(power_nodes)
	printf '%s\n' "$line" >>"$CHECK_OUT/probe.txt"
	res="$(printf '%s\n' "$line" | tr '\t' '\n' | sed -n 's/^result=//p')"
	rest="$(printf '%s\n' "$line" | cut -f4- | tr '\t' ' ')"
	case "$res" in
	ok) pass "probe.$id" "$rest" ;;
	skipped) skip "probe.$id" "$rest" ;;
	"") fail "probe.$id" "no answer from the controls CLI" ;;
	*) fail "probe.$id" "$res: $rest" ;;
	esac
done
# shellcheck disable=SC2046
snap after $(power_nodes)
left="$(snap_diff before after)"
[ -z "$left" ] && pass restored "every probed node is back to its value from before" ||
	fail restored "left changed after the probes: $(echo "$left" | tr '\n' ' ')"
manual look.brightness "Quick menu > Display: move brightness; the screen follows smoothly"
manual look.colour "Display: vibrance / colour temperature / night light visibly change and go back"
manual look.overlay "Performance: each overlay preset shows the right MangoHud layout over a game"
manual feel.rumble "Controller: rumble test and strength: you feel the difference"
manual look.led "Controller: LED colour / effect / brightness: the lights match"
manual hear.audio "Audio: volume, mute, output switch: you hear it"
manual excluded "Change by hand once (not automatic): Wi-Fi, Bluetooth, airplane, refresh rate (keep/revert dialog), rotation, HDR, sleep, screenshot, keep awake"
