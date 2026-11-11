# shellcheck shell=sh
# Shared engine for GameCove's small file fixes: a udev rule (or another small config file) that
# fixes one thing on a few handhelds, applied at once and on every boot, fully undone by `remove`.
# Sourced by fixes/<name>/fix.sh, never run. See fixes/README.md.
#
# A fix sets, before sourcing:
#   NAME         its folder name (gamecove-fix <NAME> ...)
#   DEVICES      "@" = the handhelds fixes/lib/fix-devices.txt names for it (resolved from the fix's
#                trait selectors in app/data/fixes.json); or devices.json ids (space separated);
#                "*" = any handheld in devices.txt
#   FILES        real paths it writes (space separated, no spaces inside), e.g. /etc/udev/rules.d/...
#   RELOAD       "udev" to reload udev rules after a change, else empty
#   REVISION     optional: the fix's revision (a whole number, the same as "revision" in its fix.json;
#                1 when unset). Bump both when the files the fix writes change: installed copies are
#                then brought up to date by `update` (docs/FIXES.md, "When a fix changes").
# and defines:
#   file_text <path>   prints the content for one of FILES (the first line must hold GC_MARK)
#   hw_present         0 when the part the fix is for is in this handheld (else: not needed)
#   os_fixed           0 when the system already does this by itself (another rule, a newer kernel)
#   apply_now          optional: make it take effect now (save originals with save_value first)
#                      (file_text builds udev lines with gc_rule_lines, which adds the DMI match)
#   revert_now         optional: undo apply_now (restore_values does the usual thing)
#   verify             optional: 0 when the fix just written really works (update rolls back when not)
#   blocked            optional: prints why it can't be applied on this machine now ("" = it can);
#                      install refuses (exit 3) and status says state=unsupported, reason=<text>
#
# Commands: install | remove | update | status | set on | set off (on = install, off = remove; all through
# gamecove-fix with the administrator password since review S3-2: a udev rule that acts on every
# boot isn't a day-to-day setting). status prints applies=, installed=, os_fixed=,
# hw=, revision= (and installed_revision= when installed), then state= (on | off | os-fixed |
# not-needed | partial | n/a).
# update: only when installed. Rewrites the fix's files from this revision of the script; when that
# fails (a file can't be written, verify says no) every file, the saved values and the record are put
# back exactly as they were (exit 1). Never leaves half of each.
#
# Only the handhelds in DEVICES: the id comes from fixes/lib/devices.txt (generated from
# devices.json). Rules themselves also match the DMI ids of every handheld in DEVICES
# (gc_rule_lines), so on a drive that boots several handhelds a rule written on one acts only on
# those that share the trait the fix is for, never on another.
#
# GAMECOVE_ROOT prefixes every path (tests); GAMECOVE_CHANGES_LOG gets one line per change.
# Exit codes: 0 done (also "not needed"), 1 failed, 2 bad usage or not this handheld,
# 3 not available here (blocked).

ROOT="${GAMECOVE_ROOT:-}"
GC_LIB="$(cd "$(dirname "$0")/../lib" && pwd)"
# shellcheck source=fixes/lib/handheld.sh
. "$GC_LIB/handheld.sh"
# Every handheld row, not just the fan / charge-limit ones (handheld.sh reads $HANDHELDS).
HANDHELDS="$GC_LIB/devices.txt"
FIX_DEVICES="$GC_LIB/fix-devices.txt"
if [ "$DEVICES" = "@" ]; then
	DEVICES="$(awk -F '\t' -v n="$NAME" '$1 == n { print $2; exit }' "$FIX_DEVICES" 2>/dev/null || true)"
fi
GC_MARK="# GameCove fix $NAME"
STATE="$ROOT/var/lib/gamecove/fixes/$NAME"
RELOAD="${RELOAD:-}"
REVISION="${REVISION:-1}"

gc_say() { printf '%s\n' "$*"; }
gc_die() { printf '%s: %s\n' "$NAME" "$2" >&2; exit "$1"; }

gc_log() {
	mkdir -p "$STATE" 2>/dev/null || true
	log_cap "$STATE/changes.log"
	printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" >>"$STATE/changes.log" 2>/dev/null || true
	if [ -n "${GAMECOVE_CHANGES_LOG:-}" ]; then
		printf '%s fix=%s detail=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$NAME" "$1" >>"$GAMECOVE_CHANGES_LOG" 2>/dev/null || true
	fi
}

