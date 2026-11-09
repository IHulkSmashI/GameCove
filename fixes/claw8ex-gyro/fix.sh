#!/bin/sh
# GameCove fix: gyro on the MSI Claw 8 EX AI+ (board MS-1T91), the IMU behind Intel's sensor hub (ISH).
# usage: fix.sh install|remove|status|set accel-on|accel-off
#
# Method found and tested by Kisenir (r/MSIClaw), used with his permission (2026-11-08); ported from
# ClawDeck. Four pieces, all recorded and all taken out again by remove:
#   1. MSI's ISH firmware, downloaded from MSI on the device (it may not be passed on), checked by size and
#      sha256 BEFORE anything is written, installed as /etc/firmware/intel/ish/ish_ptl.bin, plus the kernel
#      argument firmware_class.path=/etc/firmware (shared with claw8ex-vrr, removed when neither needs it).
#      The file is also tracked in the initramfs (rpm-ostree initramfs-etc), like the VRR fix's EDID:
#      Bazzite's generic initramfs carries drivers/hid (intel_ish_ipc included), so the hub may ask for its
#      firmware before the root filesystem is mounted, where only the initramfs copy of /etc exists.
#   2. A HID-BPF program (bpf/) that relabels the hub's two custom sensors as Accelerometer 3D / Gyrometer
#      3D, so the kernel creates gyro_3d; installed to /etc/udev-hid-bpf/.
#   3. Two helper services: keep-alive (sensor power and report rate) and gyro bias correction.
#   4. An imu source (gyro only; accelerometer optional) in the InputPlumber override for the board.
# Bazzite (rpm-ostree) only for now. See fixes/README.md.
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=fixes/lib/claw8ex-common.sh
. "$HERE/../lib/claw8ex-common.sh"

NAME=claw8ex-gyro
KIT_URL="https://download.msi.com/nb_drivers/cs/ISH_Kit_5.8.1.7782_1T91%20_0318_5.8.58.0_0x96746247.zip"
KIT_MEMBER="Drivers/Win10/IshHeci/x64/FWImage/0004/ishS_SI_5.8.1.7782.bin"
FW_SIZE=432640
FW_SHA256=8194475367978c473d17e7e777fe196d99383f80f51b433927ea9afd0e9e661b
FW_DEST=$FW_DIR/intel/ish/ish_ptl.bin
ISH_PCI=/sys/bus/pci/devices/0000:00:12.0
BPF_NAME=MSI__Claw-ISH-IMU.bpf.o
BPF_OBJ=${GAMECOVE_GYRO_BPF_OBJ:-$HERE/bpf/$BPF_NAME}
BPF_DEST=/etc/udev-hid-bpf/$BPF_NAME
HELPER_DIR=/etc/gamecove/claw8ex-gyro
UNIT_DIR=/etc/systemd/system
KEEPALIVE=gamecove-gyro-keepalive.service
BIAS=gamecove-gyro-bias.service
BIAS_STATE=/var/lib/ish-gyro-bias
m_init "$NAME"

# One drive may boot several handhelds: the services start only on this board (ExecCondition skips the
# unit cleanly elsewhere, without a failure or a restart loop).
board_condition() { printf 'ExecCondition=/usr/bin/grep -qx %s /sys/class/dmi/id/board_name\n' "$BOARD_WANTED"; }

keepalive_unit() {
	cat <<EOF
[Unit]
Description=GameCove: MSI Claw 8 EX ISH IMU keep-alive (gyro power and report rate while InputPlumber reads it)
After=systemd-udev-settle.service

[Service]
$(board_condition)
ExecStart=/usr/bin/python3 $HELPER_DIR/ish_imu_keepalive.py
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
}

bias_unit() {
	cat <<EOF
[Unit]
Description=GameCove: gyro bias correction for the MSI Claw 8 EX ISH IMU
After=$KEEPALIVE
Wants=$KEEPALIVE

[Service]
$(board_condition)
ExecStart=/usr/bin/python3 $HELPER_DIR/ish_gyro_bias.py
Restart=always
RestartSec=3
StateDirectory=ish-gyro-bias

[Install]
WantedBy=multi-user.target
EOF
}

sha_of() { sha256sum "$1" 2>/dev/null | cut -d ' ' -f 1; }

has_ish() {
	[ "$(cat "$ROOT$ISH_PCI/vendor" 2>/dev/null)" = 0x8086 ] || return 1
	case $(tr 'A-F' 'a-f' <"$ROOT$ISH_PCI/device" 2>/dev/null) in
	0xe345 | 0xe445) return 0 ;;
	esac
	return 1
}

