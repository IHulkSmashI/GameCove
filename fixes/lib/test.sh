#!/bin/sh
# Tests for the shared fix libraries (lockdir.sh, ratelimit.sh) in a temp folder; never the real system.
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
fail() { printf 'FAIL lib: %s\n' "$1" >&2; exit 1; }
# shellcheck source=fixes/lib/lockdir.sh
. "$HERE/lockdir.sh"

# a PID that is certainly gone, and one that runs
sh -c 'exit 0' & dead=$!; wait "$dead" || true
sleep 60 & live=$!
trap 'kill "$live" 2>/dev/null || true; rm -rf "$T"' EXIT

# ---- lockdir: a dead holder's lock is taken over, a live holder's is not
L="$T/a.lock"
mkdir "$L"; echo "$dead" >"$L/pid"
lockdir_take "$L" 3 2>/dev/null || fail "a dead holder's lock is taken over"
[ "$(cat "$L/pid")" = "$$" ] || fail "taken over with our PID"
lockdir_drop "$L"
[ ! -e "$L" ] || fail "dropped"
mkdir "$L"; echo "$live" >"$L/pid"
if lockdir_take "$L" 2 2>/dev/null; then fail "a live holder's lock is respected"; fi
[ "$(cat "$L/pid")" = "$live" ] || fail "the live holder keeps its lock"
rm -r "$L"

# ---- review problem 5: waiter A judges the holder dead; waiter B breaks the lock and takes it before A
# acts; A's break must leave B's lock alone (it used to re-read B's PID and remove B's lock)
L="$T/b.lock"
mkdir "$L"; echo "$dead" >"$L/pid"
lockdir_stale "$L" || fail "the dead holder's lock is stale"
judged_a="$_lp"
lockdir_break "$L" "$dead" || fail "B breaks"
mkdir "$L" || fail "B takes the lock"
echo "$live" >"$L/pid"
lockdir_break "$L" "$judged_a" || true
[ -d "$L" ] && [ "$(cat "$L/pid" 2>/dev/null)" = "$live" ] || fail "A's late break removed B's lock"
[ ! -e "$L.break" ] || fail "the breaker's own lock is released"
rm -r "$L"
# a holder between mkdir and writing its PID is not broken by a waiter that judged an old PID
mkdir "$L"
lockdir_break "$L" "$dead" || true
[ -d "$L" ] || fail "a fresh lock without a PID yet is left alone"
rm -r "$L"

# ---- ratelimit: at most <max> changes per window; stamps from the future (a clock stepped back) don't count
# shellcheck source=fixes/lib/ratelimit.sh
. "$HERE/ratelimit.sh"
ROOT="$T/rate"
rate_take t 2 600 || fail "first change"
rate_take t 2 600 || fail "second change"
if rate_take t 2 600; then fail "the third change in the window is refused"; fi
future=$(($(date +%s) + 7200))
mkdir -p "$ROOT/run/gamecove"
printf '%s\n%s\n' "$future" "$future" >"$ROOT/run/gamecove/rate-f"
rate_take f 2 600 || fail "stamps later than now (clock stepped back) don't lock changes out"