# This handheld's devices.json id, "" when it isn't a known handheld.
gc_device() { handheld_id 2>/dev/null || true; }

gc_applies() {
	_id="$(gc_device)"
	[ -n "$_id" ] || return 1
	case " $DEVICES " in
	*" * "* | *" $_id "*) return 0 ;;
	esac
	return 1
}

# gc_rule_lines <prefix> <suffix>: one udev line per DMI alternative of every handheld in DEVICES
# (from devices.txt): <prefix>ATTR{[dmi/id]<key>}=="<pat>|<pat>", ...<suffix>. With DEVICES="*" one
# line without a DMI match (the fix's own hardware match is the gate). Prefix ends with ", ".
gc_rule_lines() {
	if [ "$DEVICES" = "*" ]; then
		printf '%s%s\n' "$1" "$2"
		return 0
	fi
	_n=0
	while IFS= read -r _l; do
		case "$_l" in '' | '#'*) continue ;; esac
		_id="${_l%%	*}"
		case " $DEVICES " in *" $_id "*) ;; *) continue ;; esac
		_attrs=""
		_rest="${_l#*	}"
		while [ -n "$_rest" ]; do
			_f="${_rest%%	*}"
			if [ "$_f" = "$_rest" ]; then _rest=""; else _rest="${_rest#*	}"; fi
			_attrs="${_attrs}ATTR{[dmi/id]${_f%%=*}}==\"${_f#*=}\", "
		done
		printf '%s%s%s\n' "$1" "$_attrs" "$2"
		_n=$((_n + 1))
	done <"$HANDHELDS"
	[ "$_n" -gt 0 ] || gc_die 1 "no handheld in fix-devices.txt for $NAME"
}

# gc_products: the DMI product_name patterns of every handheld in DEVICES, one per line.
gc_products() {
	while IFS= read -r _l; do
		case "$_l" in '' | '#'*) continue ;; esac
		case " $DEVICES " in *" ${_l%%	*} "*) ;; *) continue ;; esac
		printf '%s\n' "$_l" | tr '\t' '\n' | sed -n 's/^product_name=//p' | tr '|' '\n'
	done <"$HANDHELDS"
}

# A file of ours: present and its first line is our marker.
gc_ours() { [ -f "$ROOT$1" ] && head -n 1 "$ROOT$1" | grep -qxF "$GC_MARK"; }

gc_installed() { [ -f "$STATE/installed" ]; }

# ---- SteamOS keeps /etc and /var per OS slot: an update brings over only the /etc files an
# /etc/atomic-update.conf.d entry names (docs/SESSION.md). A rule written to /etc/udev/rules.d is gone after
# the update unless it is named there, and /var/lib/gamecove (our record) is gone either way, so:
#   - install and update on SteamOS name their files (and that file itself) in a keep entry;
#   - when the files are there and ours but the record is not, the fix is still installed: status says so and
#     the next install / update / remove writes the record again (revision 0: "update" then brings it current).
gc_os_steamos() { [ "$(sed -n 's/^ID=//p' "$ROOT/etc/os-release" 2>/dev/null | tr -d "\"'" | head -n 1)" = steamos ]; }
GC_KEEP=/etc/atomic-update.conf.d/gamecove-fix-$NAME.conf

gc_keep_write() {
	gc_os_steamos || return 0
	mkdir -p "$ROOT/etc/atomic-update.conf.d" 2>/dev/null || return 0
	{
		printf '## GameCove %s: keeps its files across SteamOS updates. gamecove-fix %s remove deletes this file.\n' "$NAME" "$NAME"
		for _f in $FILES; do printf '%s\n' "$_f"; done
		printf '%s\n' "$GC_KEEP"
	} >"$ROOT$GC_KEEP.gamecove-tmp" && mv -f "$ROOT$GC_KEEP.gamecove-tmp" "$ROOT$GC_KEEP" || rm -f "$ROOT$GC_KEEP.gamecove-tmp"
}

gc_keep_drop() { rm -f "$ROOT$GC_KEEP"; }

# 0 when the record is missing but every file is in place and ours (an OS update took the record).
gc_adoptable() { gc_os_steamos && [ ! -f "$STATE/installed" ] && gc_files_ok; }

gc_adopt() {
	gc_adoptable || return 0
	mkdir -p "$STATE" && printf '0\n' >"$STATE/installed" || return 0
	gc_log "adopted the files an OS update left behind without their record"
}

# The revision that was installed (1 for installs from before revisions were recorded).
gc_installed_revision() {
	_r="$(cat "$STATE/installed" 2>/dev/null || true)"
	case "$_r" in '' | *[!0-9]*) _r=1 ;; esac
	printf '%s' "$_r"
}