has_udev_hid_bpf() {
	command -v udev-hid-bpf >/dev/null 2>&1 && return 0
	for r in "$ROOT"/usr/lib/udev/rules.d/*hid-bpf*.rules; do
		[ -e "$r" ] && return 0
	done
	return 1
}

# The hub's HID device only appears once MSI's firmware runs on it.
hub_present() {
	for u in "$ROOT"/sys/class/hidraw/hidraw*/device/uevent; do
		[ -f "$u" ] || continue
		up=$(tr 'a-f' 'A-F' <"$u")
		case $up in *8087*0AC2*) return 0 ;; esac
	done
	return 1
}

iio_dev() {
	for d in "$ROOT"/sys/bus/iio/devices/iio:device*; do
		[ "$(cat "$d/name" 2>/dev/null)" = "$1" ] && { printf '%s' "$d"; return 0; }
	done
	return 1
}

# InputPlumber reading the gyro = the IIO buffer is enabled.
iio_reading() {
	for e in "$1"/buffer/enable "$1"/buffer0/enable; do
		[ "$(cat "$e" 2>/dev/null)" = 1 ] && return 0
	done
	return 1
}

# Download MSI's kit and pull out the firmware into $GC_TMP/ish_ptl.bin.download. Checks size and sha256;
# nothing is written outside the temp folder unless both match.
fetch_firmware() {
	say "downloading MSI's ISH kit (about 30 MB) from download.msi.com ..."
	curl -fsSL --retry 2 --max-time 600 -o "$GC_TMP/kit.zip" "$KIT_URL" || die "download failed: $KIT_URL"
	member=$(unzip -Z1 "$GC_TMP/kit.zip" 2>/dev/null | grep -i -F "$KIT_MEMBER" | head -n 1) || true
	[ -n "$member" ] || die "MSI's ISH kit has no $KIT_MEMBER"
	unzip -p "$GC_TMP/kit.zip" "$member" >"$GC_TMP/ish_ptl.bin.download" || die "could not extract the firmware"
	size=$(wc -c <"$GC_TMP/ish_ptl.bin.download" | tr -d ' ')
	sum=$(sha_of "$GC_TMP/ish_ptl.bin.download")
	if [ "$size" != "$FW_SIZE" ] || [ "$sum" != "$FW_SHA256" ]; then
		die "the firmware in MSI's kit isn't the tested one ($size bytes, sha256 $sum); nothing was changed"
	fi
}

# Installs from before the board check have units without ExecCondition: write the current ones.
refresh_units() {
	m_installed || return 0
	if grep -q "^ExecCondition=" "$ROOT$UNIT_DIR/$KEEPALIVE" 2>/dev/null && grep -q "^ExecCondition=" "$ROOT$UNIT_DIR/$BIAS" 2>/dev/null; then
		return 0
	fi
	t=$(mktemp -d)
	keepalive_unit >"$t/$KEEPALIVE"
	bias_unit >"$t/$BIAS"
	ok=0
	m_put "$t/$KEEPALIVE" "$UNIT_DIR/$KEEPALIVE" 644 && m_put "$t/$BIAS" "$UNIT_DIR/$BIAS" 644 || ok=1
	rm -rf "$t"
	systemctl daemon-reload >/dev/null 2>&1 || true
	[ "$ok" = 0 ] && say "services now start only on board $BOARD_WANTED" >&2
	return "$ok"
}

is_root() { [ -n "$ROOT" ] || [ "$(id -u)" -eq 0 ]; }

fail() {
	warn "$1; undoing what was done"
	m_undo || warn "some changes could not be undone; run remove"
	die "$1"
}

