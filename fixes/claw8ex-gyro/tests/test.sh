#!/bin/sh
# claw8ex-gyro against a fake root with stubbed rpm-ostree, systemctl, curl, unzip, sha256sum:
# firmware checked before anything is written, full roundtrip, coexistence with the buttons and VRR fixes.
# usage: sh fixes/claw8ex-gyro/tests/test.sh
# shellcheck disable=SC2016,SC2034 # ok() evals its single-quoted check later, on purpose
set -u
# shellcheck source=fixes/claw8ex-buttons/tests/lib.sh
. "$(dirname "$0")/../../claw8ex-buttons/tests/lib.sh"

FW_SHA=8194475367978c473d17e7e777fe196d99383f80f51b433927ea9afd0e9e661b
# review S1-6: the name the kernel's ISH loader tries for this vendor + product only (zlib CRC-32)
FWP=/etc/firmware/intel/ish/$(python3 -I -c 'import zlib; print("ish_ptl_%08x_%08x.bin" % (zlib.crc32(b"Micro-Star International Co., Ltd."), zlib.crc32(b"Claw 8 EX AI+ CG3EM")))')
GENERIC=/etc/firmware/intel/ish/ish_ptl.bin
MEMBER="ISH_Kit/Drivers/Win10/IshHeci/x64/FWImage/0004/ishS_SI_5.8.1.7782.bin"

# make_kit <size>: a zip shaped like MSI's kit, with a stand-in firmware of <size> bytes.
make_kit() {
	FAKE_KIT=$T/kit.zip
	python3 -I -c '
import sys, zipfile
with zipfile.ZipFile(sys.argv[1], "w") as z:
    z.writestr(sys.argv[2], b"\x5a" * int(sys.argv[3]))
    z.writestr("ISH_Kit/readme.txt", "x")
' "$FAKE_KIT" "$MEMBER" "$1"
	export FAKE_KIT
}

gyro_ready() {
	make_kit 432640
	echo BPF >"$T/fake.bpf.o"
	export GAMECOVE_GYRO_BPF_OBJ="$T/fake.bpf.o" FAKE_SHA_NAME="ish_ptl*.bin*" FAKE_SHA_VALUE=$FW_SHA
}

# The kernel side after a cold boot: argument on the command line, hub and gyro_3d present.
cold_boot() {
	echo "BOOT_IMAGE=/vmlinuz root=UUID=x quiet splash firmware_class.path=/etc/firmware" >"$R/proc/cmdline"
	mkdir -p "$R/sys/class/hidraw/hidraw3/device" "$R/sys/bus/iio/devices/iio:device1/buffer"
	echo "HID_ID=001F:00008087:00000AC2" >"$R/sys/class/hidraw/hidraw3/device/uevent"
	echo gyro_3d >"$R/sys/bus/iio/devices/iio:device1/name"
	echo 1 >"$R/sys/bus/iio/devices/iio:device1/buffer/enable"
}

# A synthetic EDID shaped like the Claw 8 panel's, registered as validated for the test.
vrr_ready() {
	mkdir -p "$R/sys/class/drm/card1-eDP-1" "$R/sys/module/drm/parameters"
	sh "$FIXES/claw8ex-vrr/tests/make-edid.sh" >"$R/sys/class/drm/card1-eDP-1/edid"
	sha=$("$REAL_SHA256SUM" "$R/sys/class/drm/card1-eDP-1/edid" | cut -d ' ' -f 1)
	echo "CSW0801 $sha 256 95,96,142,143 test panel" >"$T/panels.txt"
	export GAMECOVE_VRR_PANELS="$T/panels.txt"
}

