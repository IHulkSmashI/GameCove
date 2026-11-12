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
# shellcheck source=fixes/lib/lockdir.sh
. "$(cd "$(dirname "$0")/../lib" && pwd)/lockdir.sh"
# shellcheck source=fixes/lib/ratelimit.sh
. "$(cd "$(dirname "$0")/../lib" && pwd)/ratelimit.sh"
GC_STATE=/var/lib/gamecove
BOARD_WANTED=MS-1T91
FW_DIR=/etc/firmware
# shellcheck disable=SC2034 # used by the gyro and VRR fixes
FW_KARG="firmware_class.path=$FW_DIR"

IP_STOCK=/usr/share/inputplumber/devices/50-msi_claw8_ex_ai_cg3em.yaml
IP_OVERRIDE=/etc/inputplumber/devices.d/50-msi_claw8_ex_ai_cg3em.yaml
IP_MARK="# GameCove override of $IP_STOCK"
IP_MAP_ID=gamecove_claw8ex

# ip_stock_handles_buttons: 0 when InputPlumber's own capability map for board MS-1T91 already takes what this
# firmware sends (Guide from KeyG without KeyF15, i.e. G alone or Win+G = KeyLeftMeta+KeyG; QuickAccess from KeyF15
# alone), so claw8ex-buttons can stand down. Read from the map itself, not from a version or a map name: an update
# can fix claw2 in place or ship a new map that still misses a button. A map id other than claw2 whose file we can't
# find counts as handled (InputPlumber moved on to a map we don't know; ours would replace it blind).
IP_MAPS_DIR=/usr/share/inputplumber/capability_maps
ip_stock_map_id() { sed -n 's/^capability_map_id:[[:space:]]*\([^[:space:]]*\).*/\1/p' "$ROOT$IP_STOCK" 2>/dev/null | head -n 1; }
ip_map_file() { # ip_map_file <id>: the stock capability map file with that id ("" = none)
	for _m in "$ROOT$IP_MAPS_DIR"/*.yaml; do
		[ -f "$_m" ] || continue
		grep -qx "id:[[:space:]]*$1[[:space:]]*" "$_m" && { printf '%s\n' "$_m"; return 0; }
	done
	return 0
}
ip_map_targets() { # ip_map_targets <file>: one line per mapping, "<target button> <sorted source keys joined by +>"
	awk '
		function flush() { if (btn != "") { n = split(keys, a, " "); for (i = 1; i <= n; i++) for (j = i + 1; j <= n; j++) if (a[j] < a[i]) { t = a[i]; a[i] = a[j]; a[j] = t }
			o = ""; for (i = 1; i <= n; i++) o = o (i > 1 ? "+" : "") a[i]; print btn, o } btn = ""; keys = "" }
		/^[[:space:]]*-[[:space:]]+name:/ { flush() }
		/^[[:space:]]*-?[[:space:]]*keyboard:[[:space:]]*/ { k = $0; sub(/.*keyboard:[[:space:]]*/, "", k); sub(/[[:space:]#].*/, "", k); keys = keys " " k }
		/^[[:space:]]*button:[[:space:]]*/ { b = $0; sub(/.*button:[[:space:]]*/, "", b); sub(/[[:space:]#].*/, "", b); btn = b }
		/^[^[:space:]-]/ && !/^mapping:/ { flush() }
		END { flush() }
	' "$1" 2>/dev/null
}
ip_stock_handles_buttons() {
	_id=$(ip_stock_map_id)
	[ -n "$_id" ] || return 1
	_f=$(ip_map_file "$_id")
	if [ -z "$_f" ]; then
		[ "$_id" != claw2 ]
		return
	fi
	_t=$(ip_map_targets "$_f")
	printf '%s\n' "$_t" | grep -qx 'QuickAccess KeyF15' || return 1
	printf '%s\n' "$_t" | grep -qxE 'Guide (KeyG|KeyG\+KeyLeftMeta)'
}

say() { printf '%s\n' "$*" 2>/dev/null || :; } # a reader that stopped early (grep -q) is fine
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
	# a lock left by a run that was killed (its PID is gone) is taken over (lockdir.sh, review L3)
	lockdir_take "$GC_LOCK" 60 || die "another GameCove fix is running ($GC_LOCK)"
	trap 'lockdir_drop "$GC_LOCK"; [ -z "${GC_TMP:-}" ] || rm -rf "$GC_TMP"' EXIT
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

# m_rewrite <command ...>: the change record becomes what the command prints (it must print the same every time it
# runs, from files that don't change meanwhile). Written to a temp file, synced, compared with a second run, then
# renamed over the record: a full disk or a cut leaves the old record whole, never a truncated one (the record is the
# only way back). Status 0 or 1 from the command both mean "printed what it had" (grep with nothing left is 1).
m_rewrite() {
	_mt="$MANIFEST.tmp"
	"$@" >"$_mt" 2>/dev/null
	[ $? -le 1 ] || { rm -f "$_mt"; return 1; }
	sync "$_mt" 2>/dev/null || sync 2>/dev/null || true
	if ! "$@" 2>/dev/null | cmp -s - "$_mt"; then
		rm -f "$_mt"
		return 1
	fi
	mv -f "$_mt" "$MANIFEST" || { rm -f "$_mt"; return 1; }
}

# m_drop <line> ...: take these whole lines out of the record (m_rewrite).
m_drop() {
	_m_gone=$(printf '%s\n' "$@")
	m_rewrite _m_kept
}
_m_kept() { printf '%s\n' "$_m_gone" | grep -vxF -f - "$MANIFEST"; }

_m_reversed() { sed -n '1!G;h;$p' "$_m_left"; }

# The revision that was installed ("rev <n>" in the manifest; 1 for installs from before it was recorded).
m_rev() {
	_r=$(sed -n 's/^rev \([0-9][0-9]*\)$/\1/p' "$MANIFEST" 2>/dev/null | tail -n 1)
	printf '%s' "${_r:-1}"
}

# status lines every fix prints: this script's revision and, when installed, the one that was installed.
say_revision() {
	say "revision=${REVISION:-1}"
	! m_installed || say "installed_revision=$(m_rev)"
}

# update: bring an installed fix to this revision. These fixes change boot configuration, so there is
# no in-place swap: the old version is taken out by its own record, then this one goes in. When that
# fails, install's own undo leaves the system stock (never half of each), and exit 1 says so.
gc_root_update() {
	if ! m_installed; then
		say "not installed"
		return 0
	fi
	sh "$0" remove || die "the installed version could not be taken out; nothing else was changed"
	if ! sh "$0" install; then
		die "the new version could not be installed; the old one is out and the system is as shipped. Apply the fix again from GameCove's Fixes page"
	fi
	say "updated"
}

# mkdir -p that records every folder it creates, so undo takes them away again.
m_mkdir() {
	[ -d "$ROOT$1" ] && return 0
	m_mkdir "$(dirname "$1")" || return 1
	# recorded first: a cut between the two leaves a record of a folder that isn't there (undo skips it), never a
	# folder nothing remembers
	m_add dir "$1"
	mkdir "$ROOT$1" || return 1
}

# m_put <source file> <real dest path> <mode>: written atomically; an existing file is backed up first.
m_put() {
	m_mkdir "$(dirname "$2")" || return 1
	if [ -e "$ROOT$2" ] && ! m_has file "$2" && ! m_has replaced "$2"; then
		mkdir -p "$M_DIR/backup$(dirname "$2")" || return 1
		cp -p "$ROOT$2" "$M_DIR/backup$2" || return 1
		m_add replaced "$2"
	fi
	# the file is recorded before it is written: a cut after the rename but before the record left a file that
	# remove never took out
	m_has file "$2" || m_has replaced "$2" || m_add file "$2"
	if ! { cp "$1" "$ROOT$2.gamecove-tmp" && chmod "$3" "$ROOT$2.gamecove-tmp" && mv -f "$ROOT$2.gamecove-tmp" "$ROOT$2"; }; then
		rm -f "$ROOT$2.gamecove-tmp"
		return 1
	fi
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
		karg | marker) karg_release "$arg" "$FIX" || { done_ok=0; boot_kept=1; } ;;
		initramfs) rpm-ostree initramfs-etc --untrack="$arg" >/dev/null || { done_ok=0; boot_kept=1; } ;;
		grubline) grub_line_remove "$arg" || { done_ok=0; boot_kept=1; } ;;
		ipflag) ip_flag_off "$arg" || done_ok=0 ;;
		rev) ;; # the installed revision (m_rev): nothing to undo
		clawdeck) ;; # ClawDeck's file was adopted; the flag's undo (ip_regen) puts it back
		*) warn "unknown manifest line: $kind $arg" ;;
		esac
		[ "$done_ok" = 1 ] || printf '%s %s\n' "$kind" "$arg" >>"$M_DIR/left"
	done 3<"$M_DIR/undo"
	rm -f "$M_DIR/undo"
	[ "$units" = 0 ] || systemctl daemon-reload >/dev/null 2>&1 || true
	if [ -s "$M_DIR/left" ]; then
		_m_left=$M_DIR/left
		# a record that can't be written whole stays as it was (all of it, so remove retries everything)
		m_rewrite _m_reversed || warn "could not update the change record"
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

