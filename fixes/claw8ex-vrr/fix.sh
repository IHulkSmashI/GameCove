#!/bin/sh
# GameCove fix: 30-120 Hz VRR on the Claw's own screen instead of the 48-120 Hz its EDID announces.
# usage: fix.sh install|remove|update|status|set refresh
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
#
# SteamOS (no rpm-ostree): the same EDID, hook and modprobe rule, but no initramfs step: the fix is only offered
# where the GPU driver starts after the real /etc is there (not built in, not in the running initramfs: lsinitcpio),
# as ClawDeck checks. The switch gamecove.vrr=1 goes on one marked line in /etc/default/grub, update-grub rebuilds
# SteamOS's boot menu (checked in /efi/EFI/SteamOS/grub.cfg), and /etc/atomic-update.conf.d/gamecove-claw8ex-vrr.conf
# keeps the fix's own files across SteamOS updates. An update brings back Valve's grub file without our line:
# `set refresh` (no password; GameCove runs it at start when the line is gone) puts it back on top of the new file,
# and one restart brings the range back; where the update made the fix impossible, it takes the fix out instead.
# The record of the changes (the manifest) is the one thing that must survive too: SteamOS gives every OS slot its own
# /var and an update keeps only the /etc files on the keep list, so on SteamOS the record lives in
# /etc/gamecove/claw8ex-vrr/record (on the keep list) instead of /var/lib/gamecove (Bazzite keeps /var). A record an
# older GameCove left in /var is moved over on the next run as root. Without it, `set refresh` after an update would
# find "nothing to do" and the range would stay gone. Untested on a SteamOS handheld (see docs/FIXES.md).
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=fixes/lib/claw8ex-common.sh
. "$HERE/../lib/claw8ex-common.sh"

NAME=claw8ex-vrr
REVISION=1 # = "revision" in fix.json
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
KEEP_CONF=$KEEP_DIR/gamecove-claw8ex-vrr.conf
m_init "$NAME"
RECORD_ETC=/etc/gamecove/claw8ex-vrr/record

# On SteamOS the record sits in /etc, which the keep list carries across updates (see the header).
record_home() {
	is_steamos || return 0
	_old=$M_DIR
	M_DIR=$ROOT$RECORD_ETC
	MANIFEST=$M_DIR/manifest
	[ ! -s "$MANIFEST" ] && [ -s "$_old/manifest" ] || return 0
	if [ -n "$ROOT" ] || [ "$(id -u)" -eq 0 ]; then
		# an install from before the record moved: bring it over, and the keep list with it
		mkdir -p "$M_DIR" && cp -pR "$_old/." "$M_DIR/" && rm -rf "$_old" || { M_DIR=$_old; MANIFEST=$M_DIR/manifest; return 0; }
		if [ -f "$ROOT$KEEP_CONF" ]; then
			GC_TMP=$(mktemp -d)
			keep_text >"$GC_TMP/keep.conf"
			m_put "$GC_TMP/keep.conf" "$KEEP_CONF" 644 || warn "could not add the record to $KEEP_CONF"
			rm -rf "$GC_TMP"
			GC_TMP=
		fi
	else
		M_DIR=$_old
		MANIFEST=$M_DIR/manifest
	fi
}

vrr_undo() {
	m_undo || return 1
	record_tidy
}

# After an undo: the record's own folders, when nothing else is in them.
record_tidy() {
	rmdir "$ROOT/etc/gamecove/claw8ex-vrr" "$ROOT/etc/gamecove" 2>/dev/null || true
}

# How this system takes the boot switch: rpm-ostree (Bazzite / Fedora Atomic), steamos (its GRUB config), or none.
boot_backend() {
	if has_rpm_ostree; then
		echo rpm-ostree
	elif is_steamos && [ -f "$ROOT$GRUB_DEFAULT" ] && command -v update-grub >/dev/null 2>&1; then
		echo steamos
	else
		echo none
	fi
}

