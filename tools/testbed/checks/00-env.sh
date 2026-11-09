#!/bin/sh
# Which device, OS and stack this is, and the versions of everything GameCove talks to.
# Read-only. Fills env.txt (the report's "versions" part).
. "$(dirname "$0")/lib.sh"

kind="$(device_kind)"
info device "$(dmi sys_vendor) $(dmi product_name) (board $(dmi board_name), BIOS $(dmi bios_version))"
case "$kind" in
claw8ex) pass device "MSI Claw 8 EX: test plan section 'Claw 8 EX'" ;;
ally) pass device "ROG Ally (RC71L): test plan section 'ROG Ally'" ;;
legiongos) pass device "Legion Go S: test plan section 'Legion Go S'" ;;
*) warn device "not one of the three test devices; the device-specific checks will skip" ;;
esac
os="$(os_id)"
info os "$(os_field PRETTY_NAME) (ID=$os VERSION_ID=$(os_field VERSION_ID))"
case "$os" in
steamos | bazzite) pass os "$os" ;;
*) warn os "$os: GameCove installs on Bazzite / Fedora Atomic and SteamOS" ;;
esac

{
	echo "device_kind=$kind"
	echo "os=$os $(os_field VERSION_ID)"
	echo "kernel=$(uname -r 2>/dev/null)"
	[ -f "$GC_DATA/installer/release.env" ] && sed -n 's/^\(TAG\|OS\|SIGNATURE\)=/release_\1=/p' "$GC_DATA/installer/release.env"
	[ -f "$GC_DATA/install-state.json" ] && printf 'installed_version=%s\n' "$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$GC_DATA/install-state.json" | head -n 1)"
	if [ -f "$GC_ROOT/usr/lib/extension-release.d/extension-release.gamecove" ]; then
		echo "sysext_release=$(tr '\n' ' ' <"$GC_ROOT/usr/lib/extension-release.d/extension-release.gamecove")"
	fi
	have rpm && echo "rpm_gamecove=$(rpm -q gamecove 2>/dev/null)"
	have gamescope && echo "gamescope=$(gamescope --version 2>&1 | head -n 1)"
	have mangohud && echo "mangohud=present"
	have rpm && echo "mesa=$(rpm -q --qf '%{VERSION}' mesa-dri-drivers 2>/dev/null)"
	have pacman && echo "mesa=$(pacman -Q mesa 2>/dev/null)"
	have steamosctl && echo "steamos_manager=present"
	have hhd && echo "hhd=present"
	v="$("$GC_BUSCTL" --system get-property org.shadowblip.InputPlumber /org/shadowblip/InputPlumber/Manager org.shadowblip.InputManager Version 2>/dev/null)"
	echo "inputplumber_version=${v:-none}"
	have flatpak && echo "chrome=$(flatpak info com.google.Chrome 2>/dev/null | sed -n 's/^ *Version: //p' | head -n 1)"
	have flatpak && echo "moonlight=$(flatpak info com.moonlight_stream.Moonlight 2>/dev/null | sed -n 's/^ *Version: //p' | head -n 1)"
} >"$CHECK_OUT/env.txt" 2>/dev/null

for unit in inputplumber.service hhd@"$(id -un 2>/dev/null)".service powerstation.service systemd-sysext.service steamos-manager.service; do
	st="$("$GC_SYSTEMCTL" is-active "$unit" 2>/dev/null)"
	info "service.$unit" "${st:-unknown}"
done
st="$("$GC_SYSTEMCTL" --user is-active steamos-manager.service 2>/dev/null)"
info service.user-steamos-manager "${st:-unknown}"
if [ "$os" = steamos ] && have steamos-readonly; then
	info steamos-readonly "$(steamos-readonly status 2>/dev/null | head -n 1)"
fi
if have flatpak && flatpak info com.google.Chrome >/dev/null 2>&1; then
	pass chrome "Chrome Flatpak installed"
elif have google-chrome; then
	pass chrome "Chrome installed"
else
	warn chrome "Chrome not found (needed for the browser console)"
fi
id -nG 2>/dev/null | grep -qw wheel && pass wheel "user is in wheel (InputPlumber profile loads need it)" ||
	warn wheel "user isn't in wheel: InputPlumber profile changes will be refused"
