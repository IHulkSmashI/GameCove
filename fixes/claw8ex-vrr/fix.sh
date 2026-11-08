#!/bin/sh
# GameCove fix: 30-120 Hz VRR on the Claw's own screen instead of the 48-120 Hz its EDID announces.
# usage: fix.sh install|remove|status
#
# The panel refreshes down to 30 Hz but its EDID says 48, so below 48 fps every frame is held for a whole
# 48 Hz refresh, which judders. This writes a copy of the factory EDID with only the range bytes changed
# (plus checksums), and only for the exact validated factory EDIDs in panels.txt (sha256). At boot, the way
# Bazzite already overrides other handhelds' EDIDs:
#   /etc/firmware/edid/gamecove-<panel>-30-120.bin    the patched EDID
#   rpm-ostree initramfs-etc --track                   so the GPU driver finds it at its first probe
#   rpm-ostree kargs                                   firmware_class.path=/etc/firmware (shared with
#                                                      claw8ex-gyro) drm.edid_firmware=eDP-1:edid/<file>
# Takes effect at the next restart; remove undoes all three (also at the next restart), and the previous
# boot entry always starts without it. Ported from ClawDeck's edid.py. See README.md.
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=fixes/claw8ex-buttons/claw8ex-common.sh
. "$HERE/../claw8ex-buttons/claw8ex-common.sh"

NAME=claw8ex-vrr
PANELS=${GAMECOVE_VRR_PANELS:-$HERE/panels.txt}
EDID_DIR=$FW_DIR/edid
CONNECTOR=eDP-1
LO=30
HI=120
m_init "$NAME"

# edid_q <edid file> -v mode=... : run edid.awk on the file's bytes.
edid_q() { f=$1; shift; od -An -v -tu1 "$f" | awk -f "$HERE/edid.awk" "$@"; }

panel_edid() {
	for p in "$ROOT"/sys/class/drm/card*-"$CONNECTOR"/edid; do
		[ -s "$p" ] && { printf '%s' "$p"; return 0; }
	done
	return 1
}

panel_row() { awk -v k="$1" '!/^#/ && $1 == k { print; exit }' "$PANELS"; }

sha_of() { sha256sum "$1" 2>/dev/null | cut -d ' ' -f 1; }

file_name() { printf 'gamecove-%s-%s-%s.bin' "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" "$LO" "$HI"; }

# canonical <edid> <length> <out>: the EDID at the panel's length (a 128-byte EDID may come padded with an
# all-zero second block). Fails if it can't be normalised.
canonical() {
	size=$(wc -c <"$1" | tr -d ' ')
	if [ "$size" = "$2" ]; then
		cp "$1" "$3"
	elif [ "$2" = 128 ] && [ "$size" = 256 ] &&
		od -An -v -tu1 "$1" | awk '{ for (i = 1; i <= NF; i++) b[n++] = $i } END { if (b[126] != 0) exit 1; for (i = 128; i < 256; i++) if (b[i] != 0) exit 1 }'; then
		dd if="$1" of="$3" bs=128 count=1 2>/dev/null
	else
		return 1
	fi
}

# write_byte <file> <offset> <value>
write_byte() {
	# shellcheck disable=SC2059
	printf "\\$(printf '%03o' "$3")" | dd of="$1" bs=1 seek="$2" conv=notrunc 2>/dev/null
}

theirs() {
	case $1 in "" | *gamecove-*) return 1 ;; esac
	return 0
}

