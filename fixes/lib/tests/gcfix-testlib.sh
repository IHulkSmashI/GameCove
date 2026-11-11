# shellcheck shell=sh
# Helpers for the tests of fixes built on fixes/lib/gcfix.sh. Sourced by fixes/<name>/test.sh.
# Every test runs fix.sh against a fake root (GAMECOVE_ROOT) with a stub udevadm; nothing real is
# touched. Not shipped (packaging drops tests folders).
#
#   t_new                      fresh fake root in $R, stubs on PATH, export GAMECOVE_ROOT
#   t_dmi <vendor> <product> <board> [board_vendor]
#   t_usb <name> <vid> <pid> [attr=value ...]     /sys/bus/usb/devices/<name>
#   t_pci <slot> <vendor> <device> <class> [attr=value ...]
#   t_serio <name> <driver> [wakeup]
#   t_state                    prints the state= line of `status`
#   t_check <cond> <message>   counts a pass or prints FAIL
#   t_end                      prints the summary, exits 1 on any failure

T_PASS=0
T_FAIL=0
T_NAME=${T_NAME:-fix}

t_check() {
	if eval "$1"; then
		T_PASS=$((T_PASS + 1))
	else
		T_FAIL=$((T_FAIL + 1))
		printf 'FAIL %s: %s\n' "$T_NAME" "$2" >&2
	fi
}

t_new() {
	[ -z "${R:-}" ] || rm -rf "$R"
	R=$(mktemp -d)
	mkdir -p "$R/sys/class/dmi/id" "$R/run" "$R/.bin" "$R/sys/bus/usb/devices" "$R/sys/bus/pci/devices" "$R/sys/bus/serio/devices"
	cat >"$R/.bin/udevadm" <<'EOF'
#!/bin/sh
echo "udevadm $*" >>"$GAMECOVE_ROOT/.udevadm.calls"
EOF
	chmod +x "$R/.bin/udevadm"
	export GAMECOVE_ROOT="$R"
	export PATH="$R/.bin:$T_PATH0"
	unset GAMECOVE_CHANGES_LOG
}

t_dmi() {
	printf '%s\n' "$1" >"$R/sys/class/dmi/id/sys_vendor"
	printf '%s\n' "$2" >"$R/sys/class/dmi/id/product_name"
	printf '%s\n' "$3" >"$R/sys/class/dmi/id/board_name"
	printf '%s\n' "${4:-$1}" >"$R/sys/class/dmi/id/board_vendor"
}

# t_attrs <dir> attr=value...: files under <dir>, "a/b=v" makes subfolders.
t_attrs() {
	_d=$1
	shift
	for _kv in "$@"; do
		mkdir -p "$(dirname "$_d/${_kv%%=*}")"
		printf '%s\n' "${_kv#*=}" >"$_d/${_kv%%=*}"
	done
}

t_usb() {
	_d="$R/sys/bus/usb/devices/$1"
	mkdir -p "$_d"
	printf '%s\n' "$2" >"$_d/idVendor"
	printf '%s\n' "$3" >"$_d/idProduct"
	shift 3
	t_attrs "$_d" "$@"
}

t_pci() {
	_d="$R/sys/bus/pci/devices/$1"
	mkdir -p "$_d"
	printf '%s\n' "$2" >"$_d/vendor"
	printf '%s\n' "$3" >"$_d/device"
	printf '%s\n' "$4" >"$_d/class"
	shift 4
	t_attrs "$_d" "$@"
}

t_serio() {
	_d="$R/sys/bus/serio/devices/$1"
	mkdir -p "$_d/power" "$R/sys/bus/serio/drivers/$2"
	ln -s "../../drivers/$2" "$_d/driver"
	printf '%s\n' "${3:-enabled}" >"$_d/power/wakeup"
}

t_state() { sh "$FIX" status | sed -n 's/^state=//p'; }

# t_code <command...>: prints the exit code.
t_code() {
	set +e
	"$@" >/dev/null 2>&1
	_c=$?
	set -e
	echo "$_c"
}

t_end() {
	[ -z "${R:-}" ] || rm -rf "$R"
	if [ "$T_FAIL" -eq 0 ]; then
		printf '%s: all %d passed\n' "$T_NAME" "$T_PASS"
		return 0
	fi
	printf '%s: %d passed, %d failed\n' "$T_NAME" "$T_PASS" "$T_FAIL" >&2
	exit 1
}

