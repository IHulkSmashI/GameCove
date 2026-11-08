#!/bin/sh
# GameCove fix: the two MSI face buttons on the Claw 8 EX AI+ (board MS-1T91).
# usage: fix.sh install|remove|status
#
# Its firmware sends Win+G for the left face button and F15 alone for the right one; InputPlumber's stock
# map for the board (claw2) waits for the chord F15+G and for F16, so both buttons do nothing. This adds a
# capability map (Guide = G, QuickAccess = F15, M1/M2 back buttons) and points the board's device config at
# it through InputPlumber's own override folders in /etc. See README.md.
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=fixes/lib/claw8ex-common.sh
. "$HERE/../lib/claw8ex-common.sh"

NAME=claw8ex-buttons
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
		say "already installed"
		return 0
	fi
	ip_require_free
	stock=$(stock_map)
	[ -n "$stock" ] || die "$IP_STOCK has no capability_map_id"
	if [ "$stock" != claw2 ]; then
		say "not needed: this InputPlumber already ships its own map ($stock) for the Claw 8 EX"
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
	installed=no
	m_installed && ip_flag buttons && [ -f "$ROOT$MAP" ] && grep -q "^capability_map_id: $IP_MAP_ID" "$ROOT$IP_OVERRIDE" 2>/dev/null && installed=yes
	active=$(systemctl is-active inputplumber 2>/dev/null || true)
	say "applies=yes"
	say "installed=$installed"
	say "stock_map=${stock:-none}"
	say "inputplumber=${active:-unknown}"
	if [ "$installed" = yes ] && [ "$active" = active ]; then
		say "state=on"
	elif [ "$installed" = yes ]; then
		say "state=partial"
	elif [ -n "$stock" ] && [ "$stock" != claw2 ]; then
		say "state=not-needed"
	else
		say "state=off"
	fi
}

case ${1:-} in
install) install ;;
remove) remove ;;
status) status ;;
*) die "usage: $0 install|remove|status" ;;
esac
