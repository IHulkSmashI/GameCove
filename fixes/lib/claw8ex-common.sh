# shellcheck shell=sh
# Shared by the MSI Claw 8 EX fixes (claw8ex-buttons, claw8ex-gyro, claw8ex-vrr). Sourced, never run.
#
# Three things more than one fix touches live here so they agree:
#   - the change record (manifest) every fix keeps, and its undo;
#   - kernel arguments with a holder count (firmware_class.path is needed by the gyro AND the VRR fix:
#     it is added by whoever needs it first and removed only when no fix holds it);
#   - the InputPlumber override for board MS-1T91, which the face buttons and the gyro both edit. It is
#     always rebuilt from the stock file plus the features switched on, so neither fix can undo the other.
#     Its header records the stock file's sha256; `set refresh` (no password, also run by GameCove's
#     "what changed" check at every start) rebuilds it when an OS update changed the stock file, or
#     drops it (back to stock) when the new layout can't be edited safely (review S1-4).
#
# Every path is prefixed with $GAMECOVE_ROOT (empty on a real system, a fake root in tests).
# Paths written to the manifest and handed to rpm-ostree are real paths, without the prefix.

ROOT=${GAMECOVE_ROOT:-}
GC_STATE=/var/lib/gamecove
BOARD_WANTED=MS-1T91
FW_DIR=/etc/firmware
# shellcheck disable=SC2034 # used by the gyro and VRR fixes
FW_KARG="firmware_class.path=$FW_DIR"

IP_STOCK=/usr/share/inputplumber/devices/50-msi_claw8_ex_ai_cg3em.yaml
IP_OVERRIDE=/etc/inputplumber/devices.d/50-msi_claw8_ex_ai_cg3em.yaml
IP_MARK="# GameCove override of $IP_STOCK"
IP_MAP_ID=gamecove_claw8ex

say() { printf '%s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

board_name() { cat "$ROOT/sys/class/dmi/id/board_name" 2>/dev/null | tr -d '[:space:]'; }

require_board() {
	[ "$(board_name)" = "$BOARD_WANTED" ] || die "this fix is only for the MSI Claw 8 EX AI+ (board $BOARD_WANTED); this board is '$(board_name)'"
}

require_root() {
	[ -n "$ROOT" ] || [ "$(id -u)" -eq 0 ] || die "needs root (run through gamecove-fix with pkexec)"
}

# One fix at a time. /run exists on every real system; tests create it in the fake root.
lock() {
	GC_LOCK="$ROOT/run/gamecove-fix.lock"
	n=0
	while ! mkdir "$GC_LOCK" 2>/dev/null; do
		n=$((n + 1))
		[ "$n" -lt 60 ] || die "another GameCove fix is running ($GC_LOCK)"
		sleep 1
	done
	trap 'rmdir "$GC_LOCK" 2>/dev/null; [ -z "${GC_TMP:-}" ] || rm -rf "$GC_TMP"' EXIT
	trap 'exit 1' INT TERM HUP PIPE
}

# ---- the change record -----------------------------------------------------------------------------------------
m_init() {
	FIX=$1
	M_DIR="$ROOT$GC_STATE/fixes/$FIX"
	MANIFEST="$M_DIR/manifest"
}

m_installed() { [ -s "$MANIFEST" ]; }

m_add() {
	mkdir -p "$M_DIR"
	printf '%s %s\n' "$1" "$2" >>"$MANIFEST"
}

m_has() { [ -f "$MANIFEST" ] && grep -qxF "$1 $2" "$MANIFEST"; }

# mkdir -p that records every folder it creates, so undo takes them away again.
m_mkdir() {
	[ -d "$ROOT$1" ] && return 0
	m_mkdir "$(dirname "$1")" || return 1
	mkdir "$ROOT$1" || return 1
	m_add dir "$1"
}

# m_put <source file> <real dest path> <mode>: written atomically; an existing file is backed up first.
m_put() {
	m_mkdir "$(dirname "$2")" || return 1
	if [ -e "$ROOT$2" ] && ! m_has file "$2" && ! m_has replaced "$2"; then
		mkdir -p "$M_DIR/backup$(dirname "$2")" || return 1
		cp -p "$ROOT$2" "$M_DIR/backup$2" || return 1
		m_add replaced "$2"
	fi
	if ! { cp "$1" "$ROOT$2.gamecove-tmp" && chmod "$3" "$ROOT$2.gamecove-tmp" && mv -f "$ROOT$2.gamecove-tmp" "$ROOT$2"; }; then
		rm -f "$ROOT$2.gamecove-tmp"
		return 1
	fi
	m_has file "$2" || m_has replaced "$2" || m_add file "$2"
}

# Undo everything in the manifest, newest first. Keeps going on errors; what couldn't be undone stays in
# the manifest, so running remove again retries just those steps.
# One exception keeps the system bootable as it is: once a kernel argument or initramfs entry can't be
# taken out, the boot configuration may still point at this fix's files (EDID, firmware), so the files,
# their folders and their initramfs tracking (all older in the manifest) are left alone and stay recorded
# for the retry. Services and InputPlumber flags are still undone.
m_undo() {
	[ -f "$MANIFEST" ] || { m_tidy; return 0; }
	units=0
	boot_kept=0
	sed -n '1!G;h;$p' "$MANIFEST" >"$M_DIR/undo"
	: >"$M_DIR/left"
	# fd 3, so nothing run in the loop can read the list
	while read -r kind arg <&3; do
		done_ok=1
		if [ "$boot_kept" = 1 ]; then
			case $kind in
			file | replaced | dir | initramfs)
				printf '%s %s\n' "$kind" "$arg" >>"$M_DIR/left"
				continue
				;;
			esac
		fi
		case $kind in
		file) rm -f "$ROOT$arg" ;;
		replaced) mv -f "$M_DIR/backup$arg" "$ROOT$arg" || done_ok=0 ;;
		dir) rmdir "$ROOT$arg" 2>/dev/null || printf '%s\n' "$arg" >>"$ROOT$GC_STATE/pending-dirs" ;;
		unit)
			systemctl disable --now "$arg" >/dev/null 2>&1 || warn "could not stop $arg"
			units=1
			;;
		karg) karg_release "$arg" "$FIX" || { done_ok=0; boot_kept=1; } ;;
		initramfs) rpm-ostree initramfs-etc --untrack="$arg" >/dev/null || { done_ok=0; boot_kept=1; } ;;
		ipflag) ip_flag_off "$arg" || done_ok=0 ;;
		*) warn "unknown manifest line: $kind $arg" ;;
		esac
		[ "$done_ok" = 1 ] || printf '%s %s\n' "$kind" "$arg" >>"$M_DIR/left"
	done 3<"$M_DIR/undo"
	rm -f "$M_DIR/undo"
	[ "$units" = 0 ] || systemctl daemon-reload >/dev/null 2>&1 || true
	if [ -s "$M_DIR/left" ]; then
		sed -n '1!G;h;$p' "$M_DIR/left" >"$MANIFEST"
		rm -f "$M_DIR/left"
		return 1
	fi
	rm -rf "$M_DIR"
	m_tidy
}

