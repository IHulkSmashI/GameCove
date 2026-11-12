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
# The next boot uses the deployment's kernel arguments (the fake rpm-ostree's list).
boot_hook() {
	printf 'BOOT_IMAGE=/vmlinuz %s\n' "$(tr '\n' ' ' <"$FAKE/kargs")" >"$R/proc/cmdline"
	GAMECOVE_ROOT=$R sh "$R/etc/gamecove/claw8ex-vrr/edid-hook.sh"
}
# A boot whose command line is given (the previous boot entry, or one edited at the boot menu).
boot_hook_with() {
	printf '%s\n' "$1" >"$R/proc/cmdline"
	GAMECOVE_ROOT=$R sh "$R/etc/gamecove/claw8ex-vrr/edid-hook.sh"
}
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

# review S1-5: the previous boot entry is clean, and there is a kill switch at the boot menu
case_start rollback_and_kill_switch
vrr_ready
fix claw8ex-vrr install >/dev/null 2>&1
ok 'grep -qx "gamecove.vrr=1" "$FAKE/kargs"' "install adds the gamecove.vrr=1 switch to the new boot entry"
ok 'fix claw8ex-vrr status | grep -qx boot_switch=yes' "status: boot switch set"
boot_hook_with "BOOT_IMAGE=/vmlinuz root=UUID=x quiet splash"
ok '[ -z "$(drm_param)" ]' "previous boot entry (no gamecove.vrr=1): panel's own EDID, even with the hook in /etc"
boot_hook_with "BOOT_IMAGE=/vmlinuz root=UUID=x gamecove.vrr=1 gamecove.novrr"
ok '[ -z "$(drm_param)" ]' "gamecove.novrr at the boot menu: off for that boot"
ok 'fix claw8ex-vrr status | grep -qx kill_switch=on' "status: kill switch on"
boot_hook_with "BOOT_IMAGE=/vmlinuz gamecove.novrr=1 gamecove.vrr=1"
ok '[ -z "$(drm_param)" ]' "gamecove.novrr=<anything> works too"
boot_hook_with "BOOT_IMAGE=/vmlinuz root=UUID=x gamecove.vrr=1"
ok '[ "$(drm_param)" = "eDP-1:edid/gamecove-csw0801-30-120.bin" ]' "with the switch: applied"
fix claw8ex-vrr remove >/dev/null
ok '! grep -qx "gamecove.vrr=1" "$FAKE/kargs"' "remove takes the switch out"
# an install from before the switch gets it on the next install / root status, never treated as an old karg
fix claw8ex-vrr install >/dev/null 2>&1
M=$R/var/lib/gamecove/fixes/claw8ex-vrr/manifest
grep -v "^marker " "$M" >"$M.tmp"
mv "$M.tmp" "$M"
grep -vx "gamecove.vrr=1" "$FAKE/kargs" >"$FAKE/k.tmp"
mv "$FAKE/k.tmp" "$FAKE/kargs"
rm -rf "$R/var/lib/gamecove/kargs/gamecove_vrr_1"
fix claw8ex-vrr status >/dev/null 2>&1
ok 'grep -qx "gamecove.vrr=1" "$FAKE/kargs" && grep -qx "marker gamecove.vrr=1" "$M"' "root status adds the switch to an older install"
fix claw8ex-vrr status >/dev/null 2>&1
ok '[ "$(karg_count gamecove.vrr=1)" = 1 ]' "only once"
fix claw8ex-vrr remove >/dev/null

