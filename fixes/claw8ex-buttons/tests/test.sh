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

# Stand down only when InputPlumber's own map takes what this firmware sends (read from the map, not its name).
CLAW2_MAP='version: 1
kind: CapabilityMap
name: MSI Claw Type 2
id: claw2
mapping:
  - name: Guide (Short)
    source_events:
      - keyboard: KeyF15
      - keyboard: KeyG
    target_event:
      gamepad:
        button: Guide
  - name: QuickAccess
    source_events:
      - keyboard: KeyF16
    target_event:
      gamepad:
        button: QuickAccess
filtered_events: []
'
stock_map_file() { mkdir -p "$R/usr/share/inputplumber/capability_maps"; printf '%s' "$1" >"$R/usr/share/inputplumber/capability_maps/$2.yaml"; }
case_start stock_map_still_broken
stock_map_file "$CLAW2_MAP" msiclaw_type2
ok 'fix claw8ex-buttons status | grep -qx os_fixed=no' "InputPlumber's claw2 (F15+G chord, F16): not fixed"
ok 'fix claw8ex-buttons status | grep -qx state=off' "still offered"
case_start stock_map_fixed_in_place
# claw2 keeps its name but now takes Win+G and F15 alone
stock_map_file "$(printf '%s' "$CLAW2_MAP" | sed 's/keyboard: KeyF15$/keyboard: KeyLeftMeta/; s/keyboard: KeyF16/keyboard: KeyF15/')" msiclaw_type2
ok 'fix claw8ex-buttons status | grep -qx os_fixed=yes' "claw2 fixed in place: os_fixed=yes"
before=$(snapshot)
ok 'fix claw8ex-buttons install | grep -q "not needed"' "install stands down"
ok '[ "$(snapshot)" = "$before" ]' "nothing changed"
ok 'fix claw8ex-buttons status | grep -qx state=not-needed' "status not-needed"
fix claw8ex-buttons remove >/dev/null 2>&1
case_start stock_map_new_but_half_fixed
# a new map for the board that fixes QuickAccess but still waits for the F15+G chord: ours is still needed
sed -i 's/capability_map_id: claw2/capability_map_id: claw8ex_up/' "$R/usr/share/inputplumber/devices/50-msi_claw8_ex_ai_cg3em.yaml"
stock_map_file "$(printf '%s' "$CLAW2_MAP" | sed 's/^id: claw2/id: claw8ex_up/; s/keyboard: KeyF16/keyboard: KeyF15/')" msiclaw_8ex
ok 'fix claw8ex-buttons status | grep -qx os_fixed=no' "half-fixed new map: os_fixed=no"
fix claw8ex-buttons install >/dev/null 2>&1; rc=$?
ok "[ $rc -eq 0 ] && override | grep -qx 'capability_map_id: gamecove_claw8ex'" "installs over a map that still drops Guide"
case_start stock_map_new_and_fixed
sed -i 's/capability_map_id: claw2/capability_map_id: claw8ex_up/' "$R/usr/share/inputplumber/devices/50-msi_claw8_ex_ai_cg3em.yaml"
stock_map_file "$(printf '%s' "$CLAW2_MAP" | sed 's/^id: claw2/id: claw8ex_up/; s/      - keyboard: KeyF15$//; s/keyboard: KeyF16/keyboard: KeyF15/')" msiclaw_8ex
ok 'fix claw8ex-buttons status | grep -qx os_fixed=yes' "new map with G alone and F15 alone: os_fixed=yes"

case_start existing_etc_inputplumber
mkdir -p "$R/etc/inputplumber/capability_maps.d"
echo keep >"$R/etc/inputplumber/capability_maps.d/other.yaml"
before=$(snapshot)
fix claw8ex-buttons install >/dev/null
fix claw8ex-buttons remove >/dev/null
ok '[ "$(snapshot)" = "$before" ]' "existing folders and files kept"

# review S1-4: an OS update changes the stock file; the override must follow it, never stay frozen
case_start stock_updated
STOCK="$R/usr/share/inputplumber/devices/50-msi_claw8_ex_ai_cg3em.yaml"
fix claw8ex-buttons install >/dev/null 2>&1
ok 'override | grep -q "^# stock-sha256: $(sha256sum "$STOCK" | cut -d " " -f 1)$"' "override records the stock file's sha256"
ok 'fix claw8ex-buttons status | grep -qx inputplumber_override=current' "status: current"
printf '# new field from an InputPlumber update\nnew_schema_field: true\n' >>"$STOCK"
ok 'fix claw8ex-buttons status | grep -qx inputplumber_override=stale' "status: stale after the stock file changed"
: >"$FAKE/calls"
fix claw8ex-buttons set refresh >/dev/null 2>&1; rc=$?
ok "[ $rc -eq 0 ]" "refresh succeeds"
ok 'override | grep -qx "new_schema_field: true"' "rebuilt from the new stock file"
ok 'override | grep -qx "capability_map_id: gamecove_claw8ex"' "our map still in"
ok 'fix claw8ex-buttons status | grep -qx inputplumber_override=current' "current again"
ok 'grep -q "systemctl restart inputplumber" "$FAKE/calls"' "InputPlumber restarted"
: >"$FAKE/calls"
fix claw8ex-buttons set refresh >/dev/null 2>&1
ok '! grep -q "systemctl restart inputplumber" "$FAKE/calls"' "a current override isn't touched"
# a layout we can't edit (no capability_map_id line): drop to stock, never keep the old copy
sed -i '/^capability_map_id:/d' "$STOCK"
fix claw8ex-buttons set refresh >/dev/null 2>&1; rc=$?
ok "[ $rc -eq 0 ]" "refresh with an unknown layout still succeeds"
ok '[ ! -e "$R/etc/inputplumber/devices.d/50-msi_claw8_ex_ai_cg3em.yaml" ]' "stale override removed: InputPlumber uses the stock file"
ok 'fix claw8ex-buttons status | grep -qx inputplumber_override=dropped' "status: dropped"
# a later stock file GameCove can edit again brings it back
echo "capability_map_id: claw2" >>"$STOCK"
fix claw8ex-buttons set refresh >/dev/null 2>&1
ok 'override | grep -qx "capability_map_id: gamecove_claw8ex"' "rebuilt once the layout is editable again"
ok '! fix claw8ex-buttons set other 2>/dev/null' "only refresh can be set"

finish
