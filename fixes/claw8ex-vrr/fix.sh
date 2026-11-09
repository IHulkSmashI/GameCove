#!/bin/sh
# GameCove fix: 30-120 Hz VRR on the Claw's own screen instead of the 48-120 Hz its EDID announces.
# usage: fix.sh install|remove|status
#
# The panel refreshes down to 30 Hz but its EDID says 48, so below 48 fps every frame is held for a whole
# 48 Hz refresh, which judders. This writes a copy of the factory EDID with only the range bytes changed
# (plus checksums), and only for the exact validated factory EDIDs in panels.txt (sha256).
#
# One drive may boot several handhelds, so nothing here is global (no kernel argument). A modprobe
# "install" rule runs a tiny hook right before the Intel GPU driver (xe / i915) loads. Only when the board
# in /sys/class/dmi/id is the one this was installed on does the hook set the drm module's edid_firmware
# parameter (and firmware_class's search path, when unset) through /sys/module. Anywhere else it does
# nothing, and the driver loads as usual.
#   /etc/firmware/edid/gamecove-<panel>-30-120.bin    the patched EDID
#   /etc/gamecove/claw8ex-vrr/edid.conf               "<board> <connector>:edid/<file>"
#   /etc/gamecove/claw8ex-vrr/edid-hook.sh            the board check (shell built-ins only)
#   /etc/modprobe.d/gamecove-claw8ex-vrr.conf         install xe / i915 = hook, then the real modprobe
#   rpm-ostree initramfs-etc --track (all four)        so it also works when the driver loads in the initramfs
#   kernel argument gamecove.vrr=1                    the switch: the hook acts only when it is there
# Takes effect at the next restart; remove undoes everything (also at the next restart). The files are
# written to the live /etc, so the previous boot entry has them too; it still starts with the panel's own
# EDID because its command line has no gamecove.vrr=1 (the marker does nothing by itself, so it is safe
# on other handhelds booting this drive). Kill switch at the boot menu: add gamecove.novrr (or delete
# gamecove.vrr=1) for that boot; `remove` then undoes it for good (review S1-5).
# Older installs used kernel arguments (drm.edid_firmware=...,
# firmware_class.path=...); install, and status run as root, move them to the hook. Ported from
# ClawDeck's edid.py. See fixes/README.md.
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=fixes/lib/claw8ex-common.sh
. "$HERE/../lib/claw8ex-common.sh"

NAME=claw8ex-vrr
PANELS=${GAMECOVE_VRR_PANELS:-$HERE/panels.txt}
EDID_DIR=$FW_DIR/edid
CONNECTOR=eDP-1
LO=30
HI=120
CONF_DIR=/etc/gamecove/claw8ex-vrr
HOOK=$CONF_DIR/edid-hook.sh
HOOK_CONF=$CONF_DIR/edid.conf
MODPROBE_CONF=/etc/modprobe.d/gamecove-claw8ex-vrr.conf
DRM_PARAM=/sys/module/drm/parameters/edid_firmware
VRR_KARG=gamecove.vrr=1
m_init "$NAME"

# The boot entry switch (kept in the manifest as "marker", so migrate never takes it for an old karg).
ensure_marker() {
	m_has marker "$VRR_KARG" && return 0
	karg_hold "$VRR_KARG" "$NAME" || return 1
	m_add marker "$VRR_KARG"
}

kill_switch() { karg_in gamecove.novrr "$(cmdline)"; }

# edid_q <edid file> -v mode=... : run edid.awk on the file's bytes.
edid_q() { f=$1; shift; od -An -v -tu1 "$f" | awk -f "$HERE/edid.awk" "$@"; }

# Boards whose panels are in panels.txt (the MSI Claw family).
claw_board() {
	case $(board_name) in MS-1T*) return 0 ;; esac
	return 1
}

is_root() { [ -n "$ROOT" ] || [ "$(id -u)" -eq 0 ]; }

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

# The drm parameter as the running kernel has it ("" when unset or unreadable).
drm_param() { tr -d '\n' <"$ROOT$DRM_PARAM" 2>/dev/null || true; }

modprobe_text() {
	cat <<EOF
# GameCove claw8ex-vrr: right before the Intel GPU driver loads, $HOOK sets the corrected EDID,
# but only on the board it was installed on (first word of $HOOK_CONF). On other hardware it does nothing.
# Remove with: gamecove-fix $NAME remove
install xe /bin/sh $HOOK || :; /sbin/modprobe --ignore-install xe \$CMDLINE_OPTS
install i915 /bin/sh $HOOK || :; /sbin/modprobe --ignore-install i915 \$CMDLINE_OPTS
EOF
}

