#!/bin/sh
# claw8ex-vrr against a fake root with stubbed rpm-ostree: the patch itself, the roundtrip, refusals.
# usage: sh fixes/claw8ex-vrr/tests/test.sh
# shellcheck disable=SC2016,SC2034 # ok() evals its single-quoted check later, on purpose
set -u
# shellcheck source=fixes/claw8ex-buttons/tests/lib.sh
. "$(dirname "$0")/../../claw8ex-buttons/tests/lib.sh"
HERE=$(cd "$(dirname "$0")" && pwd)
EDID_FILE=/etc/firmware/edid/gamecove-csw0801-30-120.bin

vrr_ready() {
	mkdir -p "$R/sys/class/drm/card1-eDP-1" "$R/sys/module/drm/parameters" "$R/sys/module/firmware_class/parameters"
	echo >"$R/sys/module/drm/parameters/edid_firmware"
	echo >"$R/sys/module/firmware_class/parameters/path"
	sh "$HERE/make-edid.sh" >"$R/sys/class/drm/card1-eDP-1/edid"
	sha=$("$REAL_SHA256SUM" "$R/sys/class/drm/card1-eDP-1/edid" | cut -d ' ' -f 1)
	echo "CSW0801 $sha 256 95,96,142,143 test panel" >"$T/panels.txt"
	export GAMECOVE_VRR_PANELS="$T/panels.txt"
}

# Independent check of the written EDID (Python, not the awk that made it).
check_patched() {
	python3 -I -c '
import sys
a, b = open(sys.argv[1], "rb").read(), open(sys.argv[2], "rb").read()
assert len(a) == len(b) == 256
changed = {i for i in range(256) if a[i] != b[i]}
assert changed <= {95, 142, 127, 254, 255}, changed
assert (b[95], b[96], b[142], b[143]) == (30, 120, 30, 120)
assert sum(b[0:128]) % 256 == 0 and sum(b[128:256]) % 256 == 0
assert sum(b[129:255]) % 256 == 0          # DisplayID section, which Linux validates
' "$1" "$2"
}

case_start awk_helpers
vrr_ready
E="$R/sys/class/drm/card1-eDP-1/edid"
ok '[ "$(od -An -v -tu1 "$E" | awk -f "$FIXES/claw8ex-vrr/edid.awk" -v mode=id)" = CSW0801 ]' "panel id"
ok '[ "$(od -An -v -tu1 "$E" | awk -f "$FIXES/claw8ex-vrr/edid.awk" -v mode=range)" = "48 120" ]' "factory range"
ok 'od -An -v -tu1 "$E" | awk -f "$FIXES/claw8ex-vrr/edid.awk" -v mode=check' "factory checksums valid"

# What modprobe does right before the GPU driver loads: run the hook (as installed in the fake root).
boot_hook() { GAMECOVE_ROOT=$R sh "$R/etc/gamecove/claw8ex-vrr/edid-hook.sh"; }
drm_param() { tr -d '\n' <"$R/sys/module/drm/parameters/edid_firmware"; }
fw_param() { tr -d '\n' <"$R/sys/module/firmware_class/parameters/path"; }

case_start roundtrip
vrr_ready
before=$(snapshot)
fix claw8ex-vrr install >"$T/out" 2>&1
rc=$?
ok "[ $rc -eq 0 ]" "install succeeds ($(tail -n 1 "$T/out"))"
ok '[ -f "$R$EDID_FILE" ]' "patched EDID written"
ok 'check_patched "$R/sys/class/drm/card1-eDP-1/edid" "$R$EDID_FILE"' "only range bytes and checksums changed, all valid"
ok 'grep -qxF "$EDID_FILE" "$FAKE/initramfs"' "EDID tracked in the initramfs"
for f in /etc/gamecove/claw8ex-vrr/edid.conf /etc/gamecove/claw8ex-vrr/edid-hook.sh /etc/modprobe.d/gamecove-claw8ex-vrr.conf; do
	ok "[ -f \"\$R$f\" ] && grep -qxF $f \"\$FAKE/initramfs\"" "$f written and tracked in the initramfs"
