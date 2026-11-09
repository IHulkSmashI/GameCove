#!/bin/sh
# shellcheck disable=SC2034 # the device variables are read by the checks t_common evals
# ally-mcu-powersave against fake roots (never the real system).
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
FIX="$HERE/fix.sh"
T_NAME=ally-mcu-powersave
T_PATH0=$PATH
# shellcheck source=fixes/lib/tests/gcfix-testlib.sh
. "$HERE/../lib/tests/gcfix-testlib.sh"
RULE=/etc/udev/rules.d/60-gamecove-ally-mcu-powersave.rules
N=""
MCU_DIR=$(mktemp -d)
trap 'rm -rf "$MCU_DIR"' EXIT
printf 'model=ally\nversion=319\nmin=319\n' >"$MCU_DIR/ok"
printf 'model=ally\nversion=318\nmin=319\n' >"$MCU_DIR/old"
printf 'model=ally-x\nversion=313\nmin=314\n' >"$MCU_DIR/old-x"
printf 'error=couldn'"'"'t ask the MCU (Permission denied)\n' >"$MCU_DIR/err"
export GAMECOVE_TEST_MCU_INFO="$MCU_DIR/ok"
ally() {
	t_dmi "ASUSTeK COMPUTER INC." "ROG Ally RC71L_RC71L" "RC71L"
	mkdir -p "$R/sys/class/firmware-attributes/asus-armoury/attributes/mcu_powersave"
	N="$R/sys/class/firmware-attributes/asus-armoury/attributes/mcu_powersave/current_value"
	echo 0 >"$N"
}
laptop() {
	t_dmi "ASUSTeK COMPUTER INC." "ROG Zephyrus G14 GA403UV" "GA403UV"
	mkdir -p "$R/sys/devices/platform/asus-nb-wmi"
	echo 0 >"$R/sys/devices/platform/asus-nb-wmi/mcu_powersave"
}
t_common "$RULE" ally laptop '[ "$(cat "$N")" = 1 ]' '[ "$(cat "$N")" = 0 ]'
# older kernels: the asus-wmi switch
t_new
t_dmi "ASUSTeK COMPUTER INC." "ROG Ally X RC72LA_RC72LA" "RC72LA"
mkdir -p "$R/sys/devices/platform/asus-nb-wmi"
echo 0 >"$R/sys/devices/platform/asus-nb-wmi/mcu_powersave"
sh "$FIX" install >/dev/null
t_check '[ "$(cat "$R/sys/devices/platform/asus-nb-wmi/mcu_powersave")" = 1 ]' "legacy asus-wmi switch set"
sh "$FIX" remove >/dev/null
t_check '[ "$(cat "$R/sys/devices/platform/asus-nb-wmi/mcu_powersave")" = 0 ]' "legacy switch put back"
t_new
ally
echo 1 >"$N"
t_check '[ "$(t_state)" = os-fixed ]' "already on: os-fixed"
t_new
t_dmi "ASUSTeK COMPUTER INC." "ROG Ally RC71L_RC71L" "RC71L"
t_check '[ "$(t_state)" = not-needed ]' "no MCU switch in this kernel: not-needed"
# review S1-3: never with old or unknown MCU firmware; status says why
for f in old old-x err; do
	t_new
	ally
	export GAMECOVE_TEST_MCU_INFO="$MCU_DIR/$f"
	t_check '[ "$(t_state)" = unsupported ]' "$f firmware: unsupported"
	t_check 'sh "$FIX" status | grep -q "^reason=not available: "' "$f firmware: reason given"
	set +e
	sh "$FIX" install >/dev/null 2>&1
	rc=$?
	set -e
	t_check '[ "$rc" = 3 ]' "$f firmware: install refused (exit 3)"
	t_check '[ ! -e "$R$RULE" ]' "$f firmware: no udev rule"
	t_check '[ "$(cat "$N")" = 0 ]' "$f firmware: switch untouched"
done
export GAMECOVE_TEST_MCU_INFO="$MCU_DIR/old-x"
t_check 'sh "$FIX" status | grep -q "older than 314"' "Ally X minimum 314"
t_new
ally
export GAMECOVE_TEST_MCU_INFO="$MCU_DIR/ok"
t_check 'sh "$FIX" install >/dev/null' "new enough firmware: installs"
t_check '[ "$(cat "$N")" = 1 ]' "and turns it on"
# never automatic: no "auto" selector in the catalogue
t_check 'python3 -I -c "import json,sys; f=[x for x in json.load(open(sys.argv[1]))[\"fixes\"] if x[\"id\"]==\"ally-mcu-powersave\"][0]; sys.exit(1 if f.get(\"auto\") else 0)" "$HERE/../../app/data/fixes.json"' "not auto-applied anywhere"
t_check 'python3 -I "$HERE/tests/test_mcu_version.py" >/dev/null 2>&1' "mcu_version.py unit tests"
t_end
