#!/bin/sh
# OptiScaler into a free DX12 Steam game and out again, through GameCove's own
# upscaling helper (what the quick menu's Upscaler runs): status, apply (the
# recommended setup), the files in the game folder, undo, the folder as it was.
# Needs DT_DX12_APPID (an installed free DX12 game); downloads OptiScaler once.
. "$(dirname "$0")/../lib.sh"

app="${DT_DX12_APPID:-}"
[ -n "$app" ] || { skip all "set DT_DX12_APPID to an installed free DX12 Steam game"; exit 0; }
if [ "$DT_DRY" != 1 ]; then
	[ -x "$DT_UPSCALE" ] || { skip all "GameCove's upscaling helper isn't installed ($DT_UPSCALE)"; exit 0; }
	installed "$app" || { skip all "Steam app $app isn't installed"; exit 0; }
fi
case "$(device_kind)" in
claw8ex) gpu='{"vendor":"intel","family":"intel-xe2","arch":"Xe2","xmx":true}' ;;
*) gpu='{"vendor":"amd","family":"amd-rdna3","arch":"RDNA3","xmx":false}' ;;
esac
dir="$(game_dir "$app")"
up() { run "$DT_UPSCALE" "$1" --home "$GC_HOME" --key "$app" --gpu "$gpu" ${dir:+--dir "$dir"} >"$CHECK_OUT/$1.json" 2>&1; }
ls -R "$dir" >"$CHECK_OUT/before.txt" 2>/dev/null || true
up status && info status "$(head -c 300 "$CHECK_OUT/status.json")"
if up apply && { [ "$DT_DRY" = 1 ] || grep -q '"ok": *true' "$CHECK_OUT/apply.json"; }; then
	pass apply "the recommended setup went in ($(head -c 200 "$CHECK_OUT/apply.json"))"
else
	fail apply "$(head -c 300 "$CHECK_OUT/apply.json" 2>/dev/null)"
fi
ls -R "$dir" >"$CHECK_OUT/applied.txt" 2>/dev/null || true
if [ "$DT_DRY" = 1 ] || grep -qi 'optiscaler\|nvngx\|dxgi.dll\|winmm.dll' "$CHECK_OUT/applied.txt"; then
	pass files "OptiScaler's files are in the game folder"
else
	fail files "no OptiScaler files found in $dir"
fi
manual look.optiscaler "Start the game from GameCove: OptiScaler's overlay (Insert) shows; pick the upscaler in the game's menu"
if up undo && { [ "$DT_DRY" = 1 ] || grep -q '"ok": *true' "$CHECK_OUT/undo.json"; }; then pass undo "taken out"; else fail undo "$(head -c 300 "$CHECK_OUT/undo.json" 2>/dev/null)"; fi
ls -R "$dir" >"$CHECK_OUT/after.txt" 2>/dev/null || true
if [ "$DT_DRY" = 1 ] || cmp -s "$CHECK_OUT/before.txt" "$CHECK_OUT/after.txt"; then
	pass restored "the game folder is as it was"
else
	fail restored "the game folder differs from before (before.txt / after.txt)"
fi
