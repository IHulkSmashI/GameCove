#!/bin/sh
# onexfly-touch against fake roots (never the real system).
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
FIX="$HERE/fix.sh"
T_NAME=onexfly-touch
T_PATH0=$PATH
# shellcheck source=fixes/lib/tests/gcfix-testlib.sh
. "$HERE/../lib/tests/gcfix-testlib.sh"
S=/etc/gamescope-session-plus/sessions.d
Q=/usr/share/gamescope-session-plus/device-quirks

# device-quirks as ChimeraOS/gamescope-session ships it (2026-01), or with PR 128 applied
quirks() {
	mkdir -p "$R/usr/share/gamescope-session-plus"
	cat >"$R$Q" <<QQ
SYS_ID="\$(cat /sys/devices/virtual/dmi/id/product_name)"
OXP_120_LIST="ONEXPLAYER F1:ONEXPLAYER F1 EVA-01"
if [[ ":\$OXP_120_LIST:" =~ ":\$SYS_ID:"  ]]; then
  PANEL_TYPE=$1
  ORIENTATION=left
  export STEAM_DISPLAY_REFRESH_LIMITS=40,120
fi
OXP_X1_LIST="ONEXPLAYER X1 i"
if [[ ":\$OXP_X1_LIST:" =~ ":\$SYS_ID:"  ]]; then
  PANEL_TYPE=external
fi
QQ
}
f1() { t_dmi "ONE-NETBOOK" "ONEXPLAYER F1" "ONEXPLAYER F1"; quirks external; }

t_new
f1
t_check '[ "$(t_state)" = off ]' "state=off before install"
t_check 'sh "$FIX" install >/dev/null' "install"
for c in gamecove steam ogui-steam; do
	t_check '[ -f "$R$S/$c" ] && head -n 1 "$R$S/$c" | grep -qx "# GameCove fix onexfly-touch"' "$c session file written"
done
t_check '[ "$(t_state)" = on ]' "state=on"
t_check '[ "$(sh "$FIX" install)" = "already installed" ]' "install twice is a no-op"
# the file only acts on the F1 (it reads the DMI product name itself), and sets PANEL_TYPE=internal there
t_check 'grep -q "\"ONEXPLAYER F1\" | \"ONEXPLAYER F1 EVA-01\" | " "$R$S/gamecove"' "session file gates on the product names"
t_check 'grep -q "\"AOKZOE A1 AR07\"" "$R$S/gamecove"' "session file also names the siblings in such quirk blocks"
t_check '! grep -q "ONEXPLAYER X1 i" "$R$S/gamecove"' "session file never names the X1 i (its block is internal)"
cp "$R$S/gamecove" "$R/probe"
sed -i "s|/sys/class/dmi/id/product_name|$R/sys/class/dmi/id/product_name|" "$R/probe"
t_check '[ "$(PANEL_TYPE=external sh -c ". \"$R/probe\"; echo \$PANEL_TYPE")" = internal ]' "F1: PANEL_TYPE becomes internal"
echo "ROG Ally RC71L" >"$R/sys/class/dmi/id/product_name"
t_check '[ "$(PANEL_TYPE=external sh -c ". \"$R/probe\"; echo \$PANEL_TYPE")" = external ]' "other handheld on the same drive: untouched"
echo "ONEXPLAYER F1" >"$R/sys/class/dmi/id/product_name"
t_check 'sh "$FIX" remove >/dev/null' "remove"
t_check '[ ! -e "$R$S/gamecove" ] && [ ! -e "$R$S/steam" ] && [ ! -e "$R$S/ogui-steam" ]' "files gone"
t_check '[ "$(t_state)" = off ]' "state=off after remove"
# someone else's Steam session file is left alone (and not written over)
t_new
f1
mkdir -p "$R$S"
echo "# theirs" >"$R$S/steam"
sh "$FIX" install >/dev/null
t_check 'grep -qx "# theirs" "$R$S/steam"' "foreign steam file untouched"
t_check '[ -f "$R$S/gamecove" ]' "own session still fixed"
sh "$FIX" remove >/dev/null
t_check 'grep -qx "# theirs" "$R$S/steam"' "remove leaves the foreign file"
# fixed upstream (PR 128): os-fixed, nothing written
t_new
t_dmi "ONE-NETBOOK" "ONEXPLAYER F1" "ONEXPLAYER F1"
quirks internal
t_check '[ "$(t_state)" = os-fixed ]' "device-quirks says internal: os-fixed"
t_check 'sh "$FIX" install | grep -q "not needed"' "os-fixed: install is a no-op"
# no gamescope-session-plus: not needed
t_new
t_dmi "ONE-NETBOOK" "ONEXPLAYER F1" "ONEXPLAYER F1"
t_check '[ "$(t_state)" = not-needed ]' "no device-quirks: not-needed"
# the OLED model isn't in the quirk list
t_new
t_dmi "ONE-NETBOOK" "ONEXPLAYER F1 OLED" "ONEXPLAYER F1"
quirks external
t_check '[ "$(t_state)" = not-needed ]' "F1 OLED: not-needed"
# other handhelds: refused
t_new
t_dmi "ONE-NETBOOK" "ONEXPLAYER X1 i" "X1"
quirks external
t_check '[ "$(sh "$FIX" status | tr "\n" " ")" = "applies=no state=n/a " ]' "X1: applies=no"
t_check '[ "$(t_code sh "$FIX" install)" = 2 ]' "X1: install refused"
# a sibling in the same kind of block (OneXPlayer 2: OXP_LIST, PANEL_TYPE=external): offered, works
t_new
t_dmi "ONE-NETBOOK" "ONEXPLAYER 2 ARP23" "ONEXPLAYER 2"
mkdir -p "$R/usr/share/gamescope-session-plus"
printf '%s\n' 'OXP_LIST="ONE XPLAYER:ONEXPLAYER 2 ARP23:ONEXPLAYER 2 PRO ARP23H"' 'AOK_LIST="AOKZOE A1 AR07:AOKZOE A1 Pro"' \
	'if [[ ":$OXP_LIST:" =~ ":$SYS_ID:" ]] || [[ ":$AOK_LIST:" =~ ":$SYS_ID:" ]]; then' '  DRM_MODE=fixed' '  PANEL_TYPE=external' '  ORIENTATION=left' 'fi' >"$R$Q"
t_check '[ "$(t_state)" = off ]' "OneXPlayer 2: needed (external block)"
t_check 'sh "$FIX" install >/dev/null && [ "$(t_state)" = on ]' "OneXPlayer 2: install"
cp "$R$S/gamecove" "$R/probe"
sed -i "s|/sys/class/dmi/id/product_name|$R/sys/class/dmi/id/product_name|" "$R/probe"
t_check '[ "$(PANEL_TYPE=external sh -c ". \"$R/probe\"; echo \$PANEL_TYPE")" = internal ]' "OneXPlayer 2: PANEL_TYPE becomes internal"
sed -i 's/PANEL_TYPE=external/PANEL_TYPE=internal/' "$R$Q"
sh "$FIX" remove >/dev/null
t_check '[ "$(t_state)" = os-fixed ]' "OneXPlayer 2: block fixed upstream: os-fixed"
t_end