# t_common <rule path> <make-device-fn> <make-other-fn> <live check> <restored check>
# The checks every file fix shares: off -> install -> on (idempotent) -> remove -> off, set on/off,
# a foreign file is left alone, another handheld is refused, a Bazzite-style rule elsewhere is
# os-fixed, and the change log. <make-device-fn> builds a fake root where the fix is needed.
t_common() {
	_rule=$1
	_mk=$2
	_other=$3
	_live=$4
	_back=$5
	t_new
	$_mk
	t_check '[ "$(t_state)" = off ]' "state=off before install"
	t_check 'sh "$FIX" status | grep -qx "applies=yes"' "applies=yes on this handheld"
	t_check 'sh "$FIX" install >/dev/null' "install"
	t_check '[ -f "$R$_rule" ]' "rule written"
	T_RULE_COPY=$(mktemp)
	cp "$R$_rule" "$T_RULE_COPY" 2>/dev/null || true
	t_check 'head -n 1 "$R$_rule" | grep -qx "# GameCove fix $T_NAME"' "rule carries the marker"
	t_check '[ "$(stat -c %a "$R$_rule")" = 644 ]' "rule is 0644"
	t_check "$_live" "takes effect at once"
	t_check '[ "$(t_state)" = on ]' "state=on after install"
	t_check 'grep -q "control --reload-rules" "$R/.udevadm.calls"' "udev reloads its rules"
	t_check '[ "$(sh "$FIX" install)" = "already installed" ]' "install twice is a no-op"
	t_check 'grep -q "^.* install device=" "$R/var/lib/gamecove/fixes/$T_NAME/changes.log"' "install logged"
	t_check '[ ! -e "$R/run/gamecove-$T_NAME.lock" ]' "lock released"
	# update (docs/FIXES.md): an installed fix is rewritten from this revision of the script, nothing else changes
	t_check 'sh "$FIX" status | grep -qx "revision=[0-9][0-9]*"' "status names the script's revision"
	t_check 'sh "$FIX" status | grep -qx "installed_revision=[0-9][0-9]*"' "status names the installed revision"
	t_check 'sh "$FIX" status | grep -q "^os_fixed="' "status answers the probe (os_fixed)"
	echo 1 >"$R/var/lib/gamecove/fixes/$T_NAME/installed"
	sed -i '2i # an older revision wrote this line' "$R$_rule"
	t_check '[ "$(sh "$FIX" update)" = updated ]' "update"
	t_check 'cmp -s "$R$_rule" "$T_RULE_COPY"' "update: the rule is this revision's again"
	t_check '[ "$(t_state)" = on ]' "update: still on"
	t_check '[ ! -e "$R/var/lib/gamecove/fixes/$T_NAME/rollback" ]' "update: no rollback copy left"
	t_check 'grep -q " update revision=1->" "$R/var/lib/gamecove/fixes/$T_NAME/changes.log"' "update logged"
	t_check 'sh "$FIX" remove >/dev/null 2>&1' "remove"
	t_check '[ ! -e "$R$_rule" ]' "rule gone after remove"
	t_check '[ "$(sh "$FIX" update)" = "not installed" ]' "update never installs: not installed, nothing written"
	t_check '[ ! -e "$R$_rule" ]' "update: nothing written when not installed"
	t_check "$_back" "original values back after remove"
	t_check '[ "$(t_state)" = off ]' "state=off after remove"
	t_check '[ "$(sh "$FIX" remove)" = "not installed" ]' "remove twice is a no-op"
	t_check '[ ! -e "$R/var/lib/gamecove/fixes/$T_NAME/installed" ]' "nothing left recorded"
	t_check 'sh "$FIX" set on >/dev/null && [ "$(t_state)" = on ]' "set on = install"
	t_check 'sh "$FIX" set off >/dev/null 2>&1 && [ "$(t_state)" = off ]' "set off = remove"
	t_check '[ "$(t_code sh "$FIX" set maybe)" = 2 ]' "set refuses other values"
	t_check '[ "$(t_code sh "$FIX" bogus)" = 2 ]' "unknown command: exit 2"
	# a file someone else wrote is never replaced
	mkdir -p "$(dirname "$R$_rule")"
	echo "# someone else's rule" >"$R$_rule"
	t_check '[ "$(t_code sh "$FIX" install)" = 1 ]' "foreign file: install refuses"
	t_check 'grep -qx "# someone else.s rule" "$R$_rule"' "foreign file untouched"
	rm -f "$R$_rule"
	# the change log of gamecove-fix
	export GAMECOVE_CHANGES_LOG="$R/changes.log"
	sh "$FIX" install >/dev/null
	t_check 'grep -q "fix=$T_NAME detail=install" "$R/changes.log"' "detail line in gamecove-fix's log"
	sh "$FIX" remove >/dev/null 2>&1
	unset GAMECOVE_CHANGES_LOG
	# the same rule shipped by the OS (Bazzite): os-fixed, install changes nothing
	t_new
	$_mk
	mkdir -p "$R/usr/lib/udev/rules.d"
	sed 1d "$T_RULE_COPY" >"$R/usr/lib/udev/rules.d/50-os-shipped.rules"
	rm -f "$T_RULE_COPY"
	t_check '[ "$(t_state)" = os-fixed ]' "OS rule: state=os-fixed"
	t_check 'sh "$FIX" install | grep -q "not needed"' "OS rule: install says not needed"
	t_check '[ ! -e "$R$_rule" ]' "OS rule: nothing written"
	# another handheld (or a laptop) is never touched
	t_new
	$_other
	t_check '[ "$(sh "$FIX" status | tr "\n" " ")" = "applies=no state=n/a " ]' "other device: applies=no"
	t_check '[ "$(t_code sh "$FIX" install)" = 2 ]' "other device: install refused (exit 2)"
	t_check '[ ! -e "$R$_rule" ]' "other device: nothing written"
	t_new
	rm -rf "$R/sys/class/dmi"
	t_check '[ "$(t_code sh "$FIX" install)" = 2 ]' "no DMI ids: refused"
}
