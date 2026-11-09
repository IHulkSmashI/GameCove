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
# and defines:
#   file_text <path>   prints the content for one of FILES (the first line must hold GC_MARK)
#   hw_present         0 when the part the fix is for is in this handheld (else: not needed)
#   os_fixed           0 when the system already does this by itself (another rule, a newer kernel)
#   apply_now          optional: make it take effect now (save originals with save_value first)
#                      (file_text builds udev lines with gc_rule_lines, which adds the DMI match)
#   revert_now         optional: undo apply_now (restore_values does the usual thing)
#   blocked            optional: prints why it can't be applied on this machine now ("" = it can);
#                      install refuses (exit 3) and status says state=unsupported, reason=<text>
#
# Commands: install | remove | status | set on | set off (on = install, off = remove; all through
# gamecove-fix with the administrator password since review S3-2: a udev rule that acts on every
# boot isn't a day-to-day setting). status prints applies=, installed=, os_fixed=,
# hw=, then state= (on | off | os-fixed | not-needed | partial | n/a).
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

# save_value <real path>: remember a sysfs value once, so remove can put it back.
save_value() {
	[ -f "$ROOT$1" ] || return 0
	mkdir -p "$STATE"
	grep -q "^$1=" "$STATE/saved" 2>/dev/null && return 0
	printf '%s=%s\n' "$1" "$(cat "$ROOT$1" 2>/dev/null)" >>"$STATE/saved"
}

# write_value <real path> <value>: a sysfs write; failures are reported, never fatal.
write_value() {
	if ! printf '%s\n' "$2" 2>/dev/null >"$ROOT$1"; then
		printf 'warning: could not write %s to %s\n' "$2" "$1" >&2
		return 1
	fi
}

# Puts back every saved value (sysfs nodes that are gone are skipped).
restore_values() {
	[ -f "$STATE/saved" ] || return 0
	while IFS= read -r _line; do
		_p="${_line%%=*}"
		_v="${_line#*=}"
		case "$_p" in /sys/*) ;; *) continue ;; esac
		[ -f "$ROOT$_p" ] || continue
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

gc_install() {
	gc_need_root
	gc_applies || gc_die 2 "not for this handheld"
	fix_lock "$NAME"
	if gc_installed && gc_files_ok; then
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
	: >"$STATE/installed"
	for _f in $FILES; do
		mkdir -p "$(dirname "$ROOT$_f")"
		if ! { file_text "$_f" >"$ROOT$_f.gamecove-tmp" && chmod 644 "$ROOT$_f.gamecove-tmp" && mv -f "$ROOT$_f.gamecove-tmp" "$ROOT$_f"; }; then
			rm -f "$ROOT$_f.gamecove-tmp"
			gc_remove_files
			rm -f "$STATE/installed"
			gc_die 1 "could not write $_f"
		fi
	done
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
	if ! gc_installed; then
		gc_say "not installed"
		return 0
	fi
	fix_lock "$NAME"
	gc_remove_files
	gc_reload
	if command -v revert_now >/dev/null 2>&1; then
		revert_now || true
	else
		restore_values
	fi
	rm -f "$STATE/installed" "$STATE/saved"
	gc_log "remove"
	rmdir "$STATE" 2>/dev/null || true
	gc_say "removed"
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
	gc_say "installed=$inst"
	osf=no
	os_fixed && osf=yes
	gc_say "os_fixed=$osf"
	hw=no
	hw_present && hw=yes
	gc_say "hw=$hw"
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
	status) gc_status ;;
	set)
		case "${2:-}" in
		on) gc_install ;;
		off) gc_remove ;;
		*) gc_die 2 "set needs on or off" ;;
		esac
		;;
	*) gc_die 2 "usage: fix.sh install|remove|status|set on|off" ;;
	esac
}