install() {
	require_root
	lock
	if m_installed; then
		say "already installed"
		return 0
	fi
	has_rpm_ostree || die "this system has no rpm-ostree (Bazzite / Fedora Atomic only for now)"
	raw=$(panel_edid) || die "no internal screen EDID found"
	booted=$(karg_value drm.edid_firmware "$(cmdline)")
	pending=$(karg_value drm.edid_firmware "$(karg_pending)")
	theirs "$booted" && die "another EDID override is active ($booted); remove it first"
	theirs "$pending" && die "another EDID override is set for the next boot ($pending); remove it first"
	require_fw_path_free
	key=$(edid_q "$raw" -v mode=id) || die "the screen's EDID can't be read"
	row=$(panel_row "$key")
	[ -n "$row" ] || die "screen $key is not one of the validated panels; nothing changed"
	# shellcheck disable=SC2086 # split the panel row into its fields
	set -- $row
	want_sha=$2
	length=$3
	offsets=$4
	GC_TMP=$(mktemp -d)
	if ! canonical "$raw" "$length" "$GC_TMP/factory.bin" || [ "$(sha_of "$GC_TMP/factory.bin")" != "$want_sha" ]; then
		case $booted in
		*gamecove-*) die "started with GameCove's EDID already: restart once, then install again" ;;
		esac
		die "panel $key has an EDID that isn't the validated factory one; nothing changed"
	fi
	changes=$(edid_q "$GC_TMP/factory.bin" -v mode=patch -v offsets="$offsets" -v lo="$LO" -v hi="$HI") ||
		die "the patched EDID failed its own check; nothing changed"
	cp "$GC_TMP/factory.bin" "$GC_TMP/patched.bin"
	printf '%s\n' "$changes" | while read -r off val; do
		[ -n "$off" ] && write_byte "$GC_TMP/patched.bin" "$off" "$val"
	done
	if [ "$(edid_q "$GC_TMP/patched.bin" -v mode=range)" != "$LO $HI" ] || ! edid_q "$GC_TMP/patched.bin" -v mode=check; then
		die "the patched EDID failed its own check; nothing changed"
	fi
	name=$(file_name "$key")
	dest=$EDID_DIR/$name
	m_put "$GC_TMP/patched.bin" "$dest" 644 || { m_undo || true; die "could not write $dest"; }
	if ! rpm-ostree initramfs-etc --track="$dest" >/dev/null; then
		m_undo || true
		die "rpm-ostree initramfs-etc failed"
	fi
	m_add initramfs "$dest"
	karg_hold "$FW_KARG" "$NAME" || { m_undo || true; die "could not set $FW_KARG"; }
	m_add karg "$FW_KARG"
	edid_karg="drm.edid_firmware=$CONNECTOR:edid/$name"
	karg_hold "$edid_karg" "$NAME" || { m_undo || true; die "could not set $edid_karg"; }
	m_add karg "$edid_karg"
	say "installed for panel $key: restart the Claw to get 30-120 Hz VRR"
}

remove() {
	require_root
	lock
	if ! m_installed; then
		say "not installed"
		return 0
	fi
	m_undo || die "some changes could not be undone; see the messages above and run remove again"
	say "removed: restart the Claw to go back to the panel's own 48-120 Hz range"
}

status() {
	raw=$(panel_edid) || { say "applies=no"; say "state=n/a"; return 0; }
	key=$(edid_q "$raw" -v mode=id || true)
	row=$(panel_row "$key")
	range=$(edid_q "$raw" -v mode=range || true)
	booted=$(karg_value drm.edid_firmware "$(cmdline)")
	installed=no
	m_installed && installed=yes
	pending=no
	karg_in "drm.edid_firmware=$CONNECTOR:edid/$(file_name "$key")" "$(karg_pending)" && pending=yes
	say "applies=yes"
	say "panel=${key:-unknown}"
	say "validated=$([ -n "$row" ] && echo yes || echo no)"
	say "range=$(printf '%s' "${range:-unknown}" | tr ' ' '-')"
	say "installed=$installed"
	say "pending=$pending"
	if theirs "$booted"; then
		say "state=other-override"
	elif [ "$installed" = yes ] && [ "$range" = "$LO $HI" ] && [ -n "$booted" ]; then
		say "state=on"
	elif [ "$installed" = yes ]; then
		say "state=restart"
	elif [ -z "$row" ]; then
		say "state=unsupported"
	else
		say "state=off"
	fi
}

case ${1:-} in
install) install ;;
remove) remove ;;
status) status ;;
*) die "usage: $0 install|remove|status" ;;
esac
