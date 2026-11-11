#!/bin/sh
# A small free Steam game, start to finish, with the virtual pad: install it
# (Steam's own dialog confirmed with A), launch it, Guide for GameCove's quick
# menu over it (screenshot), B back to the game, GameCove's CPU and memory while
# it runs, quit, then uninstall it. Needs --allow-install-game (owner approved
# free games). DT_APPID picks the game (default 480, Spacewar: Valve's tiny free
# test app). The game is uninstalled at the end even when a step failed.
. "$(dirname "$0")/../lib.sh"

app="${DT_APPID:-480}"
if ! allowed install-game; then
	skip all "needs --allow-install-game (installs and removes Steam app $app)"
	exit 0
fi
pre_installed=0
installed "$app" && pre_installed=1
cleanup() {
	if [ "$pre_installed" = 0 ] && ! not_installed "$app"; then
		steam_uri "steam://uninstall/$app"
		sleep 4
		pad a
		wait_for 120 not_installed "$app" && pass uninstall "Steam app $app uninstalled" ||
			fail uninstall "Steam app $app still installed: remove it from Steam"
	fi
}
trap cleanup EXIT
if [ "$pre_installed" = 0 ]; then
	steam_uri "steam://install/$app"
	sleep 5
	shot install-dialog || true
	pad a   # Steam's install dialog: Install
	if wait_for 900 installed "$app"; then pass install "Steam app $app installed"; else fail install "not installed after 15 min"; exit 0; fi
else
	info install "Steam app $app was installed already (kept afterwards)"
fi
dir="$(game_dir "$app")"
steam_uri "steam://rungameid/$app"
if wait_for 90 running_with "${dir:-steamapps/common}"; then pass launch "the game runs"; else fail launch "the game didn't start in 90 s"; exit 0; fi
sleep 5
shot in-game || warn shot "no screenshot (gamescope's display not found)"
pad guide
sleep 2
shot quick-menu || true
manual look.quick-menu "evidence quick-menu.png: GameCove's quick menu is over the game, named after it"
pad down down
sleep 1
pad b
sleep 2
shot back-in-game || true
gc="$(gamecove_pid)"
if [ -n "$gc" ]; then
	s="$(proc_sample "$gc" 20)"
	echo "$s" >"$CHECK_OUT/gamecove-behind-game.txt"
	cpu="${s% *}"
	rss="${s#* }"
	awk -v c="$cpu" -v lim="${DT_CPU_MAX:-3}" 'BEGIN { exit !(c >= 0 && c <= lim) }' &&
		pass perf "GameCove behind the game: ${cpu}% CPU, ${rss} MiB" ||
		fail perf "GameCove behind the game: ${cpu}% CPU (over ${DT_CPU_MAX:-3}%), ${rss} MiB"
else
	[ "$DT_DRY" = 1 ] && skip perf "dry run" || warn perf "GameCove isn't running (start the GameCove session for this part)"
fi
# quit: what GameCove's Exit game does (TERM to the game's processes)
run pkill -TERM -u "$(id -u)" -f "${dir:-steamapps/common/__none__}" || true
if wait_for 30 sh -c "! pgrep -u $(id -u) -f '${dir:-steamapps/common/__none__}' >/dev/null"; then
	pass exit "the game ended"
else
	fail exit "the game is still running after 30 s"
fi
sleep 3
shot after-game || true
manual look.after-game "evidence after-game.png: back on GameCove's Home, focus visible"
