#!/bin/sh
# Runs fix.sh against a fake sysfs (app/tests/fixtures/power/sys_claw); never the real system.
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
FIX="$HERE/fix.sh"
ROOT="$(mktemp -d)"
trap 'rm -rf "$ROOT"' EXIT
cp -R "$HERE/../../app/tests/fixtures/power/sys_claw/." "$ROOT/"
H="$ROOT/sys/class/hwmon/hwmon5"
export GAMECOVE_ROOT="$ROOT"
fail() { printf 'FAIL %s\n' "$1" >&2; exit 1; }
# dmi <root> <sys_vendor> <product_name> <board_name> [board_vendor]
dmi() {
	mkdir -p "$1/sys/class/dmi/id"
	printf '%s\n' "$2" > "$1/sys/class/dmi/id/sys_vendor"
	printf '%s\n' "$3" > "$1/sys/class/dmi/id/product_name"
	printf '%s\n' "$4" > "$1/sys/class/dmi/id/board_name"
	printf '%s\n' "${5:-$2}" > "$1/sys/class/dmi/id/board_vendor"
}
dmi "$ROOT" "Micro-Star International Co., Ltd." "Claw 8 AI+ A2VM" "MS-1T91"
table() { echo "$(cat "$H/pwm$1_auto_point1_pwm") $(cat "$H/pwm$1_auto_point2_pwm") $(cat "$H/pwm$1_auto_point3_pwm") $(cat "$H/pwm$1_auto_point4_pwm") $(cat "$H/pwm$1_auto_point5_pwm") $(cat "$H/pwm$1_auto_point6_pwm")"; }

sh "$FIX" status | grep -q '^installed=no$' || fail "status before install"
sh "$FIX" status | tail -n 1 | grep -q '^state=off$' || fail "status ends state=off before install"
sh "$FIX" set quiet >/dev/null || fail "set quiet"
sh "$FIX" status | tail -n 1 | grep -q '^state=on$' || fail "status ends state=on after set"
for n in 1 2; do
	[ "$(table $n)" = "0 102 102 115 153 191" ] || fail "fan $n quiet table ($(table $n))"
	[ "$(cat "$H/pwm${n}_enable")" = "1" ] || fail "fan $n table mode"
	[ "$(cat "$H/pwm${n}_auto_point3_temp")" = "70000" ] || fail "temperatures untouched"
done
sh "$FIX" set max >/dev/null || fail "set max"
[ "$(table 2)" = "255 255 255 255 255 255" ] || fail "max table"
sh "$FIX" set auto >/dev/null || fail "set auto"
[ "$(cat "$H/pwm1_enable")" = "2" ] || fail "auto enable=2"
if sh "$FIX" set turbo 2>/dev/null; then fail "unknown mode refused"; fi
sh "$FIX" set quiet >/dev/null
sh "$FIX" remove >/dev/null || fail "remove"
for n in 1 2; do
	[ "$(table $n)" = "0 102 128 153 179 204" ] || fail "fan $n original table back ($(table $n))"
	[ "$(cat "$H/pwm${n}_enable")" = "2" ] || fail "fan $n original enable back"
done
sh "$FIX" status | grep -q '^installed=no$' || fail "status after remove"
sh "$FIX" status | tail -n 1 | grep -q '^state=off$' || fail "remove sticks: state=off"
grep -q 'set quiet' "$ROOT/var/lib/gamecove/fixes/fan/changes.log" || fail "changes logged"
echo msi_other > "$H/name"
set +e; sh "$FIX" set quiet 2>/dev/null; code=$?; set -e
[ "$code" = "2" ] || fail "no fan driver -> exit 2 (got $code)"
[ "$(sh "$FIX" status | tr '\n' ' ')" = "applies=no state=n/a " ] || fail "status without the driver"