# review Medium (Fixes): `update` on an active fix removed it and then failed (install can't validate the factory EDID
# while the patched one is what the screen reports), leaving the screen without VRR until a restart
case_start update_while_active
vrr_ready
fix claw8ex-vrr install >/dev/null 2>&1
cp "$R/sys/class/drm/card1-eDP-1/edid" "$T/factory.edid"
cp "$R$EDID_FILE" "$R/sys/class/drm/card1-eDP-1/edid"      # after the restart: the screen reports our EDID
boot_hook   # the boot hook hands the driver the EDID
echo "# an older hook" >"$R/etc/gamecove/claw8ex-vrr/edid-hook.sh"
ok 'fix claw8ex-vrr status | grep -qx state=on' "the fix is active"
ok 'fix claw8ex-vrr update >"$T/out" 2>&1' "update succeeds while active ($(tail -n 1 "$T/out" 2>/dev/null))"
ok '[ "$(tail -n 1 "$T/out")" = updated ]' "says updated"
ok 'cmp -s "$HERE/../edid-hook.sh" "$R/etc/gamecove/claw8ex-vrr/edid-hook.sh"' "the hook is this revision's"
ok '[ -f "$R$EDID_FILE" ] && fix claw8ex-vrr status | grep -qx installed=yes && fix claw8ex-vrr status | grep -qx state=on' "still installed and on (not removed)"
ok '[ -f "$R/etc/modprobe.d/gamecove-claw8ex-vrr.conf" ] && grep -qx "gamecove.vrr=1" "$FAKE/kargs"' "modprobe rule and boot switch in place"
fix claw8ex-vrr remove >/dev/null 2>&1
# review 4-L3: an install cut short (the record is there, the boot hook is not) is not "already installed"
case_start install_cut_short
vrr_ready
fix claw8ex-vrr install >/dev/null 2>&1
rm -f "$R/etc/gamecove/claw8ex-vrr/edid-hook.sh" "$R/etc/gamecove/claw8ex-vrr/edid.conf"
ok 'fix claw8ex-vrr install >"$T/out" 2>&1' "install after a cut-short one succeeds ($(tail -n 1 "$T/out" 2>/dev/null))"
ok '! grep -q "already installed" "$T/out"' "and does not claim it was already installed"
ok '[ -f "$R/etc/gamecove/claw8ex-vrr/edid-hook.sh" ] && [ -f "$R$EDID_FILE" ]' "the hook and the EDID are in place"
fix claw8ex-vrr remove >/dev/null 2>&1

# an older EDID is active and can't be rebuilt: nothing is changed
case_start update_refuses_when_it_cannot_rebuild
vrr_ready
fix claw8ex-vrr install >/dev/null 2>&1
cp "$R$EDID_FILE" "$T/patched.edid"
cp "$R/sys/class/drm/card1-eDP-1/edid" "$R$EDID_FILE"      # the installed file is not this range (an older revision's)
cp "$T/patched.edid" "$R/sys/class/drm/card1-eDP-1/edid"   # and the screen runs a 30-120 EDID
before=$(snapshot)
ok '! fix claw8ex-vrr update >"$T/out" 2>&1' "refused"
ok 'grep -q "nothing was changed" "$T/out"' "says nothing was changed"
ok '[ "$(snapshot)" = "$before" ]' "and nothing was"
fix claw8ex-vrr remove >/dev/null 2>&1

# review Low (Fixes): after a revision that changes the range, the screen runs the OLD patched range: that is not this
# revision's range, and `update` used to take the fix out and then fail to install it again
case_start update_refuses_when_an_older_range_is_active
vrr_ready
fix claw8ex-vrr install >/dev/null 2>&1
python3 -I -c '
import sys
b = bytearray(open(sys.argv[1], "rb").read())
b[95] = 40
b[142] = 40
b[127] = (256 - sum(b[:127]) % 256) % 256
b[254] = (256 - sum(b[129:254]) % 256) % 256
b[255] = (256 - sum(b[128:255]) % 256) % 256
open(sys.argv[2], "wb").write(b)
' "$R$EDID_FILE" "$T/older.edid"
cp "$T/older.edid" "$R$EDID_FILE"                          # an older revision wrote 40-120
cp "$T/older.edid" "$R/sys/class/drm/card1-eDP-1/edid"     # and the screen runs it
before=$(snapshot)
ok '! fix claw8ex-vrr update >"$T/out" 2>&1' "refused"
ok 'grep -q "nothing was changed" "$T/out"' "says nothing was changed"
ok '[ "$(snapshot)" = "$before" ]' "and nothing was: the fix is not taken out"
ok 'fix claw8ex-vrr status | grep -qx installed=yes' "still installed"
fix claw8ex-vrr remove >/dev/null 2>&1

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

