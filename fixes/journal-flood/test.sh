#!/bin/sh
# shellcheck disable=SC2016 # t_check evals its single-quoted check later, on purpose
# journal-flood against fake roots (never the real system).
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
FIX="$HERE/fix.sh"
T_NAME=journal-flood
T_PATH0=$PATH
# shellcheck source=fixes/lib/tests/gcfix-testlib.sh
. "$HERE/../lib/tests/gcfix-testlib.sh"
DROPIN=/etc/systemd/system/steamos-manager.service.d/50-gamecove-quiet-split-lock.conf
bazzite() {
	t_dmi "Micro-Star International Co., Ltd." "Claw 8 EX AI+ CG3EM" "MS-1T91"
	mkdir -p "$R/usr/lib/systemd/system"
	: >"$R/usr/lib/systemd/system/steamos-manager.service"
	cat >"$R/.bin/systemctl" <<'S'
#!/bin/sh
echo "systemctl $*" >>"$GAMECOVE_ROOT/.systemctl.calls"
S
	chmod +x "$R/.bin/systemctl"
}

# ClawDeck's own drop-in (finding 10) already silences it: the system's, so nothing of ours is written
t_new
bazzite
mkdir -p "$R/etc/systemd/system/steamos-manager.service.d"
printf '[Service]\nEnvironment=RUST_LOG=info,steamos_manager::sls=off\n' >"$R/etc/systemd/system/steamos-manager.service.d/50-clawdeck-quiet-split-lock.conf"
t_check '[ "$(t_state)" = os-fixed ]' "ClawDeck's drop-in is recognised: already done"
t_check 'sh "$FIX" install >/dev/null 2>&1' "install doesn't fail for it"
t_check '[ ! -e "$R$DROPIN" ]' "and writes nothing"

t_new
bazzite
t_check '[ "$(t_state)" = off ]' "Bazzite (steamos-manager, no reporter): offered"
t_check 'sh "$FIX" install >/dev/null' "install"
t_check 'head -n 1 "$R$DROPIN" | grep -qx "# GameCove fix journal-flood"' "drop-in carries the marker"
t_check 'grep -qx "Environment=RUST_LOG=info,steamos_manager::sls=off" "$R$DROPIN"' "only the sls module is silenced"
t_check 'grep -qx "\[Service\]" "$R$DROPIN"' "a [Service] drop-in"
t_check '[ "$(stat -c %a "$R$DROPIN")" = 644 ]' "0644"
t_check 'grep -qx "systemctl daemon-reload" "$R/.systemctl.calls" && grep -qx "systemctl try-restart steamos-manager.service" "$R/.systemctl.calls"' "systemd reloaded, steamos-manager restarted only if it runs"
t_check '[ "$(t_state)" = on ]' "state on"
t_check 'sh "$FIX" status | grep -qx os_fixed=no' "our own drop-in is never the OS's"
t_check '[ "$(sh "$FIX" install)" = "already installed" ]' "install twice is a no-op"
: >"$R/.systemctl.calls"
t_check 'sh "$FIX" remove >/dev/null 2>&1' "remove"
t_check '[ ! -e "$R$DROPIN" ]' "drop-in gone"
t_check 'grep -qx "systemctl daemon-reload" "$R/.systemctl.calls"' "systemd reloaded after remove"
t_check '[ "$(t_state)" = off ]' "state off"
# someone else's file with the same name is never replaced
mkdir -p "$(dirname "$R$DROPIN")"
echo "# mine" >"$R$DROPIN"
t_check '[ "$(t_code sh "$FIX" install)" = 1 ]' "foreign file: refused"
t_check 'grep -qx "# mine" "$R$DROPIN"' "foreign file untouched"

# SteamOS: Valve's reporter takes the hits, nothing floods
t_new
bazzite
: >"$R/usr/lib/systemd/system/steamos-log-submitter.service"
t_check '[ "$(t_state)" = not-needed ]' "steamos-log-submitter present: not needed"
t_check 'sh "$FIX" install | grep -q "not needed"' "install stands down"
t_check '[ ! -e "$R$DROPIN" ]' "nothing written"

# no steamos-manager at all
t_new
bazzite
rm -f "$R/usr/lib/systemd/system/steamos-manager.service"
t_check '[ "$(t_state)" = not-needed ]' "no steamos-manager: not needed"

# the OS (or the user) already silences the module with its own drop-in
t_new
bazzite
mkdir -p "$R/usr/lib/systemd/system/steamos-manager.service.d"
printf '[Service]\nEnvironment=RUST_LOG=warn,steamos_manager::sls=off\n' >"$R/usr/lib/systemd/system/steamos-manager.service.d/10-quiet.conf"
t_check '[ "$(t_state)" = os-fixed ]' "another drop-in silences it: os-fixed"

# any handheld may get it (the fix checks for the daemon), a laptop never
t_new
bazzite
t_dmi "ASUSTeK COMPUTER INC." "ROG Ally RC71L_RC71L" "RC71L"
t_check 'sh "$FIX" status | grep -qx applies=yes' "any handheld: applies"
t_new
bazzite
t_dmi "Dell Inc." "XPS 13 9310" "0XYZ"
t_check 'sh "$FIX" status | grep -qx applies=no' "not a handheld: applies=no"
t_end
