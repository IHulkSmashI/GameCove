#!/bin/sh
# gamescope while GameCove's session runs: the atoms GameCove sets and reads, mangoapp,
# the panel's VRR state. Skips in Desktop Mode.
. "$(dirname "$0")/lib.sh"
d="$(gamescope_display)"
[ -n "$d" ] || { skip atoms "no gamescope session found (run this while GameCove's session runs)"; exit 0; }
info display "gamescope Xwayland $d"
base="$(xprop_root GAMESCOPECTRL_BASELAYER_APPID)"
foc="$(xprop_root GAMESCOPE_FOCUSED_APP)"
apps="$(xprop_root GAMESCOPE_FOCUSABLE_APPS)"
fps="$(xprop_root GAMESCOPE_FPS_LIMIT)"
printf 'baselayer=%s\nfocused=%s\nfocusable=%s\nfps_limit=%s\n' "$base" "$foc" "$apps" "$fps" >"$CHECK_OUT/atoms.txt"
case ", $base, " in
", , ") fail baselayer "GAMESCOPECTRL_BASELAYER_APPID not set" ;;
*", 769, "*) pass baselayer "GAMESCOPECTRL_BASELAYER_APPID = $base (GameCove is 769)" ;;
*) warn baselayer "GAMESCOPECTRL_BASELAYER_APPID = $base (no 769: is GameCove in front?)" ;; esac
[ -n "$apps" ] && pass focusable "GAMESCOPE_FOCUSABLE_APPS = $apps" || fail focusable "GAMESCOPE_FOCUSABLE_APPS missing"
info focused "GAMESCOPE_FOCUSED_APP = ${foc:-none}, GAMESCOPE_FPS_LIMIT = ${fps:-0}"
if DISPLAY="$d" "$GC_XPROP" -root -notype 2>/dev/null | grep -E '^GAMESCOPE_(VRR|ALLOW_TEARING|SHARPNESS|SCALE|FSR|COLOR|SDR|HDR|DISPLAY)' >"$CHECK_OUT/gamescope-atoms.txt"; then
	info more "$(wc -l <"$CHECK_OUT/gamescope-atoms.txt") more GAMESCOPE_* atoms saved"
fi
pgrep -x mangoapp >/dev/null 2>&1 && pass mangoapp "mangoapp runs (performance overlay)" || warn mangoapp "mangoapp isn't running: the overlay controls are unavailable"
for f in "$GC_ROOT"/sys/class/drm/card*-eDP-*/vrr_capable; do
	[ -e "$f" ] && info "vrr.$(basename "$(dirname "$f")")" "vrr_capable=$(head -n 1 "$f")"
done
manual fps-limit "Start a game, set FPS limit 30 in the quick menu: GAMESCOPE_FPS_LIMIT reads 30 (run this check again) and MangoHud shows ~30"
manual home-back "Quit the game: GameCove is in front within ~6 s and GAMESCOPECTRL_BASELAYER_APPID ends in 769"