done
ok 'grep -qx "MS-1T91 eDP-1:edid/gamecove-csw0801-30-120.bin" "$R/etc/gamecove/claw8ex-vrr/edid.conf"' "hook keyed to this board"
ok 'grep -q "^install xe /bin/sh /etc/gamecove/claw8ex-vrr/edid-hook.sh || :; /sbin/modprobe --ignore-install xe \$CMDLINE_OPTS$" "$R/etc/modprobe.d/gamecove-claw8ex-vrr.conf"' "modprobe rule for xe"
ok 'grep -q "^install i915 " "$R/etc/modprobe.d/gamecove-claw8ex-vrr.conf"' "modprobe rule for i915"
ok '[ "$(karg_count firmware_class.path=/etc/firmware)" = 0 ]' "no firmware_class.path kernel argument"
ok '! grep -q "drm.edid_firmware" "$FAKE/kargs"' "no drm.edid_firmware kernel argument"
ok 'fix claw8ex-vrr status | grep -qx state=restart' "status: restart"
ok 'fix claw8ex-vrr status | grep -qx pending=yes' "status: pending"
# The next boot on the Claw: the hook sets the parameters, the kernel then shows the patched EDID.
boot_hook
ok '[ "$(drm_param)" = "eDP-1:edid/gamecove-csw0801-30-120.bin" ]' "on the Claw the hook sets drm.edid_firmware"
ok '[ "$(fw_param)" = /etc/firmware ]' "and the firmware search path"
cp "$R$EDID_FILE" "$R/sys/class/drm/card1-eDP-1/edid"
ok 'fix claw8ex-vrr status | grep -qx state=on' "status: on after restart"
ok 'fix claw8ex-vrr status | grep -qx range=30-120' "status: range 30-120"
ok 'fix claw8ex-vrr install | grep -q "already installed"' "second install is a no-op"
fix claw8ex-vrr remove >/dev/null
ok '[ "$(snapshot)" = "$before" ]' "remove restores the fake root, kernel arguments and initramfs"

case_start other_handheld_boots_same_drive
vrr_ready
fix claw8ex-vrr install >/dev/null 2>&1
kargs_before=$(cat "$FAKE/kargs")
# The same drive in a ROG Ally, then a Legion Go S: different board, AMD GPU, eDP panel too.
for b in RC71L 83L3; do
	echo "$b" >"$R/sys/class/dmi/id/board_name"
	echo >"$R/sys/module/drm/parameters/edid_firmware"
	echo >"$R/sys/module/firmware_class/parameters/path"
	boot_hook
	ok '[ -z "$(drm_param)" ]' "board $b: drm.edid_firmware untouched"
	ok '[ -z "$(fw_param)" ]' "board $b: firmware path untouched"
	ok '[ "$(cat "$FAKE/kargs")" = "$kargs_before" ]' "board $b: kernel arguments unchanged"
	ok 'fix claw8ex-vrr status | grep -qx applies=no' "board $b: status says it doesn't apply"
	snap=$(snapshot)
	fix claw8ex-vrr install >/dev/null 2>&1
	ok '[ "$(snapshot)" = "$snap" ]' "board $b: install changes nothing"
done
echo MS-1T91 >"$R/sys/class/dmi/id/board_name"
boot_hook
ok '[ "$(drm_param)" = "eDP-1:edid/gamecove-csw0801-30-120.bin" ]' "back on the Claw: applied again"

case_start hook_respects_others
vrr_ready
fix claw8ex-vrr install >/dev/null 2>&1
echo "eDP-1:edid/custom.bin" >"$R/sys/module/drm/parameters/edid_firmware"
boot_hook
ok '[ "$(drm_param)" = "eDP-1:edid/custom.bin" ]' "someone else's edid_firmware is kept"
echo >"$R/sys/module/drm/parameters/edid_firmware"
echo /opt/fw >"$R/sys/module/firmware_class/parameters/path"
boot_hook
ok '[ -z "$(drm_param)" ]' "another firmware path: hook does nothing"
echo >"$R/sys/module/firmware_class/parameters/path"
rm "$R$EDID_FILE"
boot_hook
ok '[ -z "$(drm_param)" ]' "EDID file missing: hook does nothing"
ok 'boot_hook' "hook always exits 0"

