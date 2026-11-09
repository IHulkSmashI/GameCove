#!/bin/sh
# Profiles on this hardware: a game's value goes on at game start and off at the end, and
# the AC / battery layers follow the charger (simulated through Profiles.set_plugged; the
# real unplug is 40-power-source). Every stored layer is put back afterwards.
. "$(dirname "$0")/lib.sh"

[ -x "$GC_APP" ] || { skip profiles "GameCove isn't installed"; exit 0; }
controls list >"$CHECK_OUT/list.txt"
pick=""
for id in ${GC_PROFILE_IDS:-power.tdp power.epp power.fan_mode power.platform_profile power.cpu_boost display.fps_limit perf.overlay}; do
	if grep -q "^control	$id	.*	available=yes	.*per_game=yes" "$CHECK_OUT/list.txt"; then
		pick="$id"
		break
	fi
done
[ -n "$pick" ] || { skip profiles "no per-game control available here (power service or session missing?)"; exit 0; }
now="$(controls get "$pick" | sed -n 's/.*	value=//p')"
line="$(grep "^control	$pick	" "$CHECK_OUT/list.txt")"
alt="$(controls probe "$pick" | tr '\t' '\n' | sed -n 's/^to=//p')"
[ -n "$alt" ] || { skip profiles "$pick: no second value to try"; exit 0; }
info control "$pick (now $now, test value $alt): $(printf '%s' "$line" | cut -f4,9)"
r="$(controls profile-test "$pick" "$alt")"
printf '%s\n' "$r" >"$CHECK_OUT/profile-test.txt"
case "$r" in *result=ok*) pass game "game layer on at start, off at the end: $(printf '%s' "$r" | cut -f4- | tr '\t' ' ')" ;;
*) fail game "$(printf '%s' "$r" | cut -f3- | tr '\t' ' ')" ;; esac
r="$(controls source-test "$pick" "$alt" "$now")"
printf '%s\n' "$r" >"$CHECK_OUT/source-test.txt"
case "$r" in *result=ok*) pass source "AC and battery layers apply on a charger change: $(printf '%s' "$r" | cut -f4- | tr '\t' ' ')" ;;
*) fail source "$(printf '%s' "$r" | cut -f3- | tr '\t' ' ')" ;; esac
manual in-game "In a real game: open the quick menu, change TDP and FPS limit, 'Save as this game's profile'; quit and relaunch: the values come back; at home they're the everyday ones"
