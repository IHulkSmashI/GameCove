#!/bin/sh
# claw8ex-gyro against a fake root with stubbed rpm-ostree, systemctl, curl, unzip, sha256sum:
# firmware checked before anything is written, full roundtrip, coexistence with the buttons and VRR fixes.
# usage: sh fixes/claw8ex-gyro/tests/test.sh
# shellcheck disable=SC2016,SC2034 # ok() evals its single-quoted check later, on purpose
set -u
# shellcheck source=fixes/claw8ex-buttons/tests/lib.sh
. "$(dirname "$0")/../../claw8ex-buttons/tests/lib.sh"

FW_SHA=8194475367978c473d17e7e777fe196d99383f80f51b433927ea9afd0e9e661b
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
	export GAMECOVE_GYRO_BPF_OBJ="$T/fake.bpf.o" FAKE_SHA_NAME="ish_ptl.bin*" FAKE_SHA_VALUE=$FW_SHA
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
	mkdir -p "$R/sys/class/drm/card1-eDP-1"
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
ok '[ -f "$R/etc/firmware/intel/ish/ish_ptl.bin" ]' "firmware installed"
ok '[ "$(wc -c <"$R/etc/firmware/intel/ish/ish_ptl.bin" | tr -d " ")" = 432640 ]' "the verified file"
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
fix claw8ex-gyro set accel on >/dev/null
ok 'override | grep -q "name: accel_3d"' "accelerometer on"
fix claw8ex-gyro set accel off >/dev/null
ok '! override | grep -q "name: accel_3d"' "accelerometer off again"
fix claw8ex-gyro set accel on >/dev/null
fix claw8ex-gyro remove >/dev/null
ok '[ "$(snapshot)" = "$before" ]' "remove restores the fake root exactly (accelerometer was on)"
ok '[ ! -e "$FAKE/active/gamecove-gyro-bias.service" ]' "services stopped"

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

case_start shared_kernel_argument
gyro_ready
vrr_ready
before=$(snapshot)
fix claw8ex-gyro install >/dev/null 2>&1
fix claw8ex-vrr install >/dev/null 2>&1
ok '[ "$(karg_count firmware_class.path=/etc/firmware)" = 1 ]' "set once for both"
fix claw8ex-gyro remove >/dev/null
ok '[ "$(karg_count firmware_class.path=/etc/firmware)" = 1 ]' "kept while the VRR fix needs it"
fix claw8ex-vrr remove >/dev/null
ok '[ "$(karg_count firmware_class.path=/etc/firmware)" = 0 ]' "removed with the last holder"
ok '[ "$(snapshot)" = "$before" ]' "fake root restored"

case_start shared_kernel_argument_vrr_first
gyro_ready
vrr_ready
before=$(snapshot)
fix claw8ex-vrr install >/dev/null 2>&1
fix claw8ex-gyro install >/dev/null 2>&1
fix claw8ex-vrr remove >/dev/null
ok '[ "$(karg_count firmware_class.path=/etc/firmware)" = 1 ]' "kept while the gyro needs it"
fix claw8ex-gyro remove >/dev/null
ok '[ "$(snapshot)" = "$before" ]' "fake root restored"

case_start preexisting_kernel_argument
gyro_ready
echo "firmware_class.path=/etc/firmware" >>"$FAKE/kargs"
before=$(snapshot)
fix claw8ex-gyro install >/dev/null 2>&1
fix claw8ex-gyro remove >/dev/null
ok '[ "$(karg_count firmware_class.path=/etc/firmware)" = 1 ]' "an argument set by someone else stays"
ok '[ "$(snapshot)" = "$before" ]' "fake root restored"

finish