# ---- SteamOS: no rpm-ostree; the switch on one marked line in /etc/default/grub, update-grub, a keep list --------
GRUB=/etc/default/grub
KEEP=/etc/atomic-update.conf.d/gamecove-claw8ex-vrr.conf
steamos_ready() {
	vrr_ready
	rm "$BIN/rpm-ostree"
	printf 'NAME="SteamOS"\nID=steamos\nID_LIKE=arch\nVERSION_ID=3.9.5\n' >"$R/etc/os-release"
	mkdir -p "$R/etc/default" "$R/etc/atomic-update.conf.d" "$R/efi/EFI/SteamOS" "$R/sys/bus/pci/drivers/xe" "$R/sys/class/drm/card1/device"
	ln -s "$R/sys/bus/pci/drivers/xe" "$R/sys/class/drm/card1/device/driver"
	printf 'GRUB_DEFAULT=0\nGRUB_TIMEOUT=0\nGRUB_CMDLINE_LINUX_DEFAULT="quiet splash"\n' >"$R$GRUB"
	chmod 0644 "$R$GRUB"
	# Holo's update-grub: grub-mkconfig sources /etc/default/grub and writes SteamOS's grub.cfg
	cat >"$BIN/update-grub" <<'EOF'
#!/bin/sh
echo "update-grub" >>"$FAKE/calls"
[ "${FAKE_FAIL:-}" = update-grub ] && exit 1
GRUB_CMDLINE_LINUX_DEFAULT=
. "$GAMECOVE_ROOT/etc/default/grub"
[ "${FAKE_GRUB_DROPS:-}" = 1 ] && GRUB_CMDLINE_LINUX_DEFAULT="quiet splash"
printf 'menuentry "SteamOS" {\n  linux /boot/vmlinuz-linux-neptune-612 root=UUID=x %s\n}\n' "$GRUB_CMDLINE_LINUX_DEFAULT" >"$GAMECOVE_ROOT/efi/EFI/SteamOS/grub.cfg"
EOF
	chmod +x "$BIN/update-grub"
	update-grub
	: >"$FAKE/calls"
	echo "BOOT_IMAGE=/boot/vmlinuz-linux-neptune-612 root=UUID=x quiet splash" >"$R/proc/cmdline"
}
# Boot SteamOS from its grub.cfg: the hook runs with that command line.
steamos_boot() {
	sed -n 's/^ *linux \/boot\/vmlinuz-linux-neptune-612 /BOOT_IMAGE=\/boot\/vmlinuz-linux-neptune-612 /p' "$R/efi/EFI/SteamOS/grub.cfg" >"$R/proc/cmdline"
	GAMECOVE_ROOT=$R sh "$R/etc/gamecove/claw8ex-vrr/edid-hook.sh"
}
# A SteamOS update: Valve's new grub file (no line of ours), its boot menu rebuilt; only keep-listed /etc files stay,
# and /var is the new slot's own (review High 9: the record in /var/lib/gamecove was gone, refresh found nothing to do).
steamos_update() {
	rm -rf "$R/var/lib/gamecove"
	if [ -f "$R$KEEP" ]; then
		for f in $(cd "$R" && find etc/gamecove -type f 2>/dev/null); do
			grep -qxF "/$f" "$R$KEEP" || rm -f "$R/$f"
		done
	fi
	printf 'GRUB_DEFAULT=0\nGRUB_TIMEOUT=0\nGRUB_CMDLINE_LINUX_DEFAULT="quiet splash amd_iommu=off"\n' >"$R$GRUB"
	update-grub
	[ "${1:-}" = drop-hook ] && rm -f "$R/etc/modprobe.d/gamecove-claw8ex-vrr.conf"
	echo "BOOT_IMAGE=/boot/vmlinuz-linux-neptune-612 root=UUID=x quiet splash amd_iommu=off" >"$R/proc/cmdline"
	echo >"$R/sys/module/drm/parameters/edid_firmware"
	echo >"$R/sys/module/firmware_class/parameters/path"
	sh "$HERE/make-edid.sh" >"$R/sys/class/drm/card1-eDP-1/edid"
}

