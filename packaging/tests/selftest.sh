#!/bin/sh
# gamecove-selftest against a fake root and stub commands (busctl, curl, pgrep, rpm, the app, the fix
# helper, the input watcher). Never touches the real system, D-Bus, input devices or the network.
# usage: sh packaging/tests/selftest.sh
# shellcheck disable=SC2016,SC2034 # single-quoted stub bodies and checks (eval later) on purpose
set -u
REPO=$(cd "$(dirname "$0")/../.." && pwd)
ST="$REPO/packaging/bin/gamecove-selftest"
PASS=0
FAILS=0

check() {
	if eval "$1"; then
		PASS=$((PASS + 1))
	else
		FAILS=$((FAILS + 1))
		printf 'FAIL %s: %s\n' "$CASE" "$2" >&2
	fi
}

# setup <board> <case> <backends>: fresh fake root, home and stubs. Backends: words from ip (InputPlumber),
# ps (PowerStation), sm (steamos-manager), hhd (Handheld Daemon), net (GitHub reachable).
setup() {
	CASE=$2
	[ -z "${T:-}" ] || rm -rf "$T"
	T=$(mktemp -d)
	R=$T/root
	B=$T/bin
	H=$T/home/tester
	mkdir -p "$R/sys/class/dmi/id" "$R/proc" "$R/etc" "$R/sys/class/drm/card1/device" "$R/sys/class/powercap/intel-rapl:0" "$B" "$H"
	echo "$1" >"$R/sys/class/dmi/id/board_name"
	echo "ASUSTeK COMPUTER INC." >"$R/sys/class/dmi/id/sys_vendor"
	echo "ROG Ally RC71L_RC71L" >"$R/sys/class/dmi/id/product_name"
	echo 'PRETTY_NAME="Bazzite 43 (FROM Fedora Kinoite)"' >"$R/etc/os-release"
	echo "BOOT_IMAGE=/vmlinuz quiet" >"$R/proc/cmdline"
	mkdir -p "$T/drivers/amdgpu"
	ln -s "$T/drivers/amdgpu" "$R/sys/class/drm/card1/device/driver"
	echo 123456 >"$R/sys/class/powercap/intel-rapl:0/energy_uj"
	: >"$T/calls"
	BACKENDS=$3
	export GAMECOVE_ROOT="$R" HOME="$H" GAMECOVE_APP="$B/gamecove.x86_64" GAMECOVE_FIX="$B/gamecove-fix" FAKE="$T" BACKENDS
	export GAMECOVE_SELFTEST_TIMEOUT=1
	unset GAMECOVE_SELFTEST_WATCH
	cat >"$B/gamecove.x86_64" <<'EOF'
#!/bin/sh
echo "Godot Engine v4.7.2 - https://godotengine.org"
echo "selftest.device.id=${FAKE_DEVICE_ID:-asus-rog-ally}"
echo "selftest.device.support=partial"
echo "selftest.gpu.driver=amdgpu"
EOF
	cat >"$B/gamecove-fix" <<'EOF'
#!/bin/sh
[ "$1" = --list ] && { echo fan; echo claw8ex-vrr; exit 0; }
case $1 in
fan) printf 'applies=yes\ninstalled=no\nnote=user 76561198012345678 token=abcdef\nstate=off\n' ;;
claw8ex-vrr) printf 'applies=no\nold_kernel_args=no\nstate=n/a\n' ;;
esac
EOF
	cat >"$B/busctl" <<'EOF'
#!/bin/sh
echo "busctl $*" >>"$FAKE/calls"
has() { case " $BACKENDS " in *" $1 "*) return 0 ;; esac; return 1; }
case "$*" in
*InputPlumber/Manager*Version*) has ip && echo 's "0.70.2"' && exit 0 ;;
*"--list tree org.shadowblip.InputPlumber"*) has ip && printf '/\n/org/shadowblip/InputPlumber\n/org/shadowblip/InputPlumber/CompositeDevice0\n' && exit 0 ;;
*CompositeDevice0*Name*) echo 's "ASUS ROG Ally"'; exit 0 ;;
*TdpLimit1\ TdpLimit\ u*) has sm && echo "$*" | awk '{print $NF}' >"$FAKE/sm_tdp" && exit 0 ;;
*TdpLimit1\ TdpLimit*) has sm && echo "u $(cat "$FAKE/sm_tdp" 2>/dev/null || echo 18)" && exit 0 ;;
*EnumerateCards*) has ps && echo 'ao 1 "/org/shadowblip/Performance/GPU/card1"' && exit 0 ;;
*set-property*GPU.Card.TDP\ TDP\ d*) has ps && echo "$*" | awk '{print $NF}' >"$FAKE/ps_tdp" && exit 0 ;;
*GPU.Card.TDP\ TDP*) has ps && echo "d $(cat "$FAKE/ps_tdp" 2>/dev/null || echo 15.000000)" && exit 0 ;;
esac
exit 1
EOF
	cat >"$B/curl" <<'EOF'