# ---- gcfix.sh update: a new revision replaces the installed one, or everything is put back (docs/FIXES.md)
# A throwaway fix built on gcfix.sh, in a fake root. V picks what the "new script" writes and whether it works.
FX="$T/fixes"
mkdir -p "$FX/demo" "$T/root/sys/class/dmi/id" "$T/root/run" "$T/bin"
ln -s "$HERE" "$FX/lib"
printf '#!/bin/sh\nexit 0\n' >"$T/bin/udevadm"
chmod +x "$T/bin/udevadm"
cat >"$FX/demo/fix.sh" <<'EOF'
#!/bin/sh
set -eu
NAME=demo
DEVICES="*"
FILES="/etc/udev/rules.d/60-gamecove-demo.rules /etc/gamecove-demo.conf"
RELOAD=udev
REVISION="${V_REV:-1}"
. "$(cd "$(dirname "$0")/../lib" && pwd)/gcfix.sh"
file_text() {
	[ "${V_BREAK:-}" != "$1" ] || return 1
	printf '%s\n# revision %s of %s\n' "$GC_MARK" "$REVISION" "$1"
}
hw_present() { return 0; }
os_fixed() { return 1; }
apply_now() { save_value /sys/demo/value; write_value /sys/demo/value "new$REVISION"; }
verify() { [ "${V_VERIFY:-ok}" = ok ]; }
gc_main "$@"
EOF
demo() { GAMECOVE_ROOT="$T/root" PATH="$T/bin:$PATH" sh "$FX/demo/fix.sh" "$@"; }
echo "Valve" >"$T/root/sys/class/dmi/id/sys_vendor"
echo "Jupiter" >"$T/root/sys/class/dmi/id/product_name"
mkdir -p "$T/root/sys/demo"
echo factory >"$T/root/sys/demo/value"
RULE="$T/root/etc/udev/rules.d/60-gamecove-demo.rules"
CONF="$T/root/etc/gamecove-demo.conf"
ST="$T/root/var/lib/gamecove/fixes/demo"
[ "$(demo update)" = "not installed" ] || fail "update of a fix that isn't installed does nothing"
[ ! -e "$RULE" ] || fail "update never installs"
demo install >/dev/null || fail "install revision 1"
grep -q "revision 1 of" "$RULE" || fail "revision 1 written"
[ "$(cat "$ST/installed")" = 1 ] || fail "the installed revision is recorded"
demo status | grep -qx "installed_revision=1" || fail "status: installed_revision"
V_REV=2 demo status | grep -qx "revision=2" || fail "status: the script's revision"
cp "$RULE" "$T/rule.v1"; cp "$CONF" "$T/conf.v1"; cp "$ST/saved" "$T/saved.v1"
# the new revision doesn't work here (verify says no): every file, the saved values and the record are back
if V_REV=2 V_VERIFY=no demo update >"$T/out" 2>&1; then fail "a failed update exits non-zero"; fi
grep -q "put back as it was" "$T/out" || fail "says it was put back: $(cat "$T/out")"
cmp -s "$RULE" "$T/rule.v1" || fail "rollback: the rule is byte for byte the old one"
cmp -s "$CONF" "$T/conf.v1" || fail "rollback: the second file too"
cmp -s "$ST/saved" "$T/saved.v1" || fail "rollback: the saved original values"
[ "$(cat "$ST/installed")" = 1 ] || fail "rollback: still recorded at revision 1"
[ ! -e "$ST/rollback" ] || fail "rollback: no copy left behind"
[ -z "$(find "$T/root/etc" -name '*.gamecove-tmp')" ] || fail "rollback: no temp file left"
grep -q "update failed" "$ST/changes.log" || fail "the failed update is logged"
demo status | grep -qx "state=on" || fail "rollback: the old version is still on"
# the second file can't be written: the first, already replaced, goes back too (never half of each)
if V_REV=2 V_BREAK=/etc/gamecove-demo.conf demo update >"$T/out" 2>&1; then fail "a half-written update exits non-zero"; fi
cmp -s "$RULE" "$T/rule.v1" || fail "half-written: the first file is the old one again"
cmp -s "$CONF" "$T/conf.v1" || fail "half-written: the second file untouched"
[ "$(cat "$ST/installed")" = 1 ] || fail "half-written: still revision 1"
# someone replaced one of our files with their own: it is left alone and nothing else changes
cp "$CONF" "$T/conf.ours"
echo "# mine now" >"$CONF"
if V_REV=2 demo update >"$T/out" 2>&1; then fail "a foreign file stops the update"; fi
grep -qx "# mine now" "$CONF" || fail "a file that isn't GameCove's is never overwritten"
cmp -s "$RULE" "$T/rule.v1" || fail "foreign file: the rule is the old one"
cp "$T/conf.ours" "$CONF"
# and the update that works
[ "$(V_REV=2 demo update)" = updated ] || fail "update to revision 2"
grep -q "revision 2 of" "$RULE" && grep -q "revision 2 of" "$CONF" || fail "both files are revision 2"
[ "$(cat "$ST/installed")" = 2 ] || fail "recorded at revision 2"
[ "$(cat "$T/root/sys/demo/value")" = new2 ] || fail "applied at once"
grep -q "update revision=1->2" "$ST/changes.log" || fail "the update is logged"
V_REV=2 demo status | grep -qx "installed_revision=2" || fail "status after the update"
# remove still puts the very first value back (the saved original survived both updates)
V_REV=2 demo remove >/dev/null || fail "remove after an update"
[ "$(cat "$T/root/sys/demo/value")" = factory ] || fail "remove: the original value from before revision 1"
[ ! -e "$RULE" ] && [ ! -e "$CONF" ] || fail "remove: files gone"
[ ! -e "$ST/set" ] || fail "remove: the record of what we set is gone too"
# review Medium (Fixes): removing a fix the system now covers itself must not write our stale original over
# the system's own value (the node no longer holds what we set)
demo install >/dev/null || fail "install again"
[ "$(cat "$T/root/sys/demo/value")" = new1 ] || fail "applied again"
echo "by-the-os" >"$T/root/sys/demo/value"
demo remove >/dev/null || fail "remove after the system changed the value"
[ "$(cat "$T/root/sys/demo/value")" = by-the-os ] || fail "remove: the system's own value is left alone, not overwritten by our saved one"
grep -q "kept /sys/demo/value" "$ST/changes.log" 2>/dev/null || [ ! -d "$ST" ] || fail "the kept value is logged"