# 0 when every file is in place and ours.
gc_files_ok() {
	for _f in $FILES; do
		gc_ours "$_f" || return 1
	done
	return 0
}

# Other files (not ours) under the usual rule folders that contain every given fixed string.
# Used by os_fixed: the OS (Bazzite, SteamOS, ...) already ships the same rule.
gc_rule_elsewhere() {
	for _d in /usr/lib/udev/rules.d /lib/udev/rules.d /etc/udev/rules.d; do
		for _r in "$ROOT$_d"/*.rules; do
			[ -f "$_r" ] || continue
			head -n 1 "$_r" | grep -qF "# GameCove fix " && continue
			_all=0
			for _s in "$@"; do
				grep -qF -- "$_s" "$_r" || { _all=1; break; }
			done
			[ "$_all" -eq 0 ] && return 0
		done
	done
	return 1
}

# Used by os_fixed: gc_all_values "<device dirs, one per line>" <attribute> <value> is 0 when there is at least one
# device and every one already has that value (the system does it some other way than a rule we can read).
gc_all_values() {
	_n=0
	for _d in $1; do
		[ "$(cat "$ROOT$_d/$2" 2>/dev/null)" = "$3" ] || return 1
		_n=$((_n + 1))
	done
	[ "$_n" -gt 0 ]
}

# save_value <real path>: remember a sysfs value once, so remove can put it back.
save_value() {
	[ -f "$ROOT$1" ] || return 0
	mkdir -p "$STATE"
	grep -q "^$1=" "$STATE/saved" 2>/dev/null && return 0
	printf '%s=%s\n' "$1" "$(cat "$ROOT$1" 2>/dev/null)" >>"$STATE/saved"
}

# write_value <real path> <value>: a sysfs write; failures are reported, never fatal. A value we saved
# (save_value) is also noted in "set" as the node reads right after the write, so restore_values can tell
# later whether the node still holds what we set.
write_value() {
	if ! printf '%s\n' "$2" 2>/dev/null >"$ROOT$1"; then
		printf 'warning: could not write %s to %s\n' "$2" "$1" >&2
		return 1
	fi
	if grep -q "^$1=" "$STATE/saved" 2>/dev/null; then
		{ grep -v "^$1=" "$STATE/set" 2>/dev/null || true; printf '%s=%s\n' "$1" "$(cat "$ROOT$1" 2>/dev/null)"; } >"$STATE/set.tmp" &&
			mv -f "$STATE/set.tmp" "$STATE/set" || true
	fi
}

# Puts back every saved value (sysfs nodes that are gone are skipped). Only a node that still holds the
# value we set: when the system (an OS update that fixes it itself) or the user wrote another one since,
# that one stays and our stale original is not written over it. A record from before "set" existed has
# nothing to compare with and is restored as it always was.
restore_values() {
	[ -f "$STATE/saved" ] || return 0
	while IFS= read -r _line; do
		_p="${_line%%=*}"
		_v="${_line#*=}"
		case "$_p" in /sys/*) ;; *) continue ;; esac
		[ -f "$ROOT$_p" ] || continue
		if [ -f "$STATE/set" ] && grep -q "^$_p=" "$STATE/set"; then
			_ours="$(grep "^$_p=" "$STATE/set" | head -n 1)"
			if [ "$(cat "$ROOT$_p" 2>/dev/null)" != "${_ours#*=}" ]; then
				gc_log "kept $_p: it isn't the value we set any more"
				continue
			fi
		fi
		write_value "$_p" "$_v" || true
	done <"$STATE/saved"
}

gc_reload() {
	case "$RELOAD" in
	udev) udevadm control --reload-rules >/dev/null 2>&1 || printf 'warning: udev did not reload its rules; a restart applies them\n' >&2 ;;
	esac
}

gc_need_root() {
	[ -n "$ROOT" ] || [ "$(id -u)" -eq 0 ] || gc_die 1 "needs root (run it through gamecove-fix)"
}

# gc_write_file <real path>: the file's text from file_text, written in one step (temp file + rename).
gc_write_file() {
	mkdir -p "$(dirname "$ROOT$1")" 2>/dev/null || return 1
	if ! { file_text "$1" >"$ROOT$1.gamecove-tmp" && chmod 644 "$ROOT$1.gamecove-tmp" && mv -f "$ROOT$1.gamecove-tmp" "$ROOT$1"; }; then
		rm -f "$ROOT$1.gamecove-tmp"
		return 1
	fi
}

gc_install() {
	gc_need_root
	gc_applies || gc_die 2 "not for this handheld"
	fix_lock "$NAME"
	gc_adopt
	if gc_installed && gc_files_ok; then
		gc_keep_write
		gc_say "already installed"
		return 0
	fi
	if ! gc_installed && os_fixed; then
		gc_say "not needed: this system already does it"
		return 0
	fi
	if ! gc_installed && ! hw_present; then
		gc_say "not needed: this handheld doesn't have the part this fix is for"
		return 0
	fi
	if command -v blocked >/dev/null 2>&1; then
		_why="$(blocked)"
		[ -z "$_why" ] || gc_die 3 "$_why"
	fi
	for _f in $FILES; do
		if [ -e "$ROOT$_f" ] && ! gc_ours "$_f"; then
			gc_die 1 "$_f exists and isn't GameCove's; leaving it"
		fi
	done
	mkdir -p "$STATE"
	printf '%s\n' "$REVISION" >"$STATE/installed"
	for _f in $FILES; do
		if ! gc_write_file "$_f"; then
			gc_remove_files
			rm -f "$STATE/installed"
			gc_die 1 "could not write $_f"
		fi
	done
	gc_keep_write
	gc_reload
	if command -v apply_now >/dev/null 2>&1; then
		apply_now || printf 'warning: it takes effect after a restart\n' >&2
	fi
	gc_log "install device=$(gc_device)"
	gc_say "installed"
}

gc_remove_files() {
	for _f in $FILES; do
		if gc_ours "$_f"; then rm -f "$ROOT$_f"; fi
	done
}

gc_remove() {
	gc_need_root
	gc_adopt
	if ! gc_installed; then
		gc_say "not installed"
		return 0
	fi
	fix_lock "$NAME"
	gc_remove_files
	gc_keep_drop
	gc_reload
	if command -v revert_now >/dev/null 2>&1; then
		revert_now || true
	else
		restore_values
	fi
	rm -f "$STATE/installed" "$STATE/saved" "$STATE/set"
	gc_log "remove"
	rmdir "$STATE" 2>/dev/null || true
	gc_say "removed"
}

# Puts back what gc_update saved: every file as it was (or gone, when it wasn't there), the saved
# sysfs values and the installed record.
gc_rollback() {
	_i=0
	for _f in $FILES; do
		_i=$((_i + 1))
		if [ -f "$1/file$_i" ]; then
			cp -p "$1/file$_i" "$ROOT$_f.gamecove-tmp" && mv -f "$ROOT$_f.gamecove-tmp" "$ROOT$_f"
		elif gc_ours "$_f"; then
			rm -f "$ROOT$_f"
		fi
	done
	cp -p "$1/installed" "$STATE/installed"
	if [ -f "$1/saved" ]; then cp -p "$1/saved" "$STATE/saved"; else rm -f "$STATE/saved"; fi
	if [ -f "$1/set" ]; then cp -p "$1/set" "$STATE/set"; else rm -f "$STATE/set"; fi
	rm -rf "$1"
	gc_reload
}

# update: bring an installed fix to this revision of the script, or leave it exactly as it was.
gc_update() {
	gc_need_root
	gc_adopt
	if ! gc_installed; then
		gc_say "not installed"
		return 0
	fi
	gc_applies || gc_die 2 "not for this handheld"
	fix_lock "$NAME"
	_from="$(gc_installed_revision)"
	_bak="$STATE/rollback"
	rm -rf "$_bak"
	mkdir -p "$_bak" || gc_die 1 "could not save the current files"
	_i=0
	for _f in $FILES; do
		_i=$((_i + 1))
		if gc_ours "$_f"; then
			cp -p "$ROOT$_f" "$_bak/file$_i" || { rm -rf "$_bak"; gc_die 1 "could not save $_f"; }
		fi
	done
	cp -p "$STATE/installed" "$_bak/installed" || { rm -rf "$_bak"; gc_die 1 "could not save the current files"; }
	[ ! -f "$STATE/saved" ] || cp -p "$STATE/saved" "$_bak/saved" || { rm -rf "$_bak"; gc_die 1 "could not save the current files"; }
	[ ! -f "$STATE/set" ] || cp -p "$STATE/set" "$_bak/set" || { rm -rf "$_bak"; gc_die 1 "could not save the current files"; }
	_why=""
	for _f in $FILES; do
		if [ -e "$ROOT$_f" ] && ! gc_ours "$_f"; then
			_why="$_f exists and isn't GameCove's; leaving it"
			break
		fi
		gc_write_file "$_f" || { _why="could not write $_f"; break; }
	done
	if [ -z "$_why" ]; then
		gc_keep_write
		gc_reload
		if command -v apply_now >/dev/null 2>&1; then
			apply_now || printf 'warning: it takes effect after a restart\n' >&2
		fi
		printf '%s\n' "$REVISION" >"$STATE/installed" || _why="could not record the new revision"
	fi
	if [ -z "$_why" ] && ! gc_files_ok; then
		_why="the new files didn't land"
	fi
	if [ -z "$_why" ] && command -v verify >/dev/null 2>&1 && ! verify; then
		_why="the new version didn't work here"
	fi
	if [ -n "$_why" ]; then
		gc_rollback "$_bak"
		gc_log "update failed ($_why); back at revision $_from"
		gc_die 1 "$_why; put back as it was"
	fi
	rm -rf "$_bak"
	gc_log "update revision=$_from->$REVISION"
	gc_say "updated"
}

gc_status() {
	if ! gc_applies; then
		gc_say "applies=no"
		gc_say "state=n/a"
		return 0
	fi
	gc_say "applies=yes"
	inst=no
	gc_installed && inst=yes
	adopt=no
	if gc_adoptable; then inst=yes; adopt=yes; fi
	gc_say "installed=$inst"
	osf=no
	os_fixed && osf=yes
	gc_say "os_fixed=$osf"
	hw=no
	hw_present && hw=yes
	gc_say "hw=$hw"
	gc_say "revision=$REVISION"
	if [ "$adopt" = yes ]; then gc_say "installed_revision=0"
	elif [ "$inst" = yes ]; then gc_say "installed_revision=$(gc_installed_revision)"; fi
	_why=""
	if [ "$inst" = no ] && [ "$osf" = no ] && [ "$hw" = yes ] && command -v blocked >/dev/null 2>&1; then
		_why="$(blocked)"
	fi
	if [ "$inst" = yes ] && gc_files_ok; then
		gc_say "state=on"
	elif [ "$inst" = yes ]; then
		gc_say "state=partial"
	elif [ "$osf" = yes ]; then
		gc_say "state=os-fixed"
	elif [ "$hw" = no ]; then
		gc_say "state=not-needed"
	elif [ -n "$_why" ]; then
		gc_say "reason=$_why"
		gc_say "state=unsupported"
	else
		gc_say "state=off"
	fi
}

gc_main() {
	trap 'fix_unlock' EXIT
	trap 'exit 1' INT TERM HUP
	case "${1:-}" in
	install) gc_install ;;
	remove) gc_remove ;;
	update) gc_update ;;
	status) gc_status ;;
	set)
		case "${2:-}" in
		on) gc_install ;;
		off) gc_remove ;;
		*) gc_die 2 "set needs on or off" ;;
		esac
		;;
	*) gc_die 2 "usage: fix.sh install|remove|update|status|set on|off" ;;
	esac
}