# After undo: InputPlumber folders once no feature uses them, folders another fix still used when their
# creator was removed (e.g. /etc/firmware, shared by the gyro and VRR fixes), then empty state folders.
m_tidy() {
	if ! ip_flag buttons && ! ip_flag imu; then
		ip_tidy_dirs
		rmdir "$IP_FLAGS" 2>/dev/null || true
	fi
	pd="$ROOT$GC_STATE/pending-dirs"
	if [ -f "$pd" ]; then
		sort -u "$pd" | awk '{ print length($0), $0 }' | sort -rn | cut -d ' ' -f 2- >"$pd.try"
		: >"$pd"
		while read -r d; do
			[ -d "$ROOT$d" ] || continue
			rmdir "$ROOT$d" 2>/dev/null || printf '%s\n' "$d" >>"$pd"
		done <"$pd.try"
		rm -f "$pd.try"
		[ -s "$pd" ] || rm -f "$pd"
	fi
	state_tidy
}

# Remove GameCove's empty state folders (never /var/lib itself).
state_tidy() {
	for d in "$ROOT$GC_STATE/fixes" "$ROOT$GC_STATE/kargs" "$ROOT$GC_STATE/inputplumber" "$ROOT$GC_STATE"; do
		rmdir "$d" 2>/dev/null || true
	done
}

# ---- kernel arguments (Bazzite / Fedora Atomic: rpm-ostree) ---------------------------------------------------
has_rpm_ostree() { command -v rpm-ostree >/dev/null 2>&1; }

# Arguments of the deployment the next boot uses.
karg_pending() { rpm-ostree kargs 2>/dev/null; }

cmdline() { cat "$ROOT/proc/cmdline" 2>/dev/null; }

# karg_value <name> <text>: value of name=... in a kernel command line, or empty.
karg_value() {
	printf '%s\n' "$2" | tr ' ' '\n' | sed -n "s|^$1=||p" | head -n 1
}

karg_in() { printf '%s\n' "$2" | tr ' ' '\n' | grep -qxF "$1"; }

karg_dir() { printf '%s%s/kargs/%s' "$ROOT" "$GC_STATE" "$(printf '%s' "$1" | tr '/=:. ' '_____')"; }