# ---- other drivers, each on a fresh fake hwmon -------------------------------
# new_hw <name> <fans> [manual]: a fake hwmon in a fresh root; prints its path
new_hw() {
	R="$(mktemp -d)"
	mkdir -p "$R/sys/class/hwmon/hwmon3"
	d="$R/sys/class/hwmon/hwmon3"
	echo "$1" > "$d/name"
	n=1
	while [ "$n" -le "$2" ]; do
		echo 2 > "$d/pwm${n}_enable"
		if [ "${3:-}" = manual ]; then
			echo 90 > "$d/pwm$n"
		else
			for i in 1 2 3 4 5 6 7 8; do
				echo $((i * 20)) > "$d/pwm${n}_auto_point${i}_pwm"
				echo $((i * 10 + 20)) > "$d/pwm${n}_auto_point${i}_temp"
			done
		fi
		n=$((n + 1))
	done
	case "$1" in
		asus_custom_fan_curve) dmi "$R" "ASUSTeK COMPUTER INC." "ROG Ally RC71L" "RC71L" ;;
		oxp_ec|oxpec) dmi "$R" "ONE-NETBOOK" "ONEXPLAYER X1 A" "X1A" ;;
		orangepi) dmi "$R" "OrangePi" "NEO-01" "NEO-01" "OrangePi" ;;
		ayaneo_ec) dmi "$R" "AYANEO" "AYANEO 3" "AB09" ;;
		gpdfan) dmi "$R" "GPD" "G1618-05" "G1618-05" ;;
		zotac_*) dmi "$R" "ZOTAC" "ZOTAC GAMING ZONE" "G0A1W" ;;
		*) dmi "$R" "ONE-NETBOOK" "ONEXPLAYER X1 A" "X1A" ;;
	esac
	echo "$R"
}

# ASUS: eight points, temperatures written too, enable 1 = custom curve, 2 = factory
R="$(new_hw asus_custom_fan_curve 2)"; export GAMECOVE_ROOT="$R"; A="$R/sys/class/hwmon/hwmon3"
sh "$FIX" status | grep -q '^driver=asus_custom_fan_curve$' || fail "asus: driver in status"
sh "$FIX" status | grep -q '^modes=quiet,auto,max$' || fail "asus: modes in status"
sh "$FIX" set quiet >/dev/null || fail "asus: set quiet"
[ "$(cat "$A/pwm2_auto_point1_pwm") $(cat "$A/pwm2_auto_point8_pwm")" = "5 191" ] || fail "asus: quiet duty"
[ "$(cat "$A/pwm1_auto_point1_temp") $(cat "$A/pwm1_auto_point8_temp")" = "30 100" ] || fail "asus: curve temperatures"
[ "$(cat "$A/pwm1_enable")" = "1" ] || fail "asus: custom curve on"
sh "$FIX" set max >/dev/null || fail "asus: set max"
[ "$(cat "$A/pwm1_auto_point4_pwm")" = "255" ] || fail "asus: max duty"
sh "$FIX" set auto >/dev/null || fail "asus: set auto"
[ "$(cat "$A/pwm1_enable")" = "2" ] || fail "asus: factory curve"
sh "$FIX" remove >/dev/null || fail "asus: remove"
[ "$(cat "$A/pwm1_auto_point1_pwm") $(cat "$A/pwm1_auto_point1_temp")" = "20 30" ] || fail "asus: original curve back"
rm -rf "$R"

# traits: the Orange Pi Neo's fan is the same oxpec driver (board NEO-01 -> orange_pi_neo, hwmon oxp_ec)
R="$(new_hw orangepi 1 manual)"; export GAMECOVE_ROOT="$R"; O="$R/sys/class/hwmon/hwmon3"
echo oxp_ec > "$O/name"
sh "$FIX" status | grep -q '^applies=yes$' || fail "neo: the fan fix applies"
sh "$FIX" status | grep -q '^modes=auto,max$' || fail "neo: modes from oxp_ec"
sh "$FIX" set max >/dev/null || fail "neo: set max"
[ "$(cat "$O/pwm1_enable") $(cat "$O/pwm1")" = "1 255" ] || fail "neo: manual full duty"
sh "$FIX" remove >/dev/null || fail "neo: remove"
rm -rf "$R"

