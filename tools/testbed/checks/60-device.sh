#!/bin/sh
# This device's own extras (test plan: Claw 8 EX / ROG Ally / Legion Go S). Read-only.
. "$(dirname "$0")/lib.sh"
fixst() { "$GC_FIX" "$1" status 2>/dev/null; }
attr() { rd "/sys/class/firmware-attributes/$1/attributes/$2/$3"; }
ppt() { # <firmware-attributes dir>
	for a in ppt_pl1_spl ppt_pl2_sppt ppt_pl3_fppt; do
		v="$(attr "$1" "$a" current_value)"
		[ -n "$v" ] && info "tdp.$a" "$v W (min $(attr "$1" "$a" min_value), max $(attr "$1" "$a" max_value))"
	done
	[ -n "$(attr "$1" ppt_pl1_spl current_value)" ] && pass tdp "$1 firmware attributes present" || warn tdp "no $1 ppt_* attributes"
}
leds() {
	n=0
	for l in "$GC_ROOT"/sys/class/leds/*; do
		case "$(basename "$l")" in *rgb* | *joystick* | *ring* | *go_s* | *legion*) ;; *) continue ;; esac
		n=$((n + 1))
		info "led.$(basename "$l")" "multi_intensity=$(head -n 1 "$l/multi_intensity" 2>/dev/null) brightness=$(head -n 1 "$l/brightness" 2>/dev/null)/$(head -n 1 "$l/max_brightness" 2>/dev/null)"
	done
	[ "$n" -gt 0 ] && pass leds "$n RGB LED node(s)" || warn leds "no RGB LED node in /sys/class/leds"
}
sm_tdp() {
	have "$GC_BUSCTL" || return 0
	v="$("$GC_BUSCTL" --user get-property com.steampowered.SteamOSManager1 /com/steampowered/SteamOSManager1 com.steampowered.SteamOSManager1.TdpLimit1 TdpLimit 2>/dev/null)"
	[ -n "$v" ] && info steamos-manager.tdp "TdpLimit1: $v (min $("$GC_BUSCTL" --user get-property com.steampowered.SteamOSManager1 /com/steampowered/SteamOSManager1 com.steampowered.SteamOSManager1.TdpLimit1 TdpLimitMin 2>/dev/null), max $("$GC_BUSCTL" --user get-property com.steampowered.SteamOSManager1 /com/steampowered/SteamOSManager1 com.steampowered.SteamOSManager1.TdpLimit1 TdpLimitMax 2>/dev/null))"
}

case "$(device_kind)" in
claw8ex)
	for f in claw8ex-gyro claw8ex-buttons claw8ex-vrr claw-kbd-wakeup claw-wifi-d3cold; do
		s="$(fixst "$f")"
		[ -n "$s" ] && info "fix.$f" "$(printf '%s' "$s" | tr '\n' ' ')"
	done
	fixst claw8ex-gyro | grep -q '^installed=yes' && pass gyro-fix "gyro fix installed" || warn gyro-fix "gyro fix not installed (Fixes page: apply it, then test gyro)"
	ppt msi-wmi-platform
	for c in "$GC_ROOT"/sys/class/drm/card*-eDP-1; do
		[ -e "$c/vrr_capable" ] && info vrr "$(basename "$c") vrr_capable=$(head -n 1 "$c/vrr_capable")"
	done
	up="$("$GC_ROOT/usr/libexec/gamecove/gamecove-upscale" state 2>/dev/null | head -c 4000)"
	printf '%s\n' "$up" >"$CHECK_OUT/upscale-state.json"
	info xess "gamecove-upscale state saved (XeSS XMX driver: see upscale-state.json)"
	manual gyro "With the gyro fix: GameCove > Controller > gyro on; tilt: the right stick / mouse moves smoothly, no drift at rest; Steam's gyro settings see it"
	manual buttons "M1 / M2 back buttons and the MSI Center / Quick Settings buttons: each does what the Buttons page says"
	manual vrr "VRR on (Display): MangoHud's frametime is smooth at 40-60 fps in a game; no flicker"
	manual xess "XeSS XMX: Upscaling page on a DX11/12 game with XeSS: 'XMX' is the active path (OptiScaler overlay Insert key shows XeSS 2.x XMX)"
	;;
ally)
	ppt asus-armoury
	v="$(attr asus-armoury mcu_powersave current_value)"
	info mcu_powersave "${v:-not present}"
	s="$(fixst ally-mcu-powersave)"
	info fix.ally-mcu-powersave "$(printf '%s' "$s" | tr '\n' ' ')"
	mcu="$(cat "$GC_ROOT/var/lib/gamecove/ally-mcu-version" 2>/dev/null | tr '\n' ' ')"
	case "$mcu" in
	*version=*) ver="$(printf '%s' "$mcu" | sed -n 's/.*version=\([0-9]*\).*/\1/p')"
		[ "${ver:-0}" -ge 319 ] && pass mcu "MCU firmware $ver (319+ is safe for MCU power saving)" ||
			warn mcu "MCU firmware $ver: update it (Armoury Crate on Windows) before turning MCU power saving on" ;;
	*) info mcu "MCU version not read yet: run 'pkexec $GC_FIX ally-mcu-powersave status' once (asks for the password)" ;;
	esac
	leds
	sm_tdp
	pp="$(rd /sys/firmware/acpi/platform_profile)"
	info platform_profile "$pp (steamos-manager wants 'performance' for its TDP on the Ally)"
	if [ "$(os_id)" = steamos ] && [ -x "$GC_ROOT/usr/bin/steamos-polkit-helpers/steamos-update" ]; then
		"$GC_ROOT/usr/bin/steamos-polkit-helpers/steamos-update" check >"$CHECK_OUT/steamos-update-check.txt" 2>&1
		rc=$?
		case "$rc" in 0) info steamos-update "an update is available" ;; 7) info steamos-update "up to date" ;; *) warn steamos-update "check exited $rc" ;; esac
	fi
	manual armoury "Armoury / Command Centre buttons: each opens what the Buttons page says (GameCove's quick menu / home)"
	manual leds "Controller > LEDs: set red, then off, then a rainbow effect: the stick rings match; after sleep they come back"
	manual updater "SteamOS updates from GameCove's Updates page: check matches Steam's; after applying, restart at once (GameCove's files are unmerged until the reboot)"
	;;
legiongos)
	ppt lenovo-wmi-other-0
	pp="$(rd /sys/firmware/acpi/platform_profile)"
	info platform_profile "$pp (custom is needed for a manual TDP)"
	leds
	sm_tdp
	bat="$(rd /sys/class/power_supply/BAT0/charge_types)"
	[ -n "$bat" ] && info charge_types "$bat"
	manual tdp-limits "Power > TDP: the slider's range matches the firmware's min/max above on battery and on AC; setting 8 W and 25 W reads back in ppt_pl1_spl"
	manual trackpad "Controller > Trackpad: mouse mode moves the cursor in Desktop / a game menu; off disables it"
	manual leds "Controller > LEDs: colour and brightness change the stick lights"
	;;
*) skip device "not one of the three test devices" ;;
esac
