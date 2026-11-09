#!/bin/sh
# Controller stack: InputPlumber devices (name, profile, capabilities, target devices,
# intercept mode), Handheld Daemon, Steam Input conflicts. Read-only.
. "$(dirname "$0")/lib.sh"
IP=org.shadowblip.InputPlumber
get() { "$GC_BUSCTL" --system get-property "$IP" "$1" "$2" "$3" 2>/dev/null | sed 's/^[a-z]* //'; }
if "$GC_BUSCTL" --system --list tree "$IP" >"$CHECK_OUT/tree.txt" 2>/dev/null; then
	pass inputplumber "running, version $(get /org/shadowblip/InputPlumber/Manager org.shadowblip.InputManager Version)"
	n=0
	for dev in $(grep -E '/CompositeDevice[0-9]+$' "$CHECK_OUT/tree.txt"); do
		n=$((n + 1))
		name="$(get "$dev" org.shadowblip.Input.CompositeDevice Name)"
		prof="$(get "$dev" org.shadowblip.Input.CompositeDevice ProfileName)"
		mode="$(get "$dev" org.shadowblip.Input.CompositeDevice InterceptMode)"
		targets="$(get "$dev" org.shadowblip.Input.CompositeDevice TargetDevices)"
		caps="$(get "$dev" org.shadowblip.Input.CompositeDevice Capabilities)"
		printf '%s\nname=%s\nprofile=%s\nintercept=%s\ntargets=%s\ncaps=%s\n\n' "$dev" "$name" "$prof" "$mode" "$targets" "$caps" >>"$CHECK_OUT/devices.txt"
		info "device$n" "$name, profile $prof, intercept $mode"
		# the same rule as controller.gyro: Gyroscope:<source> can be switched by a profile;
		# older InputPlumber's legacy Gamepad:Gyro passes the IMU but can't be switched off
		case "$caps" in
			*'"Gyroscope:'*) info "device$n.gyro" "gyro capability present (Gyroscope:*, GameCove can switch it)" ;;
			*'"Gamepad:Gyro"'*) info "device$n.gyro" "legacy Gamepad:Gyro only: the gyro reaches games, GameCove can't switch it off on this InputPlumber" ;;
		esac
		case "$caps" in *Paddle*) info "device$n.paddles" "back buttons present" ;; esac
		case "$caps" in *Touchpad* | *touchpad*) info "device$n.touchpad" "touchpad present" ;; esac
		for t in $(printf '%s' "$targets" | grep -o '/org/shadowblip/InputPlumber/devices/target/[a-z0-9_]*'); do
			info "device$n.target" "$t: $(get "$t" org.shadowblip.Input.Target DeviceType 2>/dev/null)"
		done
	done
	[ "$n" -gt 0 ] && pass devices "$n composite device(s)" || warn devices "InputPlumber runs but manages no device"
	in_gc="$("$GC_SYSTEMCTL" --user is-active gamescope-session-plus@gamecove.service 2>/dev/null)"
	if [ "$in_gc" != active ] && grep -q '^intercept=2' "$CHECK_OUT/devices.txt" 2>/dev/null; then
		fail intercept "a device is still in intercept mode 2 outside GameCove: the session's reset didn't run"
	fi
else
	case "$(device_kind)|$(os_id)" in
	ally\|steamos) info inputplumber "not running: SteamOS reads the Ally's controller itself (no InputPlumber entry in steamos-manager for RC71L)" ;;
	*) warn inputplumber "not running: GameCove's controller settings will be unavailable" ;;
	esac
fi
if [ "$("$GC_SYSTEMCTL" is-active "hhd@$(id -un 2>/dev/null).service" 2>/dev/null)" = active ]; then
	info hhd "Handheld Daemon is running"
	[ "$("$GC_SYSTEMCTL" is-active inputplumber.service 2>/dev/null)" = active ] && warn both "InputPlumber and Handheld Daemon both run: double inputs likely"
fi
manual guide "In a game (GameCove session): press Guide / the device's menu button: GameCove's quick menu opens over the game and takes the controller; press again: the game gets it back"
manual qam "QAM / '...' button: what opens (GameCove's quick menu, Steam's, or nothing)? Note it"
manual steam-input "In a Steam game with Steam Input on: no double inputs; Steam's controller settings open from GameCove's link"