install() {
	require_root
	require_board
	lock
	if m_installed; then
		refresh_units || die "could not update the services"
		say "already installed"
		return 0
	fi
	has_ish || die "no Panther Lake sensor hub at $ISH_PCI"
	has_rpm_ostree || die "the gyro fix needs Bazzite for now (it sets a kernel argument with rpm-ostree)"
	has_udev_hid_bpf || die "this system has no udev-hid-bpf, which loads the gyro program"
	[ -f "$BPF_OBJ" ] || die "the gyro program ($BPF_NAME) isn't in this build of GameCove. Install a release package (RPM or sysext from https://github.com/IHulkSmashI/gamecove/releases), which includes it, or build it from source with $HERE/bpf/build-bpf.sh (needs clang, llvm and libbpf headers) and run install again"
	require_fw_path_free
	ip_require_free
	need_fw=1
	if [ -e "$ROOT$FW_DEST" ]; then
		[ "$(sha_of "$ROOT$FW_DEST")" = "$FW_SHA256" ] || die "$FW_DEST exists and isn't MSI's tested firmware; leaving it"
		need_fw=0
	fi
	GC_TMP=$(mktemp -d)
	[ "$need_fw" = 0 ] || fetch_firmware
	# Verified (or already there): from here on every change is recorded.
	if [ "$need_fw" = 1 ]; then
		m_put "$GC_TMP/ish_ptl.bin.download" "$FW_DEST" 644 || fail "could not write $FW_DEST"
		rpm-ostree initramfs-etc --track="$FW_DEST" >/dev/null || fail "rpm-ostree initramfs-etc failed"
		m_add initramfs "$FW_DEST"
	fi
	m_put "$BPF_OBJ" "$BPF_DEST" 644 || fail "could not write $BPF_DEST"
	for h in ish_imu_keepalive.py ish_gyro_bias.py ish_sensor_probe.py; do
		m_put "$HERE/helpers/$h" "$HELPER_DIR/$h" 755 || fail "could not write $HELPER_DIR/$h"
	done
	keepalive_unit >"$GC_TMP/$KEEPALIVE"
	bias_unit >"$GC_TMP/$BIAS"
	m_put "$GC_TMP/$KEEPALIVE" "$UNIT_DIR/$KEEPALIVE" 644 || fail "could not write $KEEPALIVE"
	m_put "$GC_TMP/$BIAS" "$UNIT_DIR/$BIAS" 644 || fail "could not write $BIAS"
	systemctl daemon-reload >/dev/null 2>&1 || true
	for u in "$KEEPALIVE" "$BIAS"; do
		systemctl enable --now "$u" >/dev/null 2>&1 || fail "could not start $u"
		m_add unit "$u"
	done
	ip_flag_on imu || fail "could not add the gyro to the InputPlumber override"
	m_add ipflag imu
	karg_hold "$FW_KARG" "$NAME" || fail "could not set the kernel argument $FW_KARG"
	m_add karg "$FW_KARG"
	say "installed. Next: shut the Claw down fully and turn it on again (a cold boot, not a restart: it clears"
	say "the sensor hub), then recalibrate the gyro once in Steam (Settings > Controller > Gyro)."
}

remove() {
	require_root
	lock
	if ! m_installed; then
		say "not installed"
		return 0
	fi
	rm -f "$IP_FLAGS/accel"
	m_undo || die "some changes could not be undone; see the messages above and run remove again"
	rm -rf "${ROOT}${BIAS_STATE}"
	say "removed. Restart the Claw to finish (the loaded firmware stays until then)."
}

# One token, so it fits gamecove-fix's `set <value>` (values can't hold spaces).
set_value() {
	[ $# -eq 1 ] || die "usage: $0 set accel-on|accel-off"
	case $1 in
	accel-on | accel-off) ;;
	*) die "usage: $0 set accel-on|accel-off" ;;
	esac
	require_root
	lock
	m_installed || die "install the gyro first"
	if [ "$1" = accel-on ]; then
		mkdir -p "$IP_FLAGS" && : >"$IP_FLAGS/accel"
	else
		rm -f "$IP_FLAGS/accel"
	fi
	ip_regen || die "could not update the InputPlumber override"
	say "accelerometer ${1#accel-}; recalibrate the gyro in Steam"
}

status() {
	if m_installed && is_root; then
		lock
		refresh_units || true
	fi
	if [ "$(board_name)" != "$BOARD_WANTED" ] || ! has_ish; then
		say "applies=no"
		say "state=n/a"
		return 0
	fi
	installed=no
	m_installed && installed=yes
	fw=no
	[ "$(sha_of "$ROOT$FW_DEST")" = "$FW_SHA256" ] && fw=yes
	karg=no
	karg_in "$FW_KARG" "$(cmdline)" && karg=yes
	loaded=no
	hub_present && loaded=yes
	gyro=no
	reading=no
	if d=$(iio_dev gyro_3d); then
		gyro=yes
		iio_reading "$d" && reading=yes
	fi
	ip=no
	grep -q 'name: gyro_3d' "$ROOT$IP_OVERRIDE" 2>/dev/null && ip=yes
	accel=no
	ip_flag accel && accel=yes
	services=active
	if [ "$installed" = yes ]; then
		for u in "$KEEPALIVE" "$BIAS"; do
			[ "$(systemctl is-active "$u" 2>/dev/null || true)" = active ] || services=inactive
		done
	else
		services=none
	fi
	say "applies=yes"
	say "installed=$installed"
	say "firmware_file=$fw"
	say "kernel_arg=$karg"
	say "firmware_loaded=$loaded"
	say "gyro_iio=$gyro"
	say "inputplumber_imu=$ip"
	say "inputplumber_reading=$reading"
	say "accelerometer=$accel"
	say "services=$services"
	if [ "$installed" = no ]; then
		say "state=off"
	elif [ "$karg" = no ] || [ "$loaded" = no ] || [ "$gyro" = no ]; then
		say "state=restart"
		say "next=shut the Claw down fully and turn it on again (cold boot), then recalibrate the gyro in Steam"
	elif [ "$ip" = no ] || [ "$services" != active ]; then
		say "state=partial"
	else
		say "state=on"
	fi
}

case ${1:-} in
install) install ;;
remove) remove ;;
status) status ;;
set) shift; set_value "$@" ;;
*) die "usage: $0 install|remove|status|set accel-on|accel-off" ;;
esac