#!/bin/sh
echo "curl $*" >>"$FAKE/calls"
has() { case " $BACKENDS " in *" $1 "*) return 0 ;; esac; return 1; }
hdr=""
data=""
while [ $# -gt 0 ]; do
	case $1 in
	-H) [ "${2#@}" != "$2" ] && hdr=$(cat "${2#@}"); shift ;;
	--data) data=$2; shift ;;
	-w | -o | --max-time | -X) shift ;;
	esac
	url=$1
	shift
done
case $url in
http://127.0.0.1:5335/*)
	has hhd || exit 7
	printf '%s' "$hdr" | grep -q "Bearer SECRET123" || exit 22
	case $url in
	*/version) echo '{"version": 5}' ;;
	*/state)
		if [ -n "$data" ]; then echo "$data" >"$FAKE/hhd_post"; fi
		w=$(sed -n 's/.*"tdp": \([0-9]*\)}.*/\1/p' "$FAKE/hhd_post" 2>/dev/null)
		echo "{\"controllers\": {\"rog_ally\": {\"imu\": true}}, \"hhd\": {\"settings\": {\"tdp_enable\": true}}, \"tdp\": {\"asus\": {\"tdp_v2\": {\"mode\": \"custom\", \"custom\": {\"tdp\": ${w:-15}}}}}}"
		;;
	esac
	;;
https://github.com/*) has net && printf 302 && exit 0; printf 000; exit 6 ;;
esac
EOF
	printf '#!/bin/sh\nexit 1\n' >"$B/pgrep"
	printf '#!/bin/sh\necho 25.2.6\n' >"$B/rpm"
	chmod +x "$B"/*
	PATH="$B:$ORIG_PATH"
	export PATH
}
ORIG_PATH=$PATH

report() { ls "$H"/gamecove-selftest-*.txt 2>/dev/null | head -n 1; }

# ---- the ROG Ally with InputPlumber and PowerStation ---------------------------------------------------
setup RC71L ally_inputplumber "ip ps"
sh "$ST" --no-network >"$T/out" 2>&1
rc=$?
check '[ "$rc" -eq 0 ]' "exit 0 when nothing failed ($(grep fail "$T/out" | head -n 2))"
check '[ -n "$(report)" ]' "report file written"
check 'case $(report) in */gamecove-selftest-asus-rog-ally-*.txt) true ;; *) false ;; esac' "named after the device"
check 'grep -q "Report saved: ~\|Report saved: $H" "$T/out"' "prints the path"
check 'grep -q "\[ok\]   detected as asus-rog-ally (support: partial)" "$(report)"' "device from the app"
check 'grep -q "^dmi.board_name: RC71L$" "$(report)"' "DMI strings"
check 'grep -q "^os: Bazzite 43" "$(report)"' "OS"
check 'grep -q "^mesa: 25.2.6$" "$(report)"' "Mesa"
check 'grep -q "^gpu_driver: amdgpu$" "$(report)"' "GPU driver"
check 'grep -q "InputPlumber sees 1 device" "$(report)"' "InputPlumber devices"
check 'grep -q "^inputplumber.device: CompositeDevice0: ASUS ROG Ally$" "$(report)"' "device name"
check 'grep -q "TDP readable through powerstation: 15.000000 W" "$(report)"' "TDP through PowerStation"
check '! grep -q "set-property" "$T/calls"' "no write without --write"
check 'grep -q "^fix.fan: applies=yes" "$(report)"' "fix status"
check 'grep -q "power readings readable" "$(report)"' "RAPL readable"
check 'grep -q "network check skipped" "$(report)"' "--no-network"
check '! grep -q "76561198012345678" "$(report)"' "Steam id redacted"
check '! grep -q "abcdef" "$(report)"' "token redacted"
check '! grep -q "$H" "$(report)"' "no home path"
check '! grep -q "tester" "$(report)"' "no user name"

