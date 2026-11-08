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
	mkdir -p "$R/sys/class/drm/card1-eDP-1"
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

case_start roundtrip
vrr_ready
before=$(snapshot)
fix claw8ex-vrr install >"$T/out" 2>&1
rc=$?
ok "[ $rc -eq 0 ]" "install succeeds ($(tail -n 1 "$T/out"))"
ok '[ -f "$R$EDID_FILE" ]' "patched EDID written"
ok 'check_patched "$R/sys/class/drm/card1-eDP-1/edid" "$R$EDID_FILE"' "only range bytes and checksums changed, all valid"
ok 'grep -qxF "$EDID_FILE" "$FAKE/initramfs"' "tracked in the initramfs"
ok '[ "$(karg_count firmware_class.path=/etc/firmware)" = 1 ]' "firmware_class.path set"
ok '[ "$(karg_count drm.edid_firmware=eDP-1:edid/gamecove-csw0801-30-120.bin)" = 1 ]' "drm.edid_firmware set"
ok 'fix claw8ex-vrr status | grep -qx state=restart' "status: restart"
ok 'fix claw8ex-vrr status | grep -qx pending=yes' "status: pending"
# After the restart the kernel shows the patched EDID and has the argument.
cp "$R/sys/class/drm/card1-eDP-1/edid" "$T/factory.bin"
cp "$R$EDID_FILE" "$R/sys/class/drm/card1-eDP-1/edid"
echo "BOOT_IMAGE=/vmlinuz quiet drm.edid_firmware=eDP-1:edid/gamecove-csw0801-30-120.bin" >"$R/proc/cmdline"
ok 'fix claw8ex-vrr status | grep -qx state=on' "status: on after restart"
ok 'fix claw8ex-vrr status | grep -qx range=30-120' "status: range 30-120"
fix claw8ex-vrr remove >/dev/null
ok '[ "$(snapshot)" = "$before" ]' "remove restores the fake root, kernel arguments and initramfs"

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

case_start karg_failure_keeps_edid
vrr_ready
before=$(snapshot)
fix claw8ex-vrr install >/dev/null 2>&1
export FAKE_FAIL=kargs
ok '! fix claw8ex-vrr remove >/dev/null 2>&1' "remove reports the failed kernel argument"
ok '[ "$(karg_count drm.edid_firmware=eDP-1:edid/gamecove-csw0801-30-120.bin)" = 1 ]' "argument still set"
ok '[ -f "$R$EDID_FILE" ]' "so the EDID it points at stays"
ok 'grep -qxF "$EDID_FILE" "$FAKE/initramfs"' "and stays in the initramfs"
ok 'grep -qxF "file $EDID_FILE" "$R/var/lib/gamecove/fixes/claw8ex-vrr/manifest"' "file still recorded"
ok 'grep -qxF "initramfs $EDID_FILE" "$R/var/lib/gamecove/fixes/claw8ex-vrr/manifest"' "initramfs tracking still recorded"
ok 'grep -q "^karg drm.edid_firmware=" "$R/var/lib/gamecove/fixes/claw8ex-vrr/manifest"' "argument still recorded"
ok 'fix claw8ex-vrr status | grep -qx installed=yes' "status: still installed"
unset FAKE_FAIL
fix claw8ex-vrr remove >/dev/null
ok '[ "$(snapshot)" = "$before" ]' "retry removes everything"

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
