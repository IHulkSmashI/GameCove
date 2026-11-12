#!/bin/sh
# GameCove fix: the two MSI face buttons on the Claw 8 EX AI+ (board MS-1T91).
# usage: fix.sh install|remove|update|status
#
# Its firmware sends Win+G for the left face button and F15 alone for the right one; InputPlumber's stock
# map for the board (claw2) waits for the chord F15+G and for F16, so both buttons do nothing. This adds a
# capability map (Guide = G, QuickAccess = F15, M1/M2 back buttons) and points the board's device config at
# it through InputPlumber's own override folders in /etc. See fixes/README.md.
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=fixes/lib/claw8ex-common.sh
. "$HERE/../lib/claw8ex-common.sh"

NAME=claw8ex-buttons
REVISION=1 # = "revision" in fix.json
MAP=/etc/inputplumber/capability_maps.d/gamecove_claw8ex.yaml
m_init "$NAME"

map_text() {
	cat <<EOF
# GameCove: MSI Claw 8 EX AI+ (MS-1T91). Its firmware sends Win+G for the left face button and F15 alone for
# the right one; the stock map (claw2) waits for the chord F15+G and for F16, so both buttons are dropped.
# Remove with: gamecove-fix $NAME remove
version: 1
kind: CapabilityMap
name: MSI Claw 8 EX (GameCove)
id: $IP_MAP_ID
mapping:
  - name: Guide
    source_events:
      - keyboard: KeyG
    target_event:
      gamepad:
        button: Guide
  - name: QuickAccess
    source_events:
      - keyboard: KeyF15
    target_event:
      gamepad:
        button: QuickAccess
  - name: M1
    source_events:
      - keyboard: KeyRightBrace
    target_event:
      gamepad:
        button: RightPaddle1
  - name: M2
    source_events:
      - keyboard: KeyLeftBrace
    target_event:
      gamepad:
        button: LeftPaddle1
filtered_events: []
EOF
}

stock_map() { sed -n 's/^capability_map_id:[[:space:]]*\([^[:space:]]*\).*/\1/p' "$ROOT$IP_STOCK" 2>/dev/null | head -n 1; }

install() {
	require_root
	require_board
	lock
	if m_installed; then
		if ip_flag buttons && [ -f "$ROOT$MAP" ]; then
			say "already installed"
			return 0
		fi
		# a record whose map or flag is gone (an InputPlumber reset, a cut-short install): it said "already
		# installed" and nothing could mend it, and uninstall skipped it (status installed=no). Start clean.
		m_undo || true
	fi
	ip_require_free
	stock=$(stock_map)
	[ -n "$stock" ] || die "$IP_STOCK has no capability_map_id"
	if ip_stock_handles_buttons; then
		say "not needed: this InputPlumber's own map ($stock) already takes both face buttons"
		return 0
	fi
	GC_TMP=$(mktemp -d)
	map_text >"$GC_TMP/map.yaml"
	if ! ip_mkdirs || ! m_put "$GC_TMP/map.yaml" "$MAP" 644; then
		m_undo || true
		die "could not write $MAP"
	fi
	if ! ip_flag_on buttons; then
		m_undo || true
		die "could not write the InputPlumber override"
	fi
	m_add ipflag buttons
	! ip_clawdeck_backed_up || m_add clawdeck "$IP_OVERRIDE"
	m_add rev "$REVISION"
	say "installed: left face button = Steam menu, right face button = Quick Access"
}

remove() {
	require_root
	lock
	if ! m_installed; then
		say "not installed"
		return 0
	fi
	m_undo || die "some changes could not be undone; see the messages above and run remove again"
	say "removed: InputPlumber is back to its stock config for the face buttons"
}

status() {
	if [ "$(board_name)" != "$BOARD_WANTED" ]; then
		say "applies=no"
		say "state=n/a"
		return 0
	fi
	stock=$(stock_map)
	native=no
	ip_stock_handles_buttons && native=yes
	points=no
	grep -q "^capability_map_id: $IP_MAP_ID" "$ROOT$IP_OVERRIDE" 2>/dev/null && points=yes
	installed=no
	# ours is in place: our record, flag and map, and the override pointing at the map (or, once
	# InputPlumber ships its own map, standing aside for it after `set refresh`)
	m_installed && ip_flag buttons && [ -f "$ROOT$MAP" ] && { [ "$points" = yes ] || [ "$native" = yes ]; } && installed=yes
	active=$(systemctl is-active inputplumber 2>/dev/null || true)
	say "applies=yes"
	say "installed=$installed"
	say_revision
	# InputPlumber's stock map takes the firmware's keys now: the system does it (also with ours still in place)
	say "os_fixed=$native"
	# both at once: our override still names our map although InputPlumber has its own (until the
	# next `set refresh` rebuilds it, or the fix is removed)
	if [ "$installed" = yes ]; then
		if [ "$native" = yes ] && [ "$points" = yes ]; then say "conflict=yes"; else say "conflict=no"; fi
	fi
	say "stock_map=${stock:-none}"
	say "inputplumber=${active:-unknown}"
	say "inputplumber_override=$(ip_override_state)"
	if [ "$installed" = yes ] && [ "$active" = active ]; then
		say "state=on"
	elif [ "$installed" = yes ]; then
		say "state=partial"
	elif [ "$native" = yes ]; then
		say "state=not-needed"
	else
		say "state=off"
	fi
}

case ${1:-} in
install) install ;;
update) require_root; gc_root_update ;;
remove) remove ;;
status) status ;;
set)
	# set refresh: rebuild the shared InputPlumber override if the stock file changed (no password)
	[ "${2:-}" = refresh ] && [ $# -eq 2 ] || die "usage: $0 set refresh"
	require_root
	lock
	ip_refresh
	;;
*) die "usage: $0 install|remove|update|status|set refresh" ;;
esac