# ---- --write: same value back ------------------------------------------------------------------------
setup RC71L ally_write "ip ps"
sh "$ST" --no-network --write >"$T/out" 2>&1
check 'grep -q "busctl --system set-property org.shadowblip.PowerStation /org/shadowblip/Performance/GPU/card1 org.shadowblip.GPU.Card.TDP TDP d 15.000000" "$T/calls"' "writes the current TDP"
check 'grep -q "TDP write: set 15 W, read back 15" "$(report)"' "and reads it back"

setup 83L3 legion_go_s_steamos_manager "ip sm"
sh "$ST" --no-network --write >"$T/out" 2>&1
check 'grep -q "TDP readable through steamos-manager: 18 W" "$(report)"' "TDP through steamos-manager"
check 'grep -q "TdpLimit u 18" "$T/calls"' "steamos-manager write"
check 'grep -q "TDP write: set 18 W, read back 18" "$(report)"' "steamos-manager read back"

# ---- Handheld Daemon -------------------------------------------------------------------------------------
setup RC71L ally_hhd "hhd ps net"
mkdir -p "$R/tmp/hhd"
echo SECRET123 >"$R/tmp/hhd/token"
sh "$ST" --write >"$T/out" 2>&1
check 'grep -q "Handheld Daemon handles: rog_ally" "$(report)"' "hhd's controllers"
check 'grep -q "TDP readable through hhd: 15 W" "$(report)"' "hhd owns TDP: read through it, not PowerStation"
check 'grep -q "\"mode\": \"custom\"" "$T/hhd_post" && grep -q "\"tdp\": 15" "$T/hhd_post"' "write posts custom mode and the same watts"
check 'grep -q "TDP write: set 15 W, read back 15" "$(report)"' "hhd read back"
check '! grep -q SECRET123 "$T/calls"' "token never on a command line"
check '! grep -q SECRET123 "$(report)"' "token not in the report"
check 'grep -q "GitHub releases reachable (HTTP 302)" "$(report)"' "network check"
check 'grep -q "inputplumber: not running" "$(report)"' "InputPlumber absent"

setup RC71L nothing_running ""
sh "$ST" >"$T/out" 2>&1
rc=$?
check '[ "$rc" -eq 1 ]' "exit 1 when something failed"
check 'grep -q "no controller service" "$(report)"' "no controller service is a failure"
check 'grep -q "no TDP service answered" "$(report)"' "no TDP service"
check 'grep -q "GitHub releases not reachable" "$(report)"' "offline"

# ---- the Claw's old EDID kernel argument seen on another handheld --------------------------------------
setup RC71L old_claw_karg "ip ps"
echo "BOOT_IMAGE=/vmlinuz quiet drm.edid_firmware=eDP-1:edid/gamecove-csw0801-30-120.bin" >"$R/proc/cmdline"
sh "$ST" --no-network >"$T/out" 2>&1
check 'grep -q "\[fail\] the Claw.s EDID kernel argument is active on this handheld" "$(report)"' "flagged as a failure on the Ally"

# ---- interactive, with a fake input watcher -------------------------------------------------------------
setup RC71L interactive "ip ps"
cat >"$B/watch" <<'EOF'
#!/bin/sh
# kind seconds: a press for buttons, Enter (skip) for motion
[ "$1" = button ] && echo "Microsoft X-Box 360 pad 0: BTN_MODE" && exit 0
echo SKIP
EOF
chmod +x "$B/watch"
GAMECOVE_SELFTEST_WATCH="$B/watch" sh "$ST" --no-network --interactive </dev/null >"$T/out" 2>&1
check '[ "$(grep -c "\[ok\]   Press.*BTN_MODE" "$(report)")" = 4 ]' "four button steps seen"
check 'grep -q "\[info\] Move or tilt the handheld (gyro): skipped" "$(report)"' "a skipped step"
printf '#!/bin/sh\nexit 0\n' >"$B/watch"
rm -f "$H"/gamecove-selftest-*.txt
GAMECOVE_SELFTEST_WATCH="$B/watch" sh "$ST" --no-network --interactive </dev/null >"$T/out" 2>&1
check 'grep -q "\[fail\] Press the home / Guide button.*nothing seen in 1s" "$(report)"' "timeout is a failure"

# ---- usage -----------------------------------------------------------------------------------------------
setup RC71L usage ""
sh "$ST" --bogus >/dev/null 2>&1
rc=$?
check '[ "$rc" -eq 64 ]' "unknown option: exit 64"

[ -z "${T:-}" ] || rm -rf "$T"
printf 'selftest: %d passed, %d failed\n' "$PASS" "$FAILS"
[ "$FAILS" -eq 0 ]