# karg_hold <arg> <holder>: make sure <arg> is set and count <holder> as needing it.
karg_hold() {
	kd=$(karg_dir "$1")
	if [ ! -d "$kd" ]; then
		mkdir -p "$kd" || return 1
		if karg_in "$1" "$(karg_pending)"; then
			: >"$kd/.preexisting"            # set by someone else: never ours to remove
		elif ! rpm-ostree kargs --append-if-missing="$1" >/dev/null; then
			rm -rf "$kd"
			return 1
		fi
	fi
	: >"$kd/$2"
}

# karg_release <arg> <holder>: drop <holder>; the last holder out removes the argument (unless it was there before).
karg_release() {
	kd=$(karg_dir "$1")
	[ -d "$kd" ] || return 0
	rm -f "$kd/$2"
	set -- "$1" "$kd"/*
	[ -e "$2" ] && return 0
	kd=$(karg_dir "$1")
	if [ ! -e "$kd/.preexisting" ]; then
		rpm-ostree kargs --delete-if-present="$1" >/dev/null || return 1
	fi
	rm -rf "$kd"
	state_tidy
}

# firmware_class.path must be ours (/etc/firmware) or unset.
require_fw_path_free() {
	cur=$(karg_value firmware_class.path "$(karg_pending) $(cmdline)")
	[ -z "$cur" ] || [ "$cur" = "$FW_DIR" ] || die "firmware_class.path is already set to $cur; not changing it"
}

# ---- InputPlumber override (board MS-1T91) --------------------------------------------------------------------
IP_FLAGS="$ROOT$GC_STATE/inputplumber"

ip_override_ours() { [ -f "$ROOT$IP_OVERRIDE" ] && head -n 1 "$ROOT$IP_OVERRIDE" | grep -qxF "$IP_MARK"; }

# An override someone else wrote is never touched.
ip_require_free() {
	[ ! -e "$ROOT$IP_OVERRIDE" ] || ip_override_ours || die "$IP_OVERRIDE exists and isn't GameCove's; leaving it"
	[ -f "$ROOT$IP_STOCK" ] || die "$IP_STOCK not found: this InputPlumber has no config for the Claw 8 EX"
}

ip_flag() { [ -e "$IP_FLAGS/$1" ]; }

ip_stock_sha() { sha256sum "$ROOT$IP_STOCK" 2>/dev/null | cut -d ' ' -f 1; }

# The stock file's sha256 the override was built from ("" for an override older than this check).
ip_override_sha() { sed -n 's/^# stock-sha256: \([0-9a-f]*\)$/\1/p' "$ROOT$IP_OVERRIDE" 2>/dev/null | head -n 1; }

# Our override no longer matches the stock file it shadows (an OS / InputPlumber update changed it).
ip_stale() {
	ip_override_ours || return 1
	[ "$(ip_override_sha)" != "$(ip_stock_sha)" ]
}

# none | current | stale | dropped (rebuilding failed, InputPlumber runs the stock file)
ip_override_state() {
	if ip_override_ours; then
		if ip_stale; then echo stale; else echo current; fi
	elif [ -f "$IP_FLAGS/stale" ]; then
		echo dropped
	else
		echo none
	fi
}

# Rebuild a stale override from the current stock file. If the new stock file can't be edited the
# way we expect (or is gone), remove the override so InputPlumber uses the stock file: a frozen copy
# of an old schema could stop the controller from working. The flags stay, so the next refresh (after
# a GameCove update that knows the new layout) brings the features back.
ip_refresh() {
	if ! ip_override_ours; then
		# dropped earlier: try again (a GameCove update may handle the new layout)
		if [ -f "$IP_FLAGS/stale" ] && { ip_flag buttons || ip_flag imu; } && [ -f "$ROOT$IP_STOCK" ] && [ ! -e "$ROOT$IP_OVERRIDE" ]; then
			ip_regen >/dev/null 2>&1 && rm -f "$IP_FLAGS/stale" && say "override rebuilt from the current stock file"
		fi
		return 0
	fi
	ip_stale || { say "override is current"; return 0; }
	if [ -f "$ROOT$IP_STOCK" ] && ip_regen; then
		rm -f "$IP_FLAGS/stale"
		say "override rebuilt from the updated stock file"
		return 0
	fi
	rm -f "$ROOT$IP_OVERRIDE" "$ROOT$IP_OVERRIDE.gamecove-tmp"
	mkdir -p "$IP_FLAGS" && printf '%s\n' "$(ip_stock_sha)" >"$IP_FLAGS/stale"
	ip_restart
	warn "the stock InputPlumber file changed in a way GameCove can't edit safely; using it unchanged"
	return 0
}

ip_flag_on() {
	mkdir -p "$IP_FLAGS" && : >"$IP_FLAGS/$1" && ip_regen
}

ip_flag_off() {
	rm -f "$IP_FLAGS/$1"
	ip_regen
}

ip_imu_text() {
	cat <<'EOF'
  # IMU: gyro_3d from the sensor hub (GameCove claw8ex-gyro: HID-BPF relabel + MSI's ISH firmware)
  - group: imu
    iio:
      name: gyro_3d
    config:
      imu:
        mount_matrix:
          x: [1, 0, 0]
          y: [0, 1, 0]
          z: [0, 0, 1]

EOF
}

ip_accel_text() {
	cat <<'EOF'
  # Accelerometer (claw8ex-gyro "set accel-on"): Steam fuses it with the gyro; gyro aim is better without it
  - group: imu
    iio:
      name: accel_3d
    config:
      imu:
        mount_matrix:
          x: [1, 0, 0]
          y: [0, 1, 0]
          z: [0, 0, 1]

EOF
}

# The override text for the flags that are on, on stdout. Fails if the stock file has an unexpected shape.
ip_render() {
	swap=0
	imu=0
	ip_flag buttons && swap=1
	ip_flag imu && ! grep -q 'name: gyro_3d' "$ROOT$IP_STOCK" && imu=1
	snip="$IP_FLAGS/.snippet"
	: >"$snip"
	if [ "$imu" = 1 ]; then
		ip_imu_text >>"$snip"
		! ip_flag accel || ip_accel_text >>"$snip"
	fi
	printf '%s\n# Delete this file and restart inputplumber to go back to the stock config.\n' "$IP_MARK"
	printf '# stock-sha256: %s\n' "$(ip_stock_sha)"
	awk -v swap="$swap" -v imu="$imu" -v snip="$snip" -v mapid="$IP_MAP_ID" '
		swap == 1 && !swapped && /^capability_map_id:[ \t]*[^ \t]/ { print "capability_map_id: " mapid; swapped = 1; next }
		imu == 1 && !inserted && (/^# Optional configuration/ || /^options:/) {
			while ((getline line < snip) > 0) print line
			inserted = 1
		}
		{ print }
		END { if ((swap == 1 && !swapped) || (imu == 1 && !inserted)) exit 3 }
	' "$ROOT$IP_STOCK"
}

# Rebuild (or remove) the override from the flags and restart InputPlumber.
ip_regen() {
	if ! ip_flag buttons && ! ip_flag imu; then
		rm -f "$IP_FLAGS/accel" "$IP_FLAGS/.snippet"
		if ip_override_ours; then
			rm -f "$ROOT$IP_OVERRIDE"
			ip_tidy_dirs
			ip_restart
		fi
		rmdir "$IP_FLAGS" 2>/dev/null || true
		return 0
	fi
	ip_mkdirs || return 1
	out="$ROOT$IP_OVERRIDE.gamecove-tmp"
	if ! ip_render >"$out"; then
		rm -f "$out" "$IP_FLAGS/.snippet"
		warn "$IP_STOCK has an unexpected layout; override not written"
		return 1
	fi
	rm -f "$IP_FLAGS/.snippet"
	chmod 644 "$out" && mv -f "$out" "$ROOT$IP_OVERRIDE" || return 1
	ip_restart
}

# Folders the override and the face-button map need; the ones created are remembered so they go when
# the last InputPlumber feature goes.
ip_mkdirs() {
	mkdir -p "$IP_FLAGS" || return 1
	for d in /etc/inputplumber /etc/inputplumber/devices.d /etc/inputplumber/capability_maps.d; do
		if [ ! -d "$ROOT$d" ]; then
			mkdir "$ROOT$d" || return 1
			printf '%s\n' "$d" >>"$IP_FLAGS/.dirs"
		fi
	done
}

# Remove the folders ip_mkdirs created, deepest first; any still in use stay listed for later.
ip_tidy_dirs() {
	[ -f "$IP_FLAGS/.dirs" ] || return 0
	sed -n '1!G;h;$p' "$IP_FLAGS/.dirs" >"$IP_FLAGS/.dirs.rev"
	: >"$IP_FLAGS/.dirs.keep"
	while read -r d; do
		rmdir "$ROOT$d" 2>/dev/null || printf '%s\n' "$d" >>"$IP_FLAGS/.dirs.keep"
	done <"$IP_FLAGS/.dirs.rev"
	if [ -s "$IP_FLAGS/.dirs.keep" ]; then
		sed -n '1!G;h;$p' "$IP_FLAGS/.dirs.keep" >"$IP_FLAGS/.dirs"
	else
		rm -f "$IP_FLAGS/.dirs"
	fi
	rm -f "$IP_FLAGS/.dirs.rev" "$IP_FLAGS/.dirs.keep"
}

ip_restart() {
	systemctl restart inputplumber >/dev/null 2>&1 || warn "inputplumber did not restart; restart the device to apply"
}