# ---- boot configuration on SteamOS (no rpm-ostree) ---------------------------------------------------------------
# Ported from ClawDeck's edid.py (boot_backend "steamos-grub", conf_enable, conf_disable, steamos_after_update, built
# from SteamOS's own steamos-customizations: grub/bin/update-grub and atomic-update): Holo's update-grub runs
# grub-mkconfig on /etc/default/grub and writes /efi/EFI/SteamOS/grub.cfg, the documented way to add kernel arguments
# there. GameCove appends ONE line ending in its marker and undo deletes exactly the lines with the marker; nothing
# else in the file is touched. A SteamOS update keeps only the /etc files on its keep list (plus drop-ins in
# /etc/atomic-update.conf.d), so the fix keep-lists its own files only, never /etc/default/grub (that would hide
# Valve's future changes to it); after an update `set refresh` puts the one line back on top of Valve's new file.
GRUB_DEFAULT=/etc/default/grub
STEAMOS_GRUB_CFG=/efi/EFI/SteamOS/grub.cfg
# shellcheck disable=SC2034 # used by the VRR fix
KEEP_DIR=/etc/atomic-update.conf.d

os_id() { sed -n 's/^ID=//p' "$ROOT/etc/os-release" 2>/dev/null | tr -d "\"'" | head -n 1; }
is_steamos() { [ "$(os_id)" = steamos ]; }