# The screen's GPU driver (xe / i915), from the panel's DRM card.
gpu_driver() {
	for c in "$ROOT"/sys/class/drm/card*-"$CONNECTOR"; do
		[ -e "$c" ] || continue
		card=${c##*/}
		card=${card%%-*}
		d=$(readlink -f "$ROOT/sys/class/drm/$card/device/driver" 2>/dev/null) || continue
		printf '%s' "${d##*/}"
		return 0
	done
	return 1
}

# The driver probes before the real /etc is there (built into the kernel, or inside the running kernel's initramfs),
# so it could never read the EDID or the hook from /etc. Unknown (no lsinitcpio, image not found) counts as no, as
# in ClawDeck (the fix then does nothing at boot, and status says restart).
driver_in_initramfs() {
	drv=$(gpu_driver) || return 1
	case $drv in xe | i915) ;; *) return 1 ;; esac
	kver=$(cmdline | sed -n 's/.*BOOT_IMAGE=[^ ]*vmlinuz-\([^ ]*\).*/\1/p')
	[ -n "$kver" ] || kver=$(uname -r)
	grep -Eq "/$drv\.ko(\.[a-z]+)?\$" "$ROOT/usr/lib/modules/$kver/modules.builtin" 2>/dev/null && return 0
	img=$ROOT/boot/initramfs-$kver.img
	[ -f "$img" ] && command -v lsinitcpio >/dev/null 2>&1 || return 1
	lsinitcpio "$img" 2>/dev/null | grep -Eq "/$drv\.ko(\.[a-z]+)?\$"
}

# Why SteamOS can't take the fix here, "" when it can.
steamos_blocker() {
	[ -d "$ROOT$KEEP_DIR" ] || { printf "this SteamOS has no %s, which keeps the fix's files across updates" "$KEEP_DIR"; return 0; }
	driver_in_initramfs && { printf 'on this SteamOS the graphics driver starts from the initramfs, before /etc is there, so it could never get the corrected range'; return 0; }
	return 0
}

# Someone else's drm.edid_firmware in /etc/default/grub (a line without our marker).
grub_other_edid() {
	grep -vF "$(grub_mark "$NAME")" "$ROOT$GRUB_DEFAULT" 2>/dev/null | grep -v '^[[:space:]]*#' | grep -o 'drm\.edid_firmware=[^ "]*' | head -n 1
}

keep_text() {
	cat <<EOF
## GameCove claw8ex-vrr: keeps GameCove's corrected screen description (EDID), its boot hook and modprobe rule
## across SteamOS updates (GameCove's own files only). gamecove-fix $NAME remove deletes this file.
$EDID_DIR/gamecove-*.bin
$HOOK_CONF
$HOOK
$MODPROBE_CONF
$KEEP_CONF
$RECORD_ETC/manifest
$RECORD_ETC/backup
EOF
}

# The boot entry switch (kept in the manifest as "marker", so migrate never takes it for an old karg).
ensure_marker() {
	if [ "$(boot_backend)" = steamos ]; then
		m_has grubline "$GRUB_DEFAULT" && grub_has_line && return 0
		m_has grubline "$GRUB_DEFAULT" || m_add grubline "$GRUB_DEFAULT"
		grub_line_add "$VRR_KARG"
		return
	fi
	m_has marker "$VRR_KARG" && return 0
	karg_hold "$VRR_KARG" "$NAME" || return 1
	m_add marker "$VRR_KARG"
}

# The boot switch is in place for the next boot.
switch_set() {
	if m_has grubline "$GRUB_DEFAULT"; then
		grub_has_line
	else
		m_has marker "$VRR_KARG"
	fi
}

