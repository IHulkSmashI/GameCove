#!/bin/sh
# Logs from this boot: GameCove, gamescope, InputPlumber, polkit; crashes; root actions.
. "$(dirname "$0")/lib.sh"
"$GC_JOURNALCTL" --user -b --no-pager -o short-monotonic 2>/dev/null |
	grep -i -E 'gamecove|gamescope|mangoapp|steamos-manager' | tail -n 600 >"$CHECK_OUT/journal-user.txt"
"$GC_JOURNALCTL" -b --no-pager -o short-monotonic 2>/dev/null |
	grep -i -E 'gamecove|inputplumber|hhd|polkit.*gamecove|systemd-sysext|powerstation' | tail -n 400 >"$CHECK_OUT/journal-system.txt"
for f in "$GC_DATA"/*.log "$GC_HOME"/.local/share/godot/app_userdata/GameCove/logs/godot.log; do
	[ -f "$f" ] && tail -n 1000 "$f" >"$CHECK_OUT/$(basename "$f")"
done
cp "$GC_ROOT/var/lib/gamecove/changes.log" "$CHECK_OUT/changes.log" 2>/dev/null
n="$(grep -c -E 'SCRIPT ERROR|ERROR:' "$CHECK_OUT/godot.log" 2>/dev/null)"
[ "${n:-0}" -eq 0 ] && pass godot "no script errors in GameCove's log" || fail godot "$n error line(s) in godot.log"
n="$(grep -c 'result=fail' "$CHECK_OUT/changes.log" 2>/dev/null)"
[ "${n:-0}" -eq 0 ] && pass root-actions "no failed root actions in changes.log" || warn root-actions "$n failed root action(s) in changes.log"
if have coredumpctl; then
	coredumpctl list --no-pager -q 2>/dev/null | grep -i -E 'gamecove|gamescope|inputplumber' >"$CHECK_OUT/coredumps.txt"
	[ -s "$CHECK_OUT/coredumps.txt" ] && fail coredumps "crash dumps this boot: $(wc -l <"$CHECK_OUT/coredumps.txt")" || pass coredumps "no GameCove / gamescope / InputPlumber crash dumps"
fi