case_start roundtrip
gyro_ready
before=$(snapshot)
fix claw8ex-gyro install >"$T/out" 2>&1
rc=$?
ok "[ $rc -eq 0 ]" "install succeeds ($(tail -n 1 "$T/out"))"
ok 'grep -q "cold boot" "$T/out"' "tells the user to cold boot"
ok '[ -f "$R$FWP" ]' "firmware installed"
ok '[ "$(wc -c <"$R$FWP" | tr -d " ")" = 432640 ]' "the verified file"
ok 'grep -qxF "$FWP" "$FAKE/initramfs"' "firmware tracked in the initramfs"
ok '[ -f "$R/etc/udev-hid-bpf/MSI__Claw-ISH-IMU.bpf.o" ]' "HID-BPF program installed"
ok '[ -x "$R/etc/gamecove/claw8ex-gyro/ish_gyro_bias.py" ]' "helpers installed"
ok 'grep -q "StateDirectory=ish-gyro-bias" "$R/etc/systemd/system/gamecove-gyro-bias.service"' "bias unit has its state dir"
ok '[ -e "$FAKE/active/gamecove-gyro-keepalive.service" ] && [ -e "$FAKE/active/gamecove-gyro-bias.service" ]' "services enabled"
ok '[ "$(karg_count firmware_class.path=/etc/firmware)" = 1 ]' "kernel argument set"
ok 'override | grep -q "name: gyro_3d"' "imu source in the override"
ok '! override | grep -q "name: accel_3d"' "accelerometer off by default"
ok 'override | grep -qx "capability_map_id: claw2"' "face-button map left as stock"
ok 'fix claw8ex-gyro status | grep -qx state=restart' "status: needs a cold boot"
cold_boot
ok 'fix claw8ex-gyro status | grep -qx state=on' "status: on after cold boot"
ok 'fix claw8ex-gyro status | grep -qx inputplumber_reading=yes' "status: InputPlumber reading"
fix claw8ex-gyro set accel-on >/dev/null
ok 'override | grep -q "name: accel_3d"' "accelerometer on"
ok 'fix claw8ex-gyro status | grep -qx accelerometer=yes' "status: accelerometer on"
fix claw8ex-gyro set accel-off >/dev/null
ok '! override | grep -q "name: accel_3d"' "accelerometer off again"
# review L4: the same value again changes nothing and doesn't restart InputPlumber; at most ten real
# changes per ten minutes (any local process can call this without a password)
restarts() { grep -c "systemctl restart inputplumber" "$FAKE/calls"; }
n0=$(restarts)
fix claw8ex-gyro set accel-off >/dev/null
ok '[ "$(restarts)" = "$n0" ]' "accel-off again: no InputPlumber restart"
rm -f "$R/run/gamecove/rate-claw8ex-gyro-accel"
i=0
while [ "$i" -lt 5 ]; do
	fix claw8ex-gyro set accel-on >/dev/null 2>&1
	fix claw8ex-gyro set accel-off >/dev/null 2>&1
	i=$((i + 1))
done
ok '[ "$(restarts)" = "$((n0 + 10))" ]' "ten changes, ten restarts"
ok '! fix claw8ex-gyro set accel-on 2>/dev/null' "the eleventh change in ten minutes is refused"
ok '[ "$(restarts)" = "$((n0 + 10))" ]' "no restart for the refused change"
ok '! override | grep -q "name: accel_3d"' "the refused change wrote nothing"
ok 'fix claw8ex-gyro set accel-off >/dev/null' "the current value is still accepted (a no-op)"
rm -f "$R/run/gamecove/rate-claw8ex-gyro-accel"
ok '! fix claw8ex-gyro set accel on 2>/dev/null' "old two-token form refused"
ok '! fix claw8ex-gyro set accel-maybe 2>/dev/null' "unknown value refused"
fix claw8ex-gyro set accel-on >/dev/null
fix claw8ex-gyro remove >/dev/null
ok '[ "$(snapshot)" = "$before" ]' "remove restores the fake root exactly (accelerometer was on)"
ok '[ ! -e "$FAKE/active/gamecove-gyro-bias.service" ]' "services stopped"