# grub_mark <fix>: the marker that ends each of the fix's lines in /etc/default/grub.
grub_mark() { printf '# GameCove %s' "$1"; }

# grub_has_line [<args>]: our line is in /etc/default/grub; with <args> also in the menu SteamOS boots from (its
# grub.cfg, when there is one): a rebuild that failed after the line went in leaves the file marked and the menu not.
grub_has_line() {
	grep -qF "$(grub_mark "$FIX")" "$ROOT$GRUB_DEFAULT" 2>/dev/null || return 1
	[ -z "${1:-}" ] || [ ! -f "$ROOT$STEAMOS_GRUB_CFG" ] || grep -qF -- "$1" "$ROOT$STEAMOS_GRUB_CFG" 2>/dev/null
}

# grub_write <file> <content file>: atomically, into the real file (a symlinked config stays one), mode kept.
# The copy is written, flushed and compared with what was meant to be written before it replaces anything: a full
# or failing disk leaves the file as it was (it used to be replaced by an empty one, and update-grub then built the
# boot menu from that).
grub_write() {
	_real=$(readlink -f "$ROOT$1" 2>/dev/null) || _real=$ROOT$1
	_gt=$_real.gamecove-tmp
	rm -f "$_gt"
	if [ -e "$_real" ]; then
		cp -p "$_real" "$_gt" 2>/dev/null || { rm -f "$_gt"; return 1; }
	fi
	if ! { cat "$2" >"$_gt" && sync "$_gt" 2>/dev/null; cmp -s "$2" "$_gt"; }; then
		rm -f "$_gt"
		return 1
	fi
	mv -f "$_gt" "$_real" || { rm -f "$_gt"; return 1; }
}

# update-grub as its own systemd unit when it can (a Steam or GameCove restart can't kill it halfway), else directly.
grub_regen() {
	if [ -z "$ROOT" ] && command -v systemd-run >/dev/null 2>&1; then
		systemd-run --wait --collect --pipe --quiet --unit "gamecove-update-grub-$$" update-grub >/dev/null 2>&1
	else
		update-grub >/dev/null 2>&1
	fi
}

