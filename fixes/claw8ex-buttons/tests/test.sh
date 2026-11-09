#!/bin/sh
# claw8ex-buttons against a fake root: install/status/remove roundtrip, refusals.
# usage: sh fixes/claw8ex-buttons/tests/test.sh
# shellcheck disable=SC2016,SC2034 # ok() evals its single-quoted check later, on purpose
set -u
# shellcheck source=fixes/claw8ex-buttons/tests/lib.sh
. "$(dirname "$0")/lib.sh"

case_start roundtrip
before=$(snapshot)
fix claw8ex-buttons install >/dev/null 2>&1; rc=$?
ok "[ $rc -eq 0 ]" "install succeeds"
ok 'override | grep -qx "capability_map_id: gamecove_claw8ex"' "override points at our map"
ok 'override | head -n 1 | grep -q "^# GameCove override"' "override is marked as ours"
ok '[ -f "$R/etc/inputplumber/capability_maps.d/gamecove_claw8ex.yaml" ]' "map written"
ok 'grep -q "keyboard: KeyF15" "$R/etc/inputplumber/capability_maps.d/gamecove_claw8ex.yaml"' "QuickAccess = F15"
ok 'grep -q "systemctl restart inputplumber" "$FAKE/calls"' "InputPlumber restarted"
ok 'fix claw8ex-buttons status | grep -qx state=on' "status on"
ok 'fix claw8ex-buttons install | grep -q "already installed"' "second install is a no-op"
fix claw8ex-buttons remove >/dev/null
ok '[ "$(snapshot)" = "$before" ]' "remove restores the fake root exactly"
ok 'fix claw8ex-buttons status | grep -qx state=off' "status off"
ok 'fix claw8ex-buttons remove | grep -q "not installed"' "second remove is a no-op"

case_start override_is_device_matched
fix claw8ex-buttons install >/dev/null 2>&1
# InputPlumber only uses a device config whose matches fit the hardware; the override keeps the stock match.
ok 'override | grep -A2 "^matches:" | grep -q "board_name: MS-1T91"' "override still matches only board MS-1T91"
ok '[ "$(override | grep -c "dmi_data:")" = 1 ]' "one match block, unchanged"
ok '! grep -rl "gamecove_claw8ex" "$R/etc/inputplumber/devices.d" | grep -v 50-msi_claw8_ex_ai_cg3em.yaml' "only the Claw's config points at the map"

case_start other_board
echo MS-1T52 >"$R/sys/class/dmi/id/board_name"
before=$(snapshot)
ok '! fix claw8ex-buttons install 2>/dev/null' "refuses on another board"
ok '[ "$(snapshot)" = "$before" ]' "nothing changed"
ok 'fix claw8ex-buttons status | grep -qx applies=no' "status: doesn't apply"

case_start foreign_override
mkdir -p "$R/etc/inputplumber/devices.d"
echo "# someone else's" >"$R/etc/inputplumber/devices.d/50-msi_claw8_ex_ai_cg3em.yaml"
before=$(snapshot)
ok '! fix claw8ex-buttons install 2>/dev/null' "refuses with someone else's override"
ok '[ "$(snapshot)" = "$before" ]' "their override untouched"

case_start upstream_fixed
sed -i 's/capability_map_id: claw2/capability_map_id: claw8ex_upstream/' "$R/usr/share/inputplumber/devices/50-msi_claw8_ex_ai_cg3em.yaml"
before=$(snapshot)
ok 'fix claw8ex-buttons install | grep -q "not needed"' "not needed when InputPlumber has its own map"
ok '[ "$(snapshot)" = "$before" ]' "nothing changed"
ok 'fix claw8ex-buttons status | grep -qx state=not-needed' "status not-needed"

case_start existing_etc_inputplumber
mkdir -p "$R/etc/inputplumber/capability_maps.d"
echo keep >"$R/etc/inputplumber/capability_maps.d/other.yaml"
before=$(snapshot)
fix claw8ex-buttons install >/dev/null
fix claw8ex-buttons remove >/dev/null
ok '[ "$(snapshot)" = "$before" ]' "existing folders and files kept"

finish