case_start steamos_roundtrip
steamos_ready
before=$(snapshot)
fix claw8ex-vrr install >"$T/out" 2>&1
rc=$?
ok "[ $rc -eq 0 ]" "SteamOS: install succeeds ($(tail -n 1 "$T/out"))"
ok 'check_patched "$R/sys/class/drm/card1-eDP-1/edid" "$R$EDID_FILE"' "the same patched EDID"
for f in /etc/gamecove/claw8ex-vrr/edid.conf /etc/gamecove/claw8ex-vrr/edid-hook.sh /etc/modprobe.d/gamecove-claw8ex-vrr.conf; do
	ok "[ -f \"\$R$f\" ]" "$f written"
done
ok '[ ! -s "$FAKE/initramfs" ] && ! grep -q rpm-ostree "$FAKE/calls"' "no initramfs step (the driver starts after /etc)"
ok '[ "$(grep -c "# GameCove claw8ex-vrr" "$R$GRUB")" = 1 ]' "one marked line in /etc/default/grub"
ok 'grep -qx "GRUB_CMDLINE_LINUX_DEFAULT=\"\${GRUB_CMDLINE_LINUX_DEFAULT} gamecove.vrr=1\"  # GameCove claw8ex-vrr" "$R$GRUB"' "only the switch, appended to SteamOS's own arguments"
ok 'grep -q "GRUB_CMDLINE_LINUX_DEFAULT=\"quiet splash\"$" "$R$GRUB"' "SteamOS's own line untouched"
ok '[ "$(stat -c %a "$R$GRUB")" = 644 ]' "grub file keeps its mode"
ok 'grep -q "quiet splash gamecove.vrr=1" "$R/efi/EFI/SteamOS/grub.cfg"' "update-grub put it in SteamOS's boot menu"
ok '! grep -q "drm.edid_firmware\|firmware_class" "$R$GRUB"' "no global EDID argument (the hook is per board)"
ok 'grep -qx "/etc/firmware/edid/gamecove-\*.bin" "$R$KEEP" && grep -qx /etc/modprobe.d/gamecove-claw8ex-vrr.conf "$R$KEEP" && grep -qx /etc/gamecove/claw8ex-vrr/edid-hook.sh "$R$KEEP" && grep -qx /etc/gamecove/claw8ex-vrr/edid.conf "$R$KEEP"' "keep list: the fix's own files"
ok '! grep -q "^/etc/default/grub" "$R$KEEP"' "never Valve's grub file"
ok 'fix claw8ex-vrr status | grep -qx boot=steamos' "status: boot=steamos"
ok 'fix claw8ex-vrr status | grep -qx state=restart && fix claw8ex-vrr status | grep -qx pending=yes' "status: restart, pending"
steamos_boot
ok '[ "$(drm_param)" = "eDP-1:edid/gamecove-csw0801-30-120.bin" ]' "next boot: the hook hands the driver the corrected EDID"
cp "$R$EDID_FILE" "$R/sys/class/drm/card1-eDP-1/edid"
ok 'fix claw8ex-vrr status | grep -qx state=on' "status: on"
ok '[ "$(fix claw8ex-vrr set refresh)" = "already in place" ]' "refresh with the line in place: nothing to do"
fix claw8ex-vrr remove >/dev/null 2>&1
ok '! grep -q GameCove "$R$GRUB" && ! grep -q gamecove "$R/efi/EFI/SteamOS/grub.cfg"' "remove: line and boot menu entry gone"
ok '[ ! -e "$R$KEEP" ]' "remove: keep list gone"
ok '[ "$(snapshot)" = "$before" ]' "remove: back to exactly how it was"