# OneXPlayer, oxpec 6.16+ (oxp_ec): manual only, no quiet, auto = 2
R="$(new_hw oxp_ec 1 manual)"; export GAMECOVE_ROOT="$R"; O="$R/sys/class/hwmon/hwmon3"
sh "$FIX" status | grep -q '^modes=auto,max$' || fail "oxp: modes"
set +e; sh "$FIX" set quiet 2>/dev/null; code=$?; set -e
[ "$code" = "2" ] || fail "oxp: quiet refused with exit 2 (got $code)"
[ ! -f "$R/var/lib/gamecove/fixes/fan/original" ] || fail "oxp: refused quiet installs nothing"
sh "$FIX" set max >/dev/null || fail "oxp: set max"
[ "$(cat "$O/pwm1_enable") $(cat "$O/pwm1")" = "1 255" ] || fail "oxp: manual full duty"
sh "$FIX" set auto >/dev/null || fail "oxp: set auto"
[ "$(cat "$O/pwm1_enable")" = "2" ] || fail "oxp: auto is 2 on oxp_ec"
sh "$FIX" set max >/dev/null
sh "$FIX" remove >/dev/null || fail "oxp: remove"
[ "$(cat "$O/pwm1_enable") $(cat "$O/pwm1")" = "2 90" ] || fail "oxp: original back"
rm -rf "$R"

# old oxp-sensors driver (oxpec): auto = 0
R="$(new_hw oxpec 1 manual)"; export GAMECOVE_ROOT="$R"; O="$R/sys/class/hwmon/hwmon3"
echo 0 > "$O/pwm1_enable"
sh "$FIX" set max >/dev/null || fail "oxpec: set max"
sh "$FIX" set auto >/dev/null || fail "oxpec: set auto"
[ "$(cat "$O/pwm1_enable")" = "0" ] || fail "oxpec: auto is 0 on the old driver"
rm -rf "$R"

# AYANEO, GPD, ZOTAC: manual drivers, auto = 2
for drv in ayaneo_ec gpdfan zotac_zone_platform; do
	R="$(new_hw "$drv" 1 manual)"; export GAMECOVE_ROOT="$R"; O="$R/sys/class/hwmon/hwmon3"
	sh "$FIX" set max >/dev/null || fail "$drv: set max"
	[ "$(cat "$O/pwm1_enable") $(cat "$O/pwm1")" = "1 255" ] || fail "$drv: full duty"
	sh "$FIX" set auto >/dev/null || fail "$drv: set auto"
	[ "$(cat "$O/pwm1_enable")" = "2" ] || fail "$drv: auto"
	sh "$FIX" status | tail -n 1 | grep -q '^state=on$' || fail "$drv: state=on"
	rm -rf "$R"
done

# an unknown hwmon is never touched
R="$(new_hw nct6775 1 manual)"; export GAMECOVE_ROOT="$R"
[ "$(sh "$FIX" status | tr '\n' ' ')" = "applies=no state=n/a " ] || fail "unknown hwmon ignored"
rm -rf "$R"
# ---- a set that fails halfway puts every fan back on automatic ----------------
R="$(new_hw msi_wmi_platform 2)"; export GAMECOVE_ROOT="$R"; M="$R/sys/class/hwmon/hwmon3"
dmi "$R" "Micro-Star International Co., Ltd." "Claw A1M" "MS-1T41"
rm -f "$M/pwm2_auto_point4_pwm"; mkdir "$M/pwm2_auto_point4_pwm"   # the kernel refuses this write
set +e; sh "$FIX" set quiet 2>/dev/null; code=$?; set -e
[ "$code" = "1" ] || fail "failing write -> exit 1 (got $code)"
[ "$(cat "$M/pwm1_enable") $(cat "$M/pwm2_enable")" = "2 2" ] || fail "failed set leaves both fans on automatic ($(cat "$M/pwm1_enable") $(cat "$M/pwm2_enable"))"
grep -q 'set failed' "$R/var/lib/gamecove/fixes/fan/changes.log" || fail "failed set logged"
[ ! -e "$R/run/gamecove-fan.lock" ] || fail "lock released after a failure"
rm -rf "$R"
R="$(new_hw oxp_ec 1 manual)"; export GAMECOVE_ROOT="$R"; O="$R/sys/class/hwmon/hwmon3"
rm -f "$O/pwm1"; mkdir "$O/pwm1"
set +e; sh "$FIX" set max 2>/dev/null; code=$?; set -e
[ "$code" = "1" ] || fail "oxp: failing duty write -> exit 1 (got $code)"
[ "$(cat "$O/pwm1_enable")" = "2" ] || fail "oxp: failed max goes back to automatic"
rm -rf "$R"

