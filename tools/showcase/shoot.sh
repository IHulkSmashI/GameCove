#!/usr/bin/env bash
# Renders the showcase screenshots: every screen with a real, lived-in
# profile (real games, Steam art, achievements, gamedb data, live Discover
# prices for Canada from snapshot/, favourites, an EmuDeck setup, apps, clips,
# cloud saves, battery history; see showcase.gd). Needs xvfb-run, Godot 4.7, python3 and
# network the first time (the art cache is downloaded into cache/, git-ignored).
#
#   tools/showcase/shoot.sh [OUT_DIR] [only,these,shots]
#     OUT_DIR   default /tmp/gamecove-showcase; one folder per size and theme
#               (1920x1200-cove, 1920x1200-light, 1280x800-cove, 1280x800-light)
#   GODOT=/path/to/godot      the Godot binary (default: godot)
#   SIZES="1920x1200 1280x800" THEMES="cove light"   what to render
#   DOCS=0                    skip the README copies in docs/images/
#   REFRESH=1                 re-fetch the data first (fetch.py, then record_discover.gd)
#   SHOWCASE_ROM_ART=0        the ROM games without art (console covers, console pattern hero)
#
# docs/images/<name>.webp are the README copies: the 1920x1200 Cove set,
# resized to 1600 px wide and compressed. Their names are stable; see
# README_NAMES below.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/../.." && pwd)"
out="${1:-/tmp/gamecove-showcase}"
only="${2:-}"
godot="${GODOT:-godot}"
sizes="${SIZES:-1920x1200 1280x800}"
themes="${THEMES:-cove light}"

if [[ "${REFRESH:-0}" == "1" ]]; then
	python3 -I "$here/fetch.py"
	rm -rf "$here/snapshot"
	"$godot" --headless --path "$repo/app" -s "$here/record_discover.gd"
fi
python3 -I "$here/fetch.py" --art-only
"$godot" --headless --path "$repo/app" --import >/dev/null 2>&1 || true

for res in $sizes; do
	w="${res%x*}"
	h="${res#*x}"
	for theme in $themes; do
		dir="$out/$res-$theme"
		mkdir -p "$dir"
		# the Fixes page on three handhelds and the start dialog: tools/screenshots/shoot_fixes.gd
		for script in showcase.gd showcase_stream.gd showcase_installer.gd ../screenshots/shoot_fixes.gd; do
			args=(--out "$dir")
			[[ -n "$only" ]] && args+=(--only "$only")
			SHOWCASE_THEME="$theme" SHOOT_THEME="$theme" xvfb-run -a -s "-screen 0 ${w}x${h}x24" \
				"$godot" --path "$repo/app" --rendering-driver opengl3 --resolution "$res" --position 0,0 \
				-s "$here/$script" -- "${args[@]}" 2>&1 | grep -E "^saved|SCRIPT ERROR" || true
		done
	done
done

# README copies: docs/images/<readme name>.webp from <shot name>.
README_NAMES=(
	home:home library:library library_filter:library-filter game:game game_achievements:achievements
	game_saves:game-saves home_shelves:home-emulation emulation:emulation apps_view:apps
	discover:discover discover_free:discover-free discover_deals:deals discover_calendar:calendar
	discover_calendar_month:calendar-month discover_wishlist:wishlist
	quick_game:quick-menu quick_power:quick-power quick_display:quick-display quick_audio:quick-audio
	quick_controller:quick-controller quick_leds:quick-leds quick_device:quick-device quick_shortcuts:quick-shortcuts
	settings_buttons:settings-buttons
	settings_power:settings-power settings_performance:settings-performance settings_system:settings-system
	settings_media:settings-media settings_saves:settings-saves settings_storage:settings-storage
	settings_battery:battery-history settings_about:device fixes_claw:fixes fixes_claw_details:fixes-details
	fixes_ally:fixes-retired fixes_claw_dialog:fixes-attention settings_updates:updates
	settings_privacy:privacy settings_profiles:profiles stream:stream installer:installer setup_art:game-art-setup
	keyboard:keyboard keyboard_code:keyboard-code
)
src="$out/1920x1200-cove"
if [[ "${DOCS:-1}" == "1" && -d "$src" ]]; then
	mkdir -p "$repo/docs/images"
	pairs=()
	for p in "${README_NAMES[@]}"; do
		pairs+=("$src/${p%%:*}.png=$repo/docs/images/${p##*:}")
	done
	python3 -I "$here/optimise.py" "${pairs[@]}"
	# The light theme, for the README's theme shots.
	[[ -f "$out/1920x1200-light/home.png" ]] && python3 -I "$here/optimise.py" "$out/1920x1200-light/home.png=$repo/docs/images/home-light.png"
	[[ -f "$out/1920x1200-light/quick_power.png" ]] && python3 -I "$here/optimise.py" "$out/1920x1200-light/quick_power.png=$repo/docs/images/quick-power-light.png"
	[[ -f "$out/1920x1200-light/quick_shortcuts.png" ]] && python3 -I "$here/optimise.py" "$out/1920x1200-light/quick_shortcuts.png=$repo/docs/images/quick-shortcuts-light.png"
	[[ -f "$out/1920x1200-light/settings_buttons.png" ]] && python3 -I "$here/optimise.py" "$out/1920x1200-light/settings_buttons.png=$repo/docs/images/settings-buttons-light.png"
	[[ -f "$out/1920x1200-light/game.png" ]] && python3 -I "$here/optimise.py" "$out/1920x1200-light/game.png=$repo/docs/images/game-light.png"
	[[ -f "$out/1920x1200-light/keyboard.png" ]] && python3 -I "$here/optimise.py" "$out/1920x1200-light/keyboard.png=$repo/docs/images/keyboard-light.png"
fi
echo "showcase: $out"