case_start refuses_other_modprobe_rule
vrr_ready
mkdir -p "$R/etc/modprobe.d"
echo "install xe /usr/bin/true" >"$R/etc/modprobe.d/local.conf"
before=$(snapshot)
ok '! fix claw8ex-vrr install 2>"$T/err"' "another install rule for xe is refused"
ok 'grep -q local.conf "$T/err"' "says which file"
ok '[ "$(snapshot)" = "$before" ]' "nothing written"

# An install made before the hook: EDID + initramfs + kernel arguments (what the old fix.sh did).
make_old_install() {
	fix claw8ex-vrr install >/dev/null 2>&1
	M=$R/var/lib/gamecove/fixes/claw8ex-vrr/manifest
	grep -v -e /etc/gamecove -e /etc/modprobe.d "$M" >"$M.tmp"
	mv "$M.tmp" "$M"
	grep -v -e /etc/gamecove -e /etc/modprobe.d "$FAKE/initramfs" >"$FAKE/i.tmp"
	mv "$FAKE/i.tmp" "$FAKE/initramfs"
	rm -r "$R/etc/gamecove" "$R/etc/modprobe.d"
	for a in firmware_class.path=/etc/firmware drm.edid_firmware=eDP-1:edid/gamecove-csw0801-30-120.bin; do
		echo "$a" >>"$FAKE/kargs"
		d=$R/var/lib/gamecove/kargs/$(printf '%s' "$a" | tr '/=:. ' '_____')
		mkdir -p "$d"
		: >"$d/claw8ex-vrr"
		echo "karg $a" >>"$M"
	done
}

case_start migrates_old_kernel_arguments
vrr_ready
before=$(snapshot)
make_old_install
ok 'fix claw8ex-vrr status | grep -qx old_kernel_args=no' "status as root migrates"
ok '! grep -q drm.edid_firmware "$FAKE/kargs"' "global drm.edid_firmware removed"
ok '[ "$(karg_count firmware_class.path=/etc/firmware)" = 0 ]' "firmware_class.path removed"
ok '[ -f "$R/etc/modprobe.d/gamecove-claw8ex-vrr.conf" ] && grep -qxF /etc/modprobe.d/gamecove-claw8ex-vrr.conf "$FAKE/initramfs"' "hook in place instead"
ok '[ -f "$R$EDID_FILE" ] && grep -qxF "$EDID_FILE" "$FAKE/initramfs"' "EDID kept"
ok 'fix claw8ex-vrr status | grep -qx installed=yes' "still installed"
fix claw8ex-vrr remove >/dev/null
ok '[ "$(snapshot)" = "$before" ]' "remove after migration restores everything"

case_start migrates_via_install
vrr_ready
make_old_install
ok 'fix claw8ex-vrr install 2>&1 | grep -q "moved from kernel arguments"' "install migrates too"
ok '! grep -q drm.edid_firmware "$FAKE/kargs"' "kernel argument gone"

case_start old_install_seen_from_another_handheld
vrr_ready
before=$(snapshot)
make_old_install
gyro_holder=$R/var/lib/gamecove/kargs/firmware_class_path__etc_firmware
: >"$gyro_holder/claw8ex-gyro"
echo RC71L >"$R/sys/class/dmi/id/board_name"
ok 'fix claw8ex-vrr status | grep -qx applies=no' "on the Ally: doesn't apply"
ok '! grep -q drm.edid_firmware "$FAKE/kargs"' "but the global EDID argument is removed there too"
ok '[ "$(karg_count firmware_class.path=/etc/firmware)" = 1 ]' "the gyro's firmware path stays"
ok '[ ! -e "$R$EDID_FILE" ] && ! grep -q gamecove "$FAKE/initramfs"' "the old install is undone"
ok '[ ! -e "$R/var/lib/gamecove/fixes/claw8ex-vrr" ]' "and forgotten"

