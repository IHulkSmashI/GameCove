#!/bin/sh
# gamecove-run never changes a Proton or Steam install (review S2-2): the XMX shim goes into the game's own
# prefix (stock copy kept and put back), and .stock copies older builds left in a Proton are restored.
# shellcheck disable=SC2016,SC2034,SC2120 # check() evals its quoted test later; run takes optional extra env
#   sh packaging/tests/wrapper.sh
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
RUN="$HERE/../libexec/gamecove-run"
pass=0
fail=0
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
check() { if eval "$1"; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $2" >&2; fi; }

RT="$T/rt"
PKG="$RT/xess-xmx-linux-1/xess-xmx-linux-1"
PROTON="$T/steam/steamapps/common/Proton - Experimental"
BUNDLED="$PROTON/files/lib/wine/igdext/x86_64-windows/igdext64.dll"
PFX="$T/steam/steamapps/compatdata/42"
STORE="$PFX/pfx/drive_c/windows/system32/DriverStore/FileRepository/igd_faux.inf_1"
mkdir -p "$PKG/kernels" "$(dirname "$BUNDLED")" "$STORE" "$RT/launch"
printf 'shim IGDEXT_XELL\n' >"$PKG/igdext64.dll"
printf 'intel stock\n' >"$BUNDLED"
printf 'intel stock prefix\n' >"$STORE/igdext64.dll"
printf 'ANV_CM_KERNEL_DIR=%s/kernels\n' "$PKG" >"$RT/xmx.env"
: >"$RT/xmx-every-game"

run() {
	env -i HOME="$T" PATH="/usr/bin:/bin" GAMECOVE_RUNTIME="$RT" SteamAppId=42 STEAM_COMPAT_DATA_PATH="$PFX" \
		STEAM_COMPAT_TOOL_PATHS="$PROTON:/x" "$@" \
		bash "$RUN" sh -c 'printf "%s\n" "${INTC_ALT_DRIVER_EXTENSIONS_PATH:-none}" >"$0"' "$T/alt" >/dev/null 2>&1
}
proton_sum() { cksum <"$BUNDLED"; }

before=$(proton_sum)
run
check '[ "$(proton_sum)" = "$before" ]' "the Proton's own igdext64.dll is never changed"
check '[ ! -e "$BUNDLED.stock" ]' "no .stock copy made in the Proton"
check 'cmp -s "$STORE/igdext64.dll" "$PKG/igdext64.dll"' "the shim is in this game's prefix"
check 'grep -q "intel stock prefix" "$STORE/igdext64.dll.gamecove-stock"' "the prefix's stock copy is kept"
check 'grep -qF "C:\\windows\\system32\\driverstore\\filerepository\\igd_faux.inf_1" "$T/alt"' "INTC_ALT_DRIVER_EXTENSIONS_PATH points at the prefix's copy"
run
check 'grep -q "intel stock prefix" "$STORE/igdext64.dll.gamecove-stock"' "a second launch keeps the real stock copy"

# XMX no longer wanted for this game: its prefix gets its own file back
rm "$RT/xmx-every-game"
run
check 'grep -q "intel stock prefix" "$STORE/igdext64.dll" && [ ! -e "$STORE/igdext64.dll.gamecove-stock" ]' "prefix put back when XMX isn't used"

# an older build's change to the Proton itself: undone
: >"$RT/xmx-every-game"
cp "$BUNDLED" "$BUNDLED.stock"
cp "$PKG/igdext64.dll" "$BUNDLED"
run
check 'grep -q "intel stock" "$BUNDLED" && [ ! -e "$BUNDLED.stock" ]' "the Proton's original comes back from .stock"
# a .stock next to a file that isn't a shim (Proton updated it): left alone
printf 'newer intel\n' >"$BUNDLED"
printf 'old\n' >"$BUNDLED.stock"
run
check 'grep -q "newer intel" "$BUNDLED"' "a newer Proton file is never replaced by an old .stock"

# no prefix yet (first launch): the package's folder through Z:
rm -rf "$PFX"
run
check 'grep -q "^Z:" "$T/alt"' "no prefix yet: the package's folder through Z:"

echo "wrapper: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