# review 4-L6: saved values belong to the handheld that read them; a rule that only a comment mentions is not
# "the system already does it"
demo install >/dev/null || fail "install for the device test"
echo "some-other-handheld" >"$ST/device"
echo "changed" >"$T/root/sys/demo/value"
demo remove >/dev/null || fail "remove with another handheld's record"
[ "$(cat "$T/root/sys/demo/value")" = changed ] || fail "another handheld's saved value is not written here"
echo factory >"$T/root/sys/demo/value"
mkdir -p "$T/root/etc/udev/rules.d"
printf '# ATTR{x}=="y"\nACTION=="add"\n' >"$T/root/etc/udev/rules.d/90-other.rules"
# shellcheck disable=SC2034 # gcfix.sh reads these when it is sourced
elsewhere() { (NAME=probe DEVICES="*" FILES=/etc/x; GAMECOVE_ROOT="$T/root"; . "$HERE/gcfix.sh"; gc_rule_elsewhere "$@"); }
if elsewhere 'ATTR{x}=="y"'; then fail "a comment that mentions the rule is not the rule"; fi
printf 'ACTION=="add", ATTR{x}=="y"\n' >"$T/root/etc/udev/rules.d/90-other.rules"
elsewhere 'ATTR{x}=="y"' || fail "a real line with it is found"
rm -f "$T/root/etc/udev/rules.d/90-other.rules"

# ---- SteamOS: /etc and /var are per OS slot and only keep-listed /etc files survive an update (docs/SESSION.md)
KEEP="$T/root/etc/atomic-update.conf.d/gamecove-fix-demo.conf"
demo install >/dev/null || fail "install (not SteamOS)"
[ ! -e "$KEEP" ] || fail "no keep entry off SteamOS"
demo remove >/dev/null || fail "remove"
mkdir -p "$T/root/etc"
echo 'ID=steamos' >"$T/root/etc/os-release"
demo install >/dev/null || fail "install on SteamOS"
grep -qxF "/etc/udev/rules.d/60-gamecove-demo.rules" "$KEEP" || fail "the rule is keep-listed"
grep -qxF "/etc/gamecove-demo.conf" "$KEEP" || fail "so is the second file"
grep -qxF "/etc/atomic-update.conf.d/gamecove-fix-demo.conf" "$KEEP" || fail "and the keep file itself"
# the update: the keep-listed files come over, /var does not
rm -rf "$T/root/var/lib/gamecove"
st="$(demo status)"
echo "$st" | grep -qx "installed=yes" || fail "files without a record: still installed ($st)"
echo "$st" | grep -qx "state=on" || fail "and on"
echo "$st" | grep -qx "installed_revision=0" || fail "at revision 0, so an update is offered"
[ ! -e "$ST/installed" ] || fail "status writes nothing"
[ "$(V_REV=2 demo update)" = updated ] || fail "update re-adopts and brings it current"
[ "$(cat "$ST/installed")" = 2 ] || fail "the record is back, at revision 2"
rm -rf "$T/root/var/lib/gamecove"
demo remove >/dev/null || fail "remove after the update took the record"
[ ! -e "$RULE" ] && [ ! -e "$CONF" ] && [ ! -e "$KEEP" ] || fail "remove: files and keep entry gone"
demo status | grep -qx "state=off" || fail "off again"