# grub_line_add <args>: GameCove's line (marker on the same line: the file is a shell script grub-mkconfig sources),
# the boot menu rebuilt, and checked: SteamOS's grub.cfg must carry the arguments, or it is all taken back. The
# line counts as there (marked) only once the menu took it: when update-grub fails or leaves it out, the file goes
# back to how it was, so the next refresh sees the line missing and tries again (it used to find "already in place"
# and never retried).
grub_line_add() {
	_tmp=$(mktemp) || return 1
	_orig=$(mktemp) || { rm -f "$_tmp"; return 1; }
	# the file as it is now, or as "absent"; a file that is there but can't be read is never replaced by a guess
	_had=0
	if [ -e "$ROOT$GRUB_DEFAULT" ]; then
		_had=1
		cat "$ROOT$GRUB_DEFAULT" >"$_orig" 2>/dev/null || { rm -f "$_tmp" "$_orig"; return 1; }
	fi
	grep -vF "$(grub_mark "$FIX")" "$_orig" >"$_tmp" 2>/dev/null
	[ $? -le 1 ] || { rm -f "$_tmp" "$_orig"; return 1; }   # 1 = nothing left, fine; more = a read error
	printf 'GRUB_CMDLINE_LINUX_DEFAULT="${GRUB_CMDLINE_LINUX_DEFAULT} %s"  %s\n' "$1" "$(grub_mark "$FIX")" >>"$_tmp"
	if ! grub_write "$GRUB_DEFAULT" "$_tmp"; then
		rm -f "$_tmp" "$_orig"
		return 1
	fi
	rm -f "$_tmp"
	_why=""
	grub_regen || _why="update-grub failed"
	if [ -z "$_why" ] && [ -f "$ROOT$STEAMOS_GRUB_CFG" ] && ! grep -qF -- "$1" "$ROOT$STEAMOS_GRUB_CFG"; then
		_why="SteamOS's boot menu didn't take the setting (update-grub left it out)"
	fi
	if [ -n "$_why" ]; then
		warn "$_why"
		# not marked after all: the file as it was, and the boot menu rebuilt from it (best effort). When the
		# file can't be put back, update-grub is NOT run: it would build the menu from what is there now.
		if [ "$_had" = 1 ]; then
			grub_write "$GRUB_DEFAULT" "$_orig" || { warn "could not put $GRUB_DEFAULT back; the boot menu was not rebuilt"; rm -f "$_orig"; return 1; }
		else
			rm -f "$ROOT$GRUB_DEFAULT"
		fi
		grub_regen || true
		rm -f "$_orig"
		return 1
	fi
	rm -f "$_orig"
}

# grub_line_remove <file>: only GameCove's lines out again, and the boot menu rebuilt.
grub_line_remove() {
	if grep -qF "$(grub_mark "$FIX")" "$ROOT$1" 2>/dev/null; then
		_tmp=$(mktemp) || return 1
		grep -vF "$(grub_mark "$FIX")" "$ROOT$1" >"$_tmp" 2>/dev/null
		[ $? -le 1 ] || { rm -f "$_tmp"; return 1; }
		grub_write "$1" "$_tmp" || { rm -f "$_tmp"; return 1; }
		rm -f "$_tmp"
	fi
	grub_regen || { warn "update-grub failed"; return 1; }
}

# firmware_class.path must be ours (/etc/firmware) or unset.
require_fw_path_free() {
	cur=$(karg_value firmware_class.path "$(karg_pending) $(cmdline)")
	[ -z "$cur" ] || [ "$cur" = "$FW_DIR" ] || die "firmware_class.path is already set to $cur; not changing it"
}

# ---- InputPlumber override (board MS-1T91) --------------------------------------------------------------------
IP_FLAGS="$ROOT$GC_STATE/inputplumber"

ip_override_ours() { [ -f "$ROOT$IP_OVERRIDE" ] && head -n 1 "$ROOT$IP_OVERRIDE" | grep -qxF "$IP_MARK"; }

# ClawDeck (same Claw, many users come from it) leaves its own override of this file: its header says
# "ClawDeck override of the stock file (only capability_map_id differs)", the map it points at is
# /etc/inputplumber/capability_maps/msiclaw_claw8ex.yaml. It is recognised, never refused: the first
# GameCove feature that needs the override backs it up (ip_adopt_clawdeck) and builds GameCove's own on
# top, keeping ClawDeck's capability map; the last one to go puts ClawDeck's file back (ip_clawdeck_restore).
CD_BACKUP=$GC_STATE/backup/clawdeck
ip_override_clawdeck() { [ -f "$ROOT$IP_OVERRIDE" ] && head -n 3 "$ROOT$IP_OVERRIDE" | grep -qi 'ClawDeck override'; }
ip_clawdeck_backup() { printf '%s%s/devices.d/%s' "$ROOT" "$CD_BACKUP" "${IP_OVERRIDE##*/}"; }
ip_clawdeck_backed_up() { [ -f "$(ip_clawdeck_backup)" ]; }

