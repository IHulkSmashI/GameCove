#!/bin/sh
# EmuDeck on this handheld (the Claw has EmuDeck and three homebrew ROMs): the
# ROM folders GameCove's Emulation page reads, and each of up to three ROMs
# started through EmuDeck's own launcher for its system, seen running, a
# screenshot, and closed.
. "$(dirname "$0")/../lib.sh"

emu="$GC_HOME/Emulation"
[ -d "$emu/roms" ] || { skip all "EmuDeck isn't set up here (no ~/Emulation/roms)"; exit 0; }
pass emudeck "EmuDeck's ROM folders are there"
n=0
for rom in "$emu"/roms/*/*; do
	[ -f "$rom" ] || continue
	case "$rom" in *.txt | *.md | */systeminfo* | *metadata*) continue ;; esac
	sys="$(basename "$(dirname "$rom")")"
	launcher=""
	for l in "$emu/tools/launchers/retroarch.sh" "$emu/tools/launchers/$sys.sh"; do
		[ -x "$l" ] && launcher="$l" && break
	done
	[ -n "$launcher" ] || { info "rom.$sys" "no EmuDeck launcher for $sys"; continue; }
	n=$((n + 1))
	run "$launcher" "$rom" >"$CHECK_OUT/rom-$n.log" 2>&1 &
	p=$!
	if wait_for 30 running_with "$(basename "$rom")"; then pass "rom.$n" "$sys: $(basename "$rom") runs"; else fail "rom.$n" "$sys: $(basename "$rom") didn't start"; fi
	sleep 5
	shot "rom-$n" || true
	run pkill -TERM -u "$(id -u)" -f "$(basename "$rom")" || true
	kill "$p" 2>/dev/null || true
	sleep 3
	[ "$n" -ge 3 ] && break
done
[ "$n" -gt 0 ] || warn roms "no ROM to start (put homebrew ROMs in ~/Emulation/roms/<system>/)"
manual look.emulation "GameCove > Library > Filter > Emulation page: the three ROMs are listed and start"