# ---- grub_write (claw8ex-common.sh): a failed write leaves /etc/default/grub exactly as it was
(
	GAMECOVE_ROOT="$T/gw"
	mkdir -p "$GAMECOVE_ROOT/etc/default"
	# shellcheck source=fixes/lib/claw8ex-common.sh
	. "$HERE/claw8ex-common.sh"
	FIX=demo
	G="$GAMECOVE_ROOT/etc/default/grub"
	printf 'GRUB_TIMEOUT=5\nGRUB_CMDLINE_LINUX_DEFAULT="quiet"\n' >"$G"
	chmod 640 "$G"
	want=$(command cat "$G")
	printf 'GRUB_TIMEOUT=5\nGRUB_CMDLINE_LINUX_DEFAULT="quiet x=1"  # GameCove demo\n' >"$T/gw.new"
	# a full disk: cat writes part of it and fails
	cat() { head -c 12 "$@"; return 1; }
	if grub_write /etc/default/grub "$T/gw.new" 2>/dev/null; then fail "a full disk: grub_write must fail"; fi
	[ "$(command cat "$G")" = "$want" ] || fail "a full disk: /etc/default/grub is untouched"
	[ ! -L "$G" ] && [ -s "$G" ] || fail "a full disk: the file is still the real, non-empty file"
	[ ! -e "$G.gamecove-tmp" ] || fail "a full disk: no half-written copy is left"
	# a write that fails without saying so (cut short, exit 0): the compare catches it
	cat() { head -c 12 "$@"; }
	if grub_write /etc/default/grub "$T/gw.new" 2>/dev/null; then fail "a short write: grub_write must fail"; fi
	[ "$(command cat "$G")" = "$want" ] || fail "a short write: the file is untouched"
	unset -f cat
	# the content to write is not there
	if grub_write /etc/default/grub "$T/gw.missing" 2>/dev/null; then fail "no content file: grub_write must fail"; fi
	[ "$(command cat "$G")" = "$want" ] || fail "no content file: the file is untouched, never emptied"
	# the normal write: new content, mode kept, no leftovers
	grub_write /etc/default/grub "$T/gw.new" || fail "a normal write works"
	cmp -s "$T/gw.new" "$G" || fail "a normal write: the new content"
	[ "$(stat -c %a "$G")" = 640 ] || fail "a normal write keeps the mode"
	[ ! -e "$G.gamecove-tmp" ] || fail "a normal write leaves no copy"
	# the whole add: when the write fails, update-grub is never run and the file is as it was
	printf 'GRUB_TIMEOUT=5\n' >"$G"
	want=$(command cat "$G")
	runs="$T/gw.runs"
	: >"$runs"
	grub_regen() { echo regen >>"$runs"; }
	cat() { if [ "$1" = "$T/gw.line" ]; then command cat "$@"; else head -c 3 "$@"; return 1; fi; }
	if grub_line_add "gamecove.test=1" 2>/dev/null; then fail "grub_line_add on a full disk must fail"; fi
	unset -f cat
	[ "$(command cat "$G")" = "$want" ] || fail "grub_line_add on a full disk: file untouched"
	[ ! -s "$runs" ] || fail "update-grub is not run when the file could not be written"
) || exit 1

echo "lib tests passed"