case_start steamos_after_update
steamos_ready
fix claw8ex-vrr install >/dev/null 2>&1
ok '[ ! -e "$R/var/lib/gamecove/fixes/claw8ex-vrr" ] && [ -s "$R/etc/gamecove/claw8ex-vrr/record/manifest" ]' "SteamOS: the record is in /etc, not in the per-slot /var (High 9)"
ok 'grep -qx /etc/gamecove/claw8ex-vrr/record/manifest "$R$KEEP" && grep -qx "$KEEP" "$R$KEEP"' "and on the keep list, with the keep list itself"
steamos_update
ok '[ -s "$R/etc/gamecove/claw8ex-vrr/record/manifest" ]' "the record survived the update"
ok 'fix claw8ex-vrr status | grep -qx installed=yes' "still installed after the update"
ok 'fix claw8ex-vrr status | grep -qx after_update=yes' "after an update: status says the line is gone"
ok 'fix claw8ex-vrr status | grep -qx state=restart && fix claw8ex-vrr status | grep -qx pending=no' "not pending until it is back"
ok 'fix claw8ex-vrr set refresh | grep -q "put back after the SteamOS update"' "refresh puts it back"
ok 'grep -q "amd_iommu=off" "$R$GRUB" && [ "$(grep -c "# GameCove claw8ex-vrr" "$R$GRUB")" = 1 ]' "on top of Valve's new file, once"
ok 'grep -q "quiet splash amd_iommu=off gamecove.vrr=1" "$R/efi/EFI/SteamOS/grub.cfg"' "in the new boot menu"
ok 'fix claw8ex-vrr status | grep -qx after_update=no && fix claw8ex-vrr status | grep -qx pending=yes' "status: pending again"
steamos_boot
ok '[ "$(drm_param)" = "eDP-1:edid/gamecove-csw0801-30-120.bin" ]' "the restart after brings the range back"

case_start steamos_old_record_in_var_moves
steamos_ready
fix claw8ex-vrr install >/dev/null 2>&1
# an install from before the record moved: record in /var, keep list without it
mkdir -p "$R/var/lib/gamecove/fixes"
mv "$R/etc/gamecove/claw8ex-vrr/record" "$R/var/lib/gamecove/fixes/claw8ex-vrr"
grep -v -e /record/ "$R$KEEP" >"$R$KEEP.tmp"
mv "$R$KEEP.tmp" "$R$KEEP"
ok 'fix claw8ex-vrr status | grep -qx installed=yes' "the old record is still found"
fix claw8ex-vrr set refresh >/dev/null 2>&1
ok '[ -s "$R/etc/gamecove/claw8ex-vrr/record/manifest" ] && [ ! -e "$R/var/lib/gamecove/fixes/claw8ex-vrr" ]' "moved into /etc on the next run"
ok 'grep -qx /etc/gamecove/claw8ex-vrr/record/manifest "$R$KEEP"' "and onto the keep list"
steamos_update
ok 'fix claw8ex-vrr status | grep -qx after_update=yes' "so an update no longer loses it"
fix claw8ex-vrr remove >/dev/null 2>&1
ok '[ ! -e "$R/etc/gamecove" ] && [ ! -e "$R$KEEP" ] && [ ! -e "$R$EDID_FILE" ]' "remove: record, keep list and files gone"