# Another install rule for the GPU drivers would clash with ours (modprobe uses one): refuse.
modprobe_taken() {
	for f in "$ROOT"/etc/modprobe.d/*.conf "$ROOT"/usr/lib/modprobe.d/*.conf; do
		[ -f "$f" ] || continue
		[ "$f" = "$ROOT$MODPROBE_CONF" ] && continue
		if grep -Eq '^[[:space:]]*install[[:space:]]+(xe|i915)([[:space:]]|$)' "$f"; then
			printf '%s' "${f#"$ROOT"}"
			return 0
		fi
	done
	return 1
}

# put_hook <board> <EDID file name>: the hook files, recorded, and tracked in the initramfs.
put_hook() {
	printf '%s %s:edid/%s\n' "$1" "$CONNECTOR" "$2" >"$GC_TMP/edid.conf"
	modprobe_text >"$GC_TMP/modprobe.conf"
	m_put "$GC_TMP/edid.conf" "$HOOK_CONF" 644 || return 1
	m_put "$HERE/edid-hook.sh" "$HOOK" 755 || return 1
	m_put "$GC_TMP/modprobe.conf" "$MODPROBE_CONF" 644 || return 1
	for f in "$HOOK_CONF" "$HOOK" "$MODPROBE_CONF"; do
		m_has initramfs "$f" && continue
		rpm-ostree initramfs-etc --track="$f" >/dev/null || return 1
		m_add initramfs "$f"
	done
}

# Kernel arguments recorded by an install from before the hook.
old_kargs() {
	[ -f "$MANIFEST" ] || return 0
	sed -n 's/^karg //p' "$MANIFEST"
}

# Older installs set drm.edid_firmware=... (and held firmware_class.path=...) on the kernel command line,
# which every handheld booting this drive gets. Replace them with the hook; on another board (where the
# old EDID must not be used at all) just take the kernel arguments and the rest away.
migrate() {
	m_installed || return 0
	olds=$(old_kargs)
	[ -n "$olds" ] || return 0
	edid=$(sed -n 's|^file \(/etc/firmware/edid/gamecove-.*\.bin\)$|\1|p' "$MANIFEST" | head -n 1)
	hook=no
	if [ -n "$edid" ] && [ -f "$ROOT$edid" ] && claw_board; then
		GC_TMP=$(mktemp -d)
		put_hook "$(board_name)" "$(basename "$edid")" || { warn "could not set up the boot hook; the old kernel arguments stay"; return 1; }
		hook=yes
	fi
	for a in $olds; do
		if karg_release "$a" "$NAME"; then
			grep -vxF "karg $a" "$MANIFEST" >"$MANIFEST.tmp" || true
			mv -f "$MANIFEST.tmp" "$MANIFEST"
		else
			warn "could not remove the kernel argument $a"
		fi
	done
	if [ "$hook" = no ]; then
		m_undo || { warn "some changes could not be undone; run remove"; return 1; }
		say "removed the old global kernel arguments (this isn't the Claw it was installed on); install again on the Claw"
		return 0
	fi
	[ -z "$(old_kargs)" ] || return 1
	say "moved from kernel arguments to the per-device boot hook (takes effect at the next restart)"
}

install() {
	require_root
	lock
	if m_installed; then
		migrate || die "could not move the old kernel arguments to the boot hook; see the messages above"
		if m_installed; then
			ensure_marker || die "could not add the gamecove.vrr=1 kernel argument"
			say "already installed"
		fi
		return 0
	fi
	claw_board || die "this fix is only for the MSI Claw (boards MS-1T*); this board is '$(board_name)'"
	has_rpm_ostree || die "this system has no rpm-ostree (Bazzite / Fedora Atomic only for now)"
	raw=$(panel_edid) || die "no internal screen EDID found"
	booted=$(karg_value drm.edid_firmware "$(cmdline)")
	pending=$(karg_value drm.edid_firmware "$(karg_pending)")
	theirs "$booted" && die "another EDID override is active ($booted); remove it first"
	theirs "$pending" && die "another EDID override is set for the next boot ($pending); remove it first"
	theirs "$(drm_param)" && die "another EDID override is active ($(drm_param)); remove it first"
	if taken=$(modprobe_taken); then
		die "$taken already has an install rule for the GPU driver; not changing it"
	fi
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
		case $booted$(drm_param) in
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
	put_hook "$(board_name)" "$name" || { m_undo || true; die "could not set up the boot hook"; }
	ensure_marker || { m_undo || true; die "could not add the gamecove.vrr=1 kernel argument"; }
	say "installed for panel $key on board $(board_name): restart the Claw to get 30-120 Hz VRR"
	say "other handhelds booting this drive are not affected"
	say "if the screen is wrong after the restart: pick the previous boot entry, or add gamecove.novrr at the boot menu (e), then remove this fix"
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
	if m_installed && is_root && { [ -n "$(old_kargs)" ] || ! m_has marker "$VRR_KARG"; }; then
		lock
		migrate >&2 || true
		! m_installed || ensure_marker >&2 || true
	fi
	old=no
	[ -n "$(old_kargs)" ] && old=yes
	if ! claw_board; then
		say "applies=no"
		say "old_kernel_args=$old"
		say "state=n/a"
		return 0
	fi
	raw=$(panel_edid) || { say "applies=no"; say "old_kernel_args=$old"; say "state=n/a"; return 0; }
	key=$(edid_q "$raw" -v mode=id || true)
	row=$(panel_row "$key")
	range=$(edid_q "$raw" -v mode=range || true)
	booted=$(karg_value drm.edid_firmware "$(cmdline)")
	[ -n "$booted" ] || booted=$(drm_param)
	installed=no
	m_installed && installed=yes
	pending=no
	if [ "$installed" = yes ] && grep -qF "$(board_name) $CONNECTOR:edid/$(file_name "$key")" "$ROOT$HOOK_CONF" 2>/dev/null; then
		pending=yes
	fi
	say "applies=yes"
	say "panel=${key:-unknown}"
	say "validated=$([ -n "$row" ] && echo yes || echo no)"
	say "range=$(printf '%s' "${range:-unknown}" | tr ' ' '-')"
	say "installed=$installed"
	say "pending=$pending"
	say "old_kernel_args=$old"
	say "boot_switch=$(m_has marker "$VRR_KARG" && echo yes || echo no)"
	say "kill_switch=$(kill_switch && echo on || echo off)"
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