case_start through_the_dispatcher
# The app's path: pkexec gamecove-fix-set -> gamecove-fix -> fix.sh, values as single tokens.
gyro_ready
GF="$FIXES/../packaging/libexec/gamecove-fix"
GFS="$FIXES/../packaging/libexec/gamecove-fix-set"
disp() { GAMECOVE_FIXES_DIR="$FIXES" GAMECOVE_PATH="$BIN" sh "$@"; }
ok '! disp "$GFS" claw8ex-gyro set accel-on >/dev/null 2>&1' "accel-on refused before install"
ok '[ ! -e "$R/etc/inputplumber/devices.d/50-msi_claw8_ex_ai_cg3em.yaml" ]' "nothing written"
ok 'disp "$GF" claw8ex-gyro install >/dev/null 2>&1' "install through gamecove-fix"
ok 'disp "$GFS" claw8ex-gyro set accel-on >/dev/null 2>&1' "accel-on through gamecove-fix-set"
ok 'override | grep -q "name: accel_3d"' "accelerometer on"
ok 'grep -q "fix=claw8ex-gyro action=set value=accel-on result=ok" "$R/var/lib/gamecove/changes.log"' "logged by the dispatcher"
ok 'disp "$GF" claw8ex-gyro set accel-off >/dev/null 2>&1' "accel-off through gamecove-fix"
ok '! override | grep -q "name: accel_3d"' "accelerometer off"
ok '! disp "$GF" claw8ex-gyro set "accel on" >/dev/null 2>&1' "the dispatcher refuses a value with a space"
ok 'disp "$GFS" claw8ex-gyro status | grep -qx installed=yes' "status through gamecove-fix-set"
ok '! disp "$GFS" claw8ex-gyro remove >/dev/null 2>&1' "gamecove-fix-set refuses remove"
ok 'disp "$GF" claw8ex-gyro remove >/dev/null 2>&1' "remove through gamecove-fix"
ok '[ ! -e "$R$FWP" ]' "removed"

case_start firmware_only_for_this_model
gyro_ready
fix claw8ex-gyro install >/dev/null 2>&1
ok '[ ! -e "$R$GENERIC" ]' "never the generic ish_ptl.bin every Panther Lake machine would load"
ok 'case "$FWP" in */ish_ptl_[0-9a-f]*_[0-9a-f]*.bin) true ;; *) false ;; esac' "vendor + product name file"
ok '[ "$(python3 -I -c "import zlib; print(\"%08x\" % zlib.crc32(b\"123456789\"))")" = cbf43926 ]' "CRC-32 check value (kernel crc32(~0) ^ ~0)"
fix claw8ex-gyro remove >/dev/null 2>&1
# an install from before: generic name in the manifest and the initramfs; install / root status move it
before=$(snapshot)
fix claw8ex-gyro install >/dev/null 2>&1
M=$R/var/lib/gamecove/fixes/claw8ex-gyro/manifest
mv "$R$FWP" "$R$GENERIC"
sed -i "s|$FWP|$GENERIC|" "$M" "$FAKE/initramfs"
fix claw8ex-gyro status >/dev/null 2>&1
ok '[ -f "$R$FWP" ] && [ ! -e "$R$GENERIC" ]' "root status moves the firmware to the model-specific name"
ok 'grep -qxF "$FWP" "$FAKE/initramfs" && ! grep -qxF "$GENERIC" "$FAKE/initramfs"' "and the initramfs tracking"
ok '! grep -qF "$GENERIC" "$M"' "manifest follows"
fix claw8ex-gyro remove >/dev/null 2>&1
ok '[ "$(snapshot)" = "$before" ]' "remove after the move restores everything"
echo >"$R/sys/class/dmi/id/product_name"
ok '! fix claw8ex-gyro install 2>/dev/null' "no DMI product name: refused (can't scope the firmware)"

case_start karg_failure_keeps_firmware
gyro_ready
before=$(snapshot)
fix claw8ex-gyro install >/dev/null 2>&1
export FAKE_FAIL=kargs
ok '! fix claw8ex-gyro remove >/dev/null 2>&1' "remove reports the failed kernel argument"
ok '[ "$(karg_count firmware_class.path=/etc/firmware)" = 1 ]' "argument still set"
ok '[ -f "$R$FWP" ]' "firmware stays"
ok 'grep -qxF "$FWP" "$FAKE/initramfs"' "and stays in the initramfs"
ok 'grep -qxF "file $FWP" "$R/var/lib/gamecove/fixes/claw8ex-gyro/manifest"' "firmware still recorded"
ok '[ ! -e "$FAKE/active/gamecove-gyro-keepalive.service" ]' "services still stopped"
unset FAKE_FAIL
fix claw8ex-gyro remove >/dev/null 2>&1
ok '[ "$(snapshot)" = "$before" ]' "retry removes everything"

