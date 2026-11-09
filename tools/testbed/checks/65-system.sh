#!/bin/sh
# Fixes page, Updates page and upscaling, from the system side (read-only: checks only,
# nothing is installed). The pages themselves are manual steps.
. "$(dirname "$0")/lib.sh"
if [ -x "$GC_ROOT$GC_FIX" ] || [ -x "$GC_FIX" ]; then
	"$GC_FIX" --list >"$CHECK_OUT/fixes.txt" 2>/dev/null
	for f in $(cat "$CHECK_OUT/fixes.txt"); do
		s="$("$GC_FIX" "$f" status 2>/dev/null | tr '\n' ' ')"
		case "$s" in *applies=no*) continue ;; esac
		info "fix.$f" "$s"
	done
	pass fixes "fix statuses read (out/system/fixes.txt)"
else
	skip fixes "GameCove isn't installed"
fi
manual fixes-page "Settings > Fixes: every fix listed for this model shows the same status as above; Undo one optional fix and Apply it again (Desktop Mode: password prompt)"

case "$(os_id)" in
steamos)
	h="$GC_ROOT/usr/bin/steamos-polkit-helpers/steamos-update"
	if [ -x "$h" ]; then
		"$h" check >"$CHECK_OUT/os-update.txt" 2>&1
		rc=$?
		case "$rc" in 0 | 7) pass os-update "steamos-update check: $([ "$rc" = 0 ] && echo 'update available' || echo 'up to date') (exit $rc)" ;; *) warn os-update "steamos-update check exited $rc" ;; esac
	else
		warn os-update "no steamos-update helper"
	fi
	;;
*)
	if have rpm-ostree; then
		rpm-ostree upgrade --check >"$CHECK_OUT/os-update.txt" 2>&1
		rc=$?
		case "$rc" in 0 | 77) pass os-update "rpm-ostree upgrade --check without a prompt (exit $rc)" ;; *) warn os-update "rpm-ostree upgrade --check exited $rc (polkit rule missing?)" ;; esac
	fi
	;;
esac
if have fwupdmgr; then
	fwupdmgr get-devices --json >"$CHECK_OUT/fwupd-devices.json" 2>/dev/null && info fwupd "fwupd devices saved" || info fwupd "fwupdmgr get-devices failed"
fi
if have flatpak; then
	flatpak remote-ls --updates --columns=application >"$CHECK_OUT/flatpak-updates.txt" 2>/dev/null
	info flatpak "$(wc -l <"$CHECK_OUT/flatpak-updates.txt" | tr -d ' ') Flatpak update(s) listed"
fi
manual updates-page "Updates page: OS / firmware / Flatpak / drivers each show the same as above; check again; nothing applies by itself"
if [ -x "$GC_ROOT/usr/libexec/gamecove/gamecove-upscale" ]; then
	"$GC_ROOT/usr/libexec/gamecove/gamecove-upscale" state >"$CHECK_OUT/upscale-state.json" 2>/dev/null
	info upscale "gamecove-upscale state saved"
fi
ls "$GC_HOME"/.local/share/vulkan/implicit_layer.d/*lsfg* >/dev/null 2>&1 && info lsfg "lsfg-vk layer installed" || info lsfg "lsfg-vk not installed (frame generation needs it and your own Lossless Scaling)"
manual upscaling "Upscaling on the test game: pick the recommended upscaler, launch, confirm in the game's settings / OptiScaler overlay; then Undo: the game folder is back to stock"
manual framegen "Frame generation (lsfg-vk, if you own Lossless Scaling): 2x on the test game, MangoHud shows about double fps; off again"