case_start steamos_update_lost_files
steamos_ready
fix claw8ex-vrr install >/dev/null 2>&1
steamos_update drop-hook
ok 'fix claw8ex-vrr set refresh | grep -q "removed: the update didn.t keep /etc/modprobe.d/gamecove-claw8ex-vrr.conf"' "files the update didn't keep: the fix is taken out"
ok '[ ! -e "$R/etc/gamecove/claw8ex-vrr" ] && [ ! -e "$R$KEEP" ] && [ ! -e "$R$EDID_FILE" ]' "nothing of it left"
ok '! grep -q GameCove "$R$GRUB"' "no line added"

case_start steamos_driver_in_initramfs
steamos_ready
mkdir -p "$R/boot"
: >"$R/boot/initramfs-linux-neptune-612.img"
printf '#!/bin/sh\necho usr/lib/modules/6.12/kernel/drivers/gpu/drm/xe/xe.ko.zst\n' >"$BIN/lsinitcpio"
chmod +x "$BIN/lsinitcpio"
before=$(snapshot)
ok 'fix claw8ex-vrr install 2>&1 | grep -q "starts from the initramfs"' "driver in the initramfs: refused with the reason"
ok '[ "$(snapshot)" = "$before" ]' "nothing written"
ok 'fix claw8ex-vrr status | grep -qx state=unsupported' "status: unsupported"
printf '#!/bin/sh\necho usr/lib/modules/6.12/kernel/drivers/nvme/nvme.ko.zst\n' >"$BIN/lsinitcpio"
ok 'fix claw8ex-vrr status | grep -qx state=off' "driver after switch_root: offered"

case_start steamos_driver_built_in
steamos_ready
mkdir -p "$R/usr/lib/modules/linux-neptune-612"
echo kernel/drivers/gpu/drm/xe/xe.ko >"$R/usr/lib/modules/linux-neptune-612/modules.builtin"
ok '! fix claw8ex-vrr install 2>/dev/null' "driver built into the kernel: refused"

case_start steamos_no_keep_list
steamos_ready
rmdir "$R/etc/atomic-update.conf.d"
before=$(snapshot)
ok 'fix claw8ex-vrr install 2>&1 | grep -q "atomic-update.conf.d"' "no keep-list folder: refused"
ok '[ "$(snapshot)" = "$before" ]' "nothing written"

case_start steamos_other_edid_in_grub
steamos_ready
echo 'GRUB_CMDLINE_LINUX_DEFAULT="${GRUB_CMDLINE_LINUX_DEFAULT} drm.edid_firmware=eDP-1:edid/mine.bin"' >>"$R$GRUB"
before=$(snapshot)
ok '! fix claw8ex-vrr install 2>/dev/null' "someone else's EDID line in the grub file: refused"
ok '[ "$(snapshot)" = "$before" ]' "nothing written"

case_start steamos_boot_menu_drops_it
steamos_ready
before=$(snapshot)
export FAKE_GRUB_DROPS=1
ok '! fix claw8ex-vrr install 2>/dev/null' "update-grub left the switch out: install fails"
unset FAKE_GRUB_DROPS
ok '[ "$(snapshot)" = "$before" ]' "everything taken back"

case_start steamos_update_grub_fails
steamos_ready
before=$(snapshot)
export FAKE_FAIL=update-grub
ok '! fix claw8ex-vrr install 2>/dev/null' "update-grub fails: install fails"
unset FAKE_FAIL
ok '! grep -q GameCove "$R$GRUB"' "no line left in the grub file"
ok 'grep -qx "grubline /etc/default/grub" "$R/etc/gamecove/claw8ex-vrr/record/manifest"' "the boot menu step that failed is kept to retry"
fix claw8ex-vrr remove >/dev/null 2>&1
ok '[ "$(snapshot)" = "$before" ]' "remove then finishes the job"