case_start initramfs_failure_undoes
gyro_ready
before=$(snapshot)
export FAKE_FAIL=initramfs-etc
ok '! fix claw8ex-gyro install 2>/dev/null' "install fails when the initramfs can't be updated"
ok '[ "$(snapshot)" = "$before" ]' "firmware written before is taken away"
unset FAKE_FAIL

case_start no_bpf_object
gyro_ready
export GAMECOVE_GYRO_BPF_OBJ="$T/missing.bpf.o"
ok '! fix claw8ex-gyro install 2>"$T/err"' "refused without the HID-BPF object"
ok 'grep -q "releases" "$T/err" && grep -q "build-bpf.sh" "$T/err"' "says how to get a build that has it"

case_start wrong_sha
make_kit 432640
echo BPF >"$T/fake.bpf.o"
export GAMECOVE_GYRO_BPF_OBJ="$T/fake.bpf.o"
before=$(snapshot)
ok '! fix claw8ex-gyro install 2>"$T/err"' "wrong sha256 refused"
ok 'grep -q "nothing was changed" "$T/err"' "says nothing changed"
ok '[ "$(snapshot)" = "$before" ]' "nothing written"
ok '! grep -q "rpm-ostree kargs --" "$FAKE/calls"' "no kernel argument touched"
ok '! grep -q systemctl "$FAKE/calls"' "no service touched"

case_start wrong_size
gyro_ready
make_kit 1000
before=$(snapshot)
ok '! fix claw8ex-gyro install 2>/dev/null' "wrong size refused even with a matching sha"
ok '[ "$(snapshot)" = "$before" ]' "nothing written"

case_start missing_member
gyro_ready
python3 -I -c 'import zipfile,sys; zipfile.ZipFile(sys.argv[1],"w").writestr("other.bin", b"x")' "$FAKE_KIT"
before=$(snapshot)
ok '! fix claw8ex-gyro install 2>/dev/null' "kit without the firmware refused"
ok '[ "$(snapshot)" = "$before" ]' "nothing written"

case_start other_board
gyro_ready
echo MS-1T52 >"$R/sys/class/dmi/id/board_name"
before=$(snapshot)
ok '! fix claw8ex-gyro install 2>/dev/null' "refused on another board"
ok '! grep -q curl "$FAKE/calls"' "nothing downloaded"
ok '[ "$(snapshot)" = "$before" ]' "nothing written"

case_start foreign_firmware_path
gyro_ready
echo "firmware_class.path=/opt/fw" >>"$FAKE/kargs"
before=$(snapshot)
ok '! fix claw8ex-gyro install 2>/dev/null' "someone else's firmware_class.path refused"
ok '[ "$(snapshot)" = "$before" ]' "nothing written"

case_start karg_failure_undoes
gyro_ready
before=$(snapshot)
export FAKE_FAIL=kargs
ok '! fix claw8ex-gyro install 2>/dev/null' "install fails when rpm-ostree fails"
ok '[ "$(snapshot)" = "$before" ]' "everything written before is undone"
unset FAKE_FAIL

case_start coexist_buttons_first
gyro_ready
before=$(snapshot)
fix claw8ex-buttons install >/dev/null
fix claw8ex-gyro install >/dev/null 2>&1
ok 'override | grep -qx "capability_map_id: gamecove_claw8ex"' "both: button map"
ok 'override | grep -q "name: gyro_3d"' "both: gyro"
fix claw8ex-buttons remove >/dev/null
ok 'override | grep -qx "capability_map_id: claw2"' "buttons removed: stock map back"
ok 'override | grep -q "name: gyro_3d"' "buttons removed: gyro kept"
fix claw8ex-gyro remove >/dev/null
ok '[ "$(snapshot)" = "$before" ]' "both removed: fake root restored"