# ---- laptops with the same drivers are never touched -------------------------
R="$(new_hw msi_wmi_platform 2)"; export GAMECOVE_ROOT="$R"; M="$R/sys/class/hwmon/hwmon3"
dmi "$R" "Micro-Star International Co., Ltd." "Stealth 16 AI Studio A1VHG" "MS-15F2"
before="$(cat "$M/pwm1_enable") $(cat "$M/pwm1_auto_point2_pwm")"
[ "$(sh "$FIX" status | tr '\n' ' ')" = "applies=no state=n/a " ] || fail "MSI laptop: applies=no"
set +e; sh "$FIX" set max 2>/dev/null; code=$?; set -e
[ "$code" = "2" ] || fail "MSI laptop: set refused with exit 2 (got $code)"
[ "$(cat "$M/pwm1_enable") $(cat "$M/pwm1_auto_point2_pwm")" = "$before" ] || fail "MSI laptop: nothing written"
[ ! -e "$R/var/lib/gamecove/fixes/fan/original" ] || fail "MSI laptop: nothing recorded"
rm -rf "$R"
R="$(new_hw asus_custom_fan_curve 2)"; export GAMECOVE_ROOT="$R"
dmi "$R" "ASUSTeK COMPUTER INC." "ROG Zephyrus G14 GA403UV" "GA403UV"
set +e; sh "$FIX" set quiet 2>/dev/null; code=$?; set -e
[ "$code" = "2" ] || fail "ROG laptop: set refused (got $code)"
rm -rf "$R"
R="$(new_hw oxp_ec 1 manual)"; export GAMECOVE_ROOT="$R"
rm -rf "$R/sys/class/dmi"
set +e; sh "$FIX" set max 2>/dev/null; code=$?; set -e
[ "$code" = "2" ] || fail "no DMI ids: refused (got $code)"
rm -rf "$R"
# ---- one drive, two handhelds: each keeps its own saved fan state -------------
R="$(new_hw msi_wmi_platform 2)"; export GAMECOVE_ROOT="$R"; M="$R/sys/class/hwmon/hwmon3"
dmi "$R" "Micro-Star International Co., Ltd." "Claw 8 AI+ A2VM" "MS-1T91"
claw_orig="$(cat "$M/pwm1_auto_point2_pwm")"
sh "$FIX" set max >/dev/null || fail "two devices: set max on the Claw"
[ "$(cat "$R/var/lib/gamecove/fixes/fan/device")" = msi-claw-8-ex ] || fail "two devices: state owned by the Claw"
# Same drive in a ROG Ally: other DMI, other fan driver.
rm -rf "$M"; mkdir -p "$M"; echo asus_custom_fan_curve > "$M/name"
for n in 1 2; do echo 2 > "$M/pwm${n}_enable"; for i in 1 2 3 4 5 6 7 8; do echo 7 > "$M/pwm${n}_auto_point${i}_pwm"; echo 50 > "$M/pwm${n}_auto_point${i}_temp"; done; done
dmi "$R" "ASUSTeK COMPUTER INC." "ROG Ally RC71L_RC71L" "RC71L"
sh "$FIX" status | grep -q '^installed=no$' || fail "two devices: the Claw's state isn't the Ally's"
[ "$(sh "$FIX" remove)" = "nothing to undo" ] || fail "two devices: remove on the Ally leaves the Claw's values alone"
sh "$FIX" set max >/dev/null || fail "two devices: set max on the Ally"
sh "$FIX" remove >/dev/null || fail "two devices: remove on the Ally"
[ "$(cat "$M/pwm1_auto_point1_pwm") $(cat "$M/pwm1_enable")" = "7 2" ] || fail "two devices: the Ally gets its own values back"
# Back on the Claw: its saved state is there again.
rm -rf "$M"; cp -R "$HERE/../../app/tests/fixtures/power/sys_claw/sys/class/hwmon/hwmon5" "$M"
for n in 1 2; do echo 1 > "$M/pwm${n}_enable"; for i in 1 2 3 4 5 6; do echo 255 > "$M/pwm${n}_auto_point${i}_pwm"; done; done
dmi "$R" "Micro-Star International Co., Ltd." "Claw 8 AI+ A2VM" "MS-1T91"
sh "$FIX" status | grep -q '^installed=no$' && fail "two devices: status on the Claw sees its parked state"
sh "$FIX" remove >/dev/null || fail "two devices: remove on the Claw"
[ "$(cat "$M/pwm1_auto_point2_pwm")" = "$claw_orig" ] || fail "two devices: the Claw gets its own values back ($(cat "$M/pwm1_auto_point2_pwm") vs $claw_orig)"
rm -rf "$R"