# review Medium (Fixes): a failed update-grub left the marked line in /etc/default/grub, so refresh found "already in
# place" and never tried the boot menu again
case_start steamos_refresh_retries_a_failed_update_grub
steamos_ready
fix claw8ex-vrr install >/dev/null 2>&1
steamos_update
export FAKE_FAIL=update-grub
ok '! fix claw8ex-vrr set refresh >/dev/null 2>&1' "refresh: update-grub fails, so it fails"
unset FAKE_FAIL
ok '! grep -q "# GameCove claw8ex-vrr" "$R$GRUB"' "the line is not left marked in the grub file"
ok 'fix claw8ex-vrr status | grep -qx after_update=yes' "status still says the update left it out"
ok 'fix claw8ex-vrr set refresh | grep -q "put back after the SteamOS update"' "the next refresh tries again, and works"
ok 'grep -q "quiet splash amd_iommu=off gamecove.vrr=1" "$R/efi/EFI/SteamOS/grub.cfg"' "the boot menu has it"
fix claw8ex-vrr remove >/dev/null 2>&1

# review Medium (Fixes): a retried install on SteamOS, cut short after the hook, ended "already installed" with no keep list
case_start install_cut_short_before_the_keep_list
steamos_ready
fix claw8ex-vrr install >/dev/null 2>&1
ok '[ -f "$R/etc/atomic-update.conf.d/gamecove-claw8ex-vrr.conf" ]' "installed: the keep list is there"
rm -f "$R/etc/atomic-update.conf.d/gamecove-claw8ex-vrr.conf"
grep -vxF "file /etc/atomic-update.conf.d/gamecove-claw8ex-vrr.conf" "$R/etc/gamecove/claw8ex-vrr/record/manifest" >"$T/m.tmp" || true
cat "$T/m.tmp" >"$R/etc/gamecove/claw8ex-vrr/record/manifest"
ok 'fix claw8ex-vrr install >"$T/out" 2>&1' "the retry succeeds ($(tail -n 1 "$T/out" 2>/dev/null))"
ok '[ -f "$R/etc/atomic-update.conf.d/gamecove-claw8ex-vrr.conf" ]' "and the keep list is back"
ok 'grep -qxF "file /etc/atomic-update.conf.d/gamecove-claw8ex-vrr.conf" "$R/etc/gamecove/claw8ex-vrr/record/manifest"' "recorded, so remove takes it out again"
ok '! grep -q "already installed" "$T/out"' "and it does not say everything was in place"
fix claw8ex-vrr install >"$T/out" 2>&1
ok 'grep -q "already installed" "$T/out"' "a complete install is still \"already installed\""
fix claw8ex-vrr remove >/dev/null 2>&1
ok '[ ! -e "$R/etc/atomic-update.conf.d/gamecove-claw8ex-vrr.conf" ]' "remove takes the keep list away"

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


case_start lifecycle
# docs/FIXES.md: the probe (os_fixed), the installed revision, and update (old version out, this one in)
vrr_ready
ok 'fix claw8ex-vrr status | grep -qx os_fixed=no' "not installed, problem there: os_fixed=no"
ok 'fix claw8ex-vrr status | grep -qx revision=1' "status names the script's revision"
ok 'fix claw8ex-vrr update | grep -q "not installed"' "update never installs"
ok 'fix claw8ex-vrr status | grep -qx state=off' "still off"
fix claw8ex-vrr install >/dev/null 2>&1
ok 'fix claw8ex-vrr status | grep -qx installed_revision=1' "the installed revision is recorded"
ok '! fix claw8ex-vrr status | grep -q "^os_fixed="' "with ours in place the probe can't tell, so it doesn't answer"
before=$(snapshot)
ok 'fix claw8ex-vrr update 2>/dev/null | tail -n 1 | grep -qx updated' "update"
ok '[ "$(snapshot)" = "$before" ]' "update of the same revision leaves the same files and boot configuration"
ok 'fix claw8ex-vrr status | grep -qx installed=yes' "update: still installed"
fix claw8ex-vrr remove >/dev/null 2>&1
ok 'fix claw8ex-vrr status | grep -qx installed=no' "remove after an update"

finish