# Back ClawDeck's override up (once), before GameCove's replaces it. Nothing to do for any other file.
ip_adopt_clawdeck() {
	ip_override_clawdeck || return 0
	_cb=$(ip_clawdeck_backup)
	[ ! -f "$_cb" ] || return 0
	mkdir -p "${_cb%/*}" && cp -p "$ROOT$IP_OVERRIDE" "$_cb" || { warn "could not back up ClawDeck's $IP_OVERRIDE"; return 1; }
	say "ClawDeck's override of the controller config is backed up in $CD_BACKUP; Undo puts it back"
}

# The last GameCove feature is out: ClawDeck's override goes back where it was (when what's there now is
# GameCove's or nothing); the backup is removed. Sets _cd_restored=1 when the file was put back.
ip_clawdeck_restore() {
	_cd_restored=0
	_cb=$(ip_clawdeck_backup)
	[ -f "$_cb" ] || return 0
	if [ ! -e "$ROOT$IP_OVERRIDE" ] || ip_override_ours; then
		mkdir -p "$ROOT${IP_OVERRIDE%/*}" && cp -p "$_cb" "$ROOT$IP_OVERRIDE.gamecove-tmp" && mv -f "$ROOT$IP_OVERRIDE.gamecove-tmp" "$ROOT$IP_OVERRIDE" || {
			rm -f "$ROOT$IP_OVERRIDE.gamecove-tmp"
			warn "could not put ClawDeck's $IP_OVERRIDE back; the copy is in $CD_BACKUP"
			return 1
		}
		_cd_restored=1
	fi
	rm -f "$_cb"
	rmdir "$ROOT$CD_BACKUP/devices.d" "$ROOT$CD_BACKUP" "$ROOT$GC_STATE/backup" 2>/dev/null || true
	return 0
}

# An override someone else wrote is never touched (ClawDeck's is adopted, see above).
ip_require_free() {
	[ ! -e "$ROOT$IP_OVERRIDE" ] || ip_override_ours || ip_override_clawdeck || die "$IP_OVERRIDE exists and isn't GameCove's or ClawDeck's; leaving it"
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
	mkdir -p "$IP_FLAGS" && : >"$IP_FLAGS/$1" && ip_adopt_clawdeck && ip_regen
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
	# Our face-button map only replaces a stock one that misses what this firmware sends. Once
	# InputPlumber's own map takes both buttons (ip_stock_handles_buttons) the override keeps it, so an
	# InputPlumber update that fixes the buttons is used at once: the no-password `set refresh` GameCove
	# runs after such an update rebuilds the override this way, and our two files never shadow the
	# system's fix while the real remove waits for the admin password.
	ip_flag buttons && ! ip_stock_handles_buttons && swap=1
	map_id=$IP_MAP_ID
	if [ "$swap" = 0 ] && ip_clawdeck_backed_up; then
		# adopted from ClawDeck without the face-button feature: ClawDeck's capability map stays in use
		_cdm=$(sed -n 's/^capability_map_id:[[:space:]]*\([^[:space:]]*\).*/\1/p' "$(ip_clawdeck_backup)" | head -n 1)
		if [ -n "$_cdm" ] && [ "$_cdm" != "$(ip_stock_map_id)" ]; then
			swap=1
			map_id=$_cdm
		fi
	fi
	ip_flag imu && ! grep -q 'name: gyro_3d' "$ROOT$IP_STOCK" && imu=1
	snip="$IP_FLAGS/.snippet"
	: >"$snip"
	if [ "$imu" = 1 ]; then
		ip_imu_text >>"$snip"
		! ip_flag accel || ip_accel_text >>"$snip"
	fi
	printf '%s\n# Delete this file and restart inputplumber to go back to the stock config.\n' "$IP_MARK"
	printf '# stock-sha256: %s\n' "$(ip_stock_sha)"
	awk -v swap="$swap" -v imu="$imu" -v snip="$snip" -v mapid="$map_id" '
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
		_gone=0
		if ip_override_ours; then
			rm -f "$ROOT$IP_OVERRIDE"
			_gone=1
		fi
		ip_clawdeck_restore || return 1
		if [ "$_gone" = 1 ]; then
			ip_tidy_dirs
		fi
		if [ "$_gone" = 1 ] || [ "$_cd_restored" = 1 ]; then
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
	# the same override as now: nothing to write and no InputPlumber restart (review L4)
	if cmp -s "$out" "$ROOT$IP_OVERRIDE"; then
		rm -f "$out"
		return 0
	fi
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