# ---- custom curves (table drivers only), never quieter than Quiet, never falling --
R="$(new_hw msi_wmi_platform 2)"; export GAMECOVE_ROOT="$R"; M="$R/sys/class/hwmon/hwmon3"
dmi "$R" "Micro-Star International Co., Ltd." "Claw A1M" "MS-1T41"
sh "$FIX" set curve:0,40,50,60,80,100 >/dev/null || fail "msi: custom curve"
[ "$(cat "$M/pwm2_auto_point3_pwm") $(cat "$M/pwm2_auto_point6_pwm") $(cat "$M/pwm1_enable")" = "128 255 1" ] || fail "msi: curve written to both fans"
grep -q 'set curve 0 40 50 60 80 100' "$R/var/lib/gamecove/fixes/fan/changes.log" || fail "msi: curve logged"
before="$(cat "$M/pwm1_auto_point5_pwm")"
for bad in curve:0,40,40,45,59,75 curve:0,40,50,45,60,75 curve:0,40,40,45,60 curve:0,40,40,45,60,75,80 curve:0,40,40,45,60,101 curve:0,,40,45,60,75 curve:a,b curve: curve:0,040,040,045,060,075 curve:00,40,40,45,60,75; do
	set +e; sh "$FIX" set "$bad" 2>/dev/null; code=$?; set -e
	[ "$code" = "2" ] || fail "msi: $bad refused with exit 2 (got $code)"
done
[ "$(cat "$M/pwm1_auto_point5_pwm")" = "$before" ] || fail "msi: refused curves write nothing"
# review M1: "040" passes [ -ge 40 ] but is octal 32 in $((...)); leading zeros are refused (above)
sh "$FIX" set auto >/dev/null
rm -rf "$R"
R="$(new_hw asus_custom_fan_curve 2)"; export GAMECOVE_ROOT="$R"; A="$R/sys/class/hwmon/hwmon3"
sh "$FIX" set curve:10,20,30,40,60,80,90,100 >/dev/null || fail "asus: custom curve"
[ "$(cat "$A/pwm1_auto_point1_temp") $(cat "$A/pwm1_auto_point8_pwm")" = "30 255" ] || fail "asus: curve with temperatures"
rm -rf "$R"
R="$(new_hw oxp_ec 1 manual)"; export GAMECOVE_ROOT="$R"
set +e; sh "$FIX" set curve:50,60 2>/dev/null; code=$?; set -e
[ "$code" = "2" ] || fail "oxp: no curve on a one-duty driver (got $code)"
rm -rf "$R"
echo "fan: all passed"