case_start unknown_panel
vrr_ready
echo "CSW0801 0000000000000000000000000000000000000000000000000000000000000000 256 95,96,142,143 x" >"$T/panels.txt"
before=$(snapshot)
ok '! fix claw8ex-vrr install 2>"$T/err"' "an EDID that isn't the validated one is refused"
ok 'grep -q "validated" "$T/err"' "says why"
ok '[ "$(snapshot)" = "$before" ]' "nothing written"
: >"$T/panels.txt"
ok '! fix claw8ex-vrr install 2>/dev/null' "a panel not in the list is refused"
ok 'fix claw8ex-vrr status | grep -qx state=unsupported' "status: unsupported"
ok '[ "$(snapshot)" = "$before" ]' "nothing written"

case_start other_override
vrr_ready
echo "drm.edid_firmware=eDP-1:edid/custom.bin" >>"$FAKE/kargs"
before=$(snapshot)
ok '! fix claw8ex-vrr install 2>/dev/null' "someone else's EDID override is refused"
ok '[ "$(snapshot)" = "$before" ]' "nothing written"

case_start no_rpm_ostree
vrr_ready
rm "$BIN/rpm-ostree"
before=$(snapshot)
ok '! fix claw8ex-vrr install 2>/dev/null' "refused without rpm-ostree"
ok '[ "$(snapshot)" = "$before" ]' "nothing written"

case_start initramfs_failure_undoes
vrr_ready
before=$(snapshot)
export FAKE_FAIL=initramfs-etc
ok '! fix claw8ex-vrr install 2>/dev/null' "install fails when the initramfs can't be updated"
ok '[ "$(snapshot)" = "$before" ]' "file written before is taken away"
unset FAKE_FAIL

case_start remove_retries_only_what_failed
vrr_ready
before=$(snapshot)
fix claw8ex-vrr install >/dev/null 2>&1
export FAKE_FAIL=initramfs-etc
ok '! fix claw8ex-vrr remove >/dev/null 2>&1' "remove reports the failed step"
ok 'grep -qxF "initramfs $EDID_FILE" "$R/var/lib/gamecove/fixes/claw8ex-vrr/manifest"' "the failed step is left"
ok '[ -f "$R$EDID_FILE" ] && grep -qxF "file $EDID_FILE" "$R/var/lib/gamecove/fixes/claw8ex-vrr/manifest"' "the EDID it tracks stays, recorded"
ok '! grep -q "^karg " "$R/var/lib/gamecove/fixes/claw8ex-vrr/manifest"' "kernel arguments were undone"
ok '[ "$(karg_count firmware_class.path=/etc/firmware)" = 0 ]' "the rest was undone"
unset FAKE_FAIL
fix claw8ex-vrr remove >/dev/null
ok '[ "$(snapshot)" = "$before" ]' "second remove finishes the job"

case_start padded_128_byte_panel
mkdir -p "$R/sys/class/drm/card0-eDP-1"
python3 -I -c '
import sys
e = bytearray(128)
e[0:8] = b"\x00\xff\xff\xff\xff\xff\xff\x00"
v = ((ord("T") - 64) << 10) | ((ord("M") - 64) << 5) | (ord("A") - 64)
e[8], e[9], e[10], e[11] = v >> 8, v & 0xFF, 0x27, 0x20
e[93], e[95], e[96] = 0xFD, 48, 120
e[127] = (256 - sum(e[:127]) % 256) % 256
sys.stdout.buffer.write(bytes(e[:128]))
' >"$T/tma.bin"
sha=$("$REAL_SHA256SUM" "$T/tma.bin" | cut -d ' ' -f 1)
cat "$T/tma.bin" >"$R/sys/class/drm/card0-eDP-1/edid"
dd if=/dev/zero bs=128 count=1 2>/dev/null >>"$R/sys/class/drm/card0-eDP-1/edid"
echo "TMA2027 $sha 128 95,96 test" >"$T/panels.txt"
export GAMECOVE_VRR_PANELS="$T/panels.txt"
ok 'fix claw8ex-vrr install >/dev/null 2>&1' "zero-padded 128-byte EDID accepted"
ok '[ "$(wc -c <"$R/etc/firmware/edid/gamecove-tma2027-30-120.bin" | tr -d " ")" = 128 ]' "written at its own length"
ok '[ "$(od -An -v -tu1 "$R/etc/firmware/edid/gamecove-tma2027-30-120.bin" | awk -f "$FIXES/claw8ex-vrr/edid.awk" -v mode=range)" = "30 120" ]' "range 30-120"

finish