case_start coexist_gyro_first
gyro_ready
before=$(snapshot)
fix claw8ex-gyro install >/dev/null 2>&1
fix claw8ex-buttons install >/dev/null
ok 'override | grep -qx "capability_map_id: gamecove_claw8ex"' "both: button map"
ok 'override | grep -q "name: gyro_3d"' "both: gyro"
fix claw8ex-gyro remove >/dev/null
ok '! override | grep -q "name: gyro_3d"' "gyro removed: imu gone"
ok 'override | grep -qx "capability_map_id: gamecove_claw8ex"' "gyro removed: button map kept"
fix claw8ex-buttons remove >/dev/null
ok '[ "$(snapshot)" = "$before" ]' "both removed: fake root restored"

case_start vrr_and_gyro_coexist
gyro_ready
vrr_ready
before=$(snapshot)
fix claw8ex-gyro install >/dev/null 2>&1
fix claw8ex-vrr install >/dev/null 2>&1
ok '[ "$(karg_count firmware_class.path=/etc/firmware)" = 1 ]' "set once (by the gyro; the VRR fix needs no kernel argument)"
fix claw8ex-gyro remove >/dev/null
ok '[ "$(karg_count firmware_class.path=/etc/firmware)" = 0 ]' "removed with the gyro"
ok '[ -f "$R/etc/firmware/edid/gamecove-csw0801-30-120.bin" ]' "the VRR fix's EDID stays in /etc/firmware"
fix claw8ex-vrr remove >/dev/null
ok '[ "$(snapshot)" = "$before" ]' "fake root restored"

case_start services_only_on_the_claw
gyro_ready
fix claw8ex-gyro install >/dev/null 2>&1
for u in gamecove-gyro-keepalive.service gamecove-gyro-bias.service; do
	ok "grep -qx 'ExecCondition=/usr/bin/grep -qx MS-1T91 /sys/class/dmi/id/board_name' \"\$R/etc/systemd/system/$u\"" "$u starts only on board MS-1T91"
done
# The unit's condition, run against another handheld's DMI and the Claw's (the command systemd runs).
cond() { sed -n 's|^ExecCondition=/usr/bin/grep -qx \([^ ]*\) /sys/class/dmi/id/board_name$|\1|p' "$R/etc/systemd/system/gamecove-gyro-keepalive.service"; }
echo RC71L >"$R/sys/class/dmi/id/board_name"
ok '! grep -qx "$(cond)" "$R/sys/class/dmi/id/board_name"' "ROG Ally: condition fails, so systemd skips the services"
echo MS-1T91 >"$R/sys/class/dmi/id/board_name"
ok 'grep -qx "$(cond)" "$R/sys/class/dmi/id/board_name"' "Claw: condition passes"
echo RC71L >"$R/sys/class/dmi/id/board_name"
snap=$(snapshot)
ok 'fix claw8ex-gyro status | grep -qx applies=no' "ROG Ally: status says it doesn't apply"
ok '! fix claw8ex-gyro install 2>/dev/null' "ROG Ally: install refused"
ok '[ "$(snapshot)" = "$snap" ]' "ROG Ally: nothing changed"

case_start old_units_get_the_board_check
gyro_ready
before=$(snapshot)
fix claw8ex-gyro install >/dev/null 2>&1
for u in gamecove-gyro-keepalive.service gamecove-gyro-bias.service; do
	grep -v '^ExecCondition=' "$R/etc/systemd/system/$u" >"$T/u" && cat "$T/u" >"$R/etc/systemd/system/$u"
done
fix claw8ex-gyro status >/dev/null 2>&1
ok 'grep -q "^ExecCondition=" "$R/etc/systemd/system/gamecove-gyro-keepalive.service"' "status (root) adds the board check to an old install"
ok 'grep -q "^ExecCondition=" "$R/etc/systemd/system/gamecove-gyro-bias.service"' "both services"
fix claw8ex-gyro remove >/dev/null
ok '[ "$(snapshot)" = "$before" ]' "remove still restores everything"

case_start preexisting_kernel_argument
gyro_ready
echo "firmware_class.path=/etc/firmware" >>"$FAKE/kargs"
before=$(snapshot)
fix claw8ex-gyro install >/dev/null 2>&1
fix claw8ex-gyro remove >/dev/null
ok '[ "$(karg_count firmware_class.path=/etc/firmware)" = 1 ]' "an argument set by someone else stays"
ok '[ "$(snapshot)" = "$before" ]' "fake root restored"

finish
