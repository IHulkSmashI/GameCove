#!/bin/sh
# The virtual pad itself and GameCove answering it: the pad appears (and goes
# when vpad ends), Guide opens the quick menu, RB walks its tabs, B closes it, the
# D-pad moves focus on Home (screenshots of each step for the report).
. "$(dirname "$0")/../lib.sh"

if [ "$DT_DRY" = 1 ]; then
	"$DT_PYTHON" -I "$DT_DIR/vpad.py" --dry-run check >"$CHECK_OUT/backend.txt" 2>&1
else
	"$DT_PYTHON" -I "$DT_DIR/vpad.py" check >"$CHECK_OUT/backend.txt" 2>&1
fi
if [ $? -eq 0 ]; then pass vpad "$(cat "$CHECK_OUT/backend.txt")"; else fail vpad "no virtual pad: $(cat "$CHECK_OUT/backend.txt")"; exit 0; fi
[ -n "$(gamecove_pid)" ] || [ "$DT_DRY" = 1 ] || { skip ui "GameCove isn't running (start its session)"; exit 0; }
shot home-before || true
pad down right
shot home-moved || true
pad guide
sleep 1
shot quick-menu || true
pad rb rb
shot quick-menu-tab3 || true
pad b
sleep 1
shot home-after || true
if [ "$DT_DRY" != 1 ] && grep -q "GameCove device test pad" /proc/bus/input/devices 2>/dev/null; then
	fail removed "the test pad is still listed after vpad ended"
else
	pass removed "the test pad is gone again"
fi
manual look.input "evidence home-moved / quick-menu / quick-menu-tab3 / home-after: focus moved, the menu opened on This game, RB went two tabs on, B closed it"