# After a SteamOS update: Valve's new /etc/default/grub has no line of ours, while the keep list kept the fix's
# files. Put the line back (one restart brings the range back); where the update made the fix impossible here, or
# its files didn't survive, take the fix out instead of keeping it forever (ClawDeck steamos_after_update).
refresh() {
	require_root
	lock
	if ! m_installed || ! m_has grubline "$GRUB_DEFAULT"; then
		say "nothing to do"
		return 0
	fi
	if grub_has_line; then
		say "already in place"
		return 0
	fi
	why=""
	[ "$(boot_backend)" = steamos ] || why="this system can't take the boot switch any more"
	[ -n "$why" ] || why=$(steamos_blocker)
	if [ -z "$why" ]; then
		for f in "$HOOK_CONF" "$HOOK" "$MODPROBE_CONF"; do
			[ -f "$ROOT$f" ] || why="the update didn't keep $f"
		done
		ls "$ROOT$EDID_DIR"/gamecove-*.bin >/dev/null 2>&1 || why="the update didn't keep the corrected EDID"
	fi
	if [ -n "$why" ]; then
		vrr_undo || warn "some changes could not be undone; run remove"
		say "removed: $why"
		return 0
	fi
	grub_line_add "$VRR_KARG" || die "could not put the boot switch back after the SteamOS update"
	say "put back after the SteamOS update: restart the Claw to get 30-120 Hz VRR again"
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
	has_rpm_ostree || return 0
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
		vrr_undo || { warn "some changes could not be undone; run remove"; return 1; }
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
	backend=$(boot_backend)
	case $backend in
	rpm-ostree) ;;
	steamos)
		why=$(steamos_blocker)
		[ -z "$why" ] || die "$why"
		other=$(grub_other_edid)
		[ -z "$other" ] || die "another EDID override is set in $GRUB_DEFAULT ($other); remove it first"
		;;
	*) die "this fix needs Bazzite / Fedora Atomic (rpm-ostree) or SteamOS (its GRUB config and update-grub)" ;;
	esac
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
	m_put "$GC_TMP/patched.bin" "$dest" 644 || { vrr_undo || true; die "could not write $dest"; }
	if [ "$backend" = rpm-ostree ]; then
		if ! rpm-ostree initramfs-etc --track="$dest" >/dev/null; then
			vrr_undo || true
			die "rpm-ostree initramfs-etc failed"
		fi
		m_add initramfs "$dest"
	fi
	put_hook "$(board_name)" "$name" || { vrr_undo || true; die "could not set up the boot hook"; }
	ensure_marker || { vrr_undo || true; die "could not add the gamecove.vrr=1 boot switch"; }
	m_add rev "$REVISION"
	if [ "$backend" = steamos ]; then
		# last in, so undo takes it out first: an interrupted remove never comes back after an update
		keep_text >"$GC_TMP/keep.conf"
		m_put "$GC_TMP/keep.conf" "$KEEP_CONF" 644 || { vrr_undo || true; die "could not write $KEEP_CONF"; }
	fi
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
	vrr_undo || die "some changes could not be undone; see the messages above and run remove again"
	say "removed: restart the Claw to go back to the panel's own 48-120 Hz range"
}

status() {
	if m_installed && is_root && has_rpm_ostree && { [ -n "$(old_kargs)" ] || ! m_has marker "$VRR_KARG"; }; then
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
	if [ "$installed" = yes ] && switch_set && grep -qF "$(board_name) $CONNECTOR:edid/$(file_name "$key")" "$ROOT$HOOK_CONF" 2>/dev/null; then
		pending=yes
	fi
	after_update=no
	if [ "$installed" = yes ] && m_has grubline "$GRUB_DEFAULT" && ! grub_has_line; then
		after_update=yes
	fi
	say "applies=yes"
	say "panel=${key:-unknown}"
	say "validated=$([ -n "$row" ] && echo yes || echo no)"
	say "range=$(printf '%s' "${range:-unknown}" | tr ' ' '-')"
	say "installed=$installed"
	say_revision
	# the panel's own EDID already goes down to our range (a BIOS that corrected it): the system does it.
	# Only readable while ours isn't installed; with ours in place the BIOS rule in fix.json decides.
	if [ "$installed" = no ] && ! theirs "$booted"; then
		if [ -n "$range" ] && [ "${range%% *}" -le "$LO" ] 2>/dev/null; then say "os_fixed=yes"; else say "os_fixed=no"; fi
	fi
	say "pending=$pending"
	say "old_kernel_args=$old"
	say "boot=$(boot_backend)"
	say "boot_switch=$(switch_set && echo yes || echo no)"
	say "after_update=$after_update"
	say "kill_switch=$(kill_switch && echo on || echo off)"
	if theirs "$booted"; then
		say "state=other-override"
	elif [ "$installed" = yes ] && [ "$after_update" = no ] && [ "$range" = "$LO $HI" ] && [ -n "$booted" ]; then
		say "state=on"
	elif [ "$installed" = yes ]; then
		say "state=restart"
	elif [ -z "$row" ]; then
		say "state=unsupported"
	elif [ "$(boot_backend)" = none ] || { [ "$(boot_backend)" = steamos ] && [ -n "$(steamos_blocker)" ]; }; then
		say "state=unsupported"
	else
		say "state=off"
	fi
}

record_home
case ${1:-} in
install) install ;;
update) require_root; gc_root_update ;;
remove) remove ;;
status) status ;;
set)
	case ${2:-} in
	refresh) refresh ;;
	*) die "usage: $0 set refresh" ;;
	esac
	;;
*) die "usage: $0 install|remove|update|status|set refresh" ;;
esac
