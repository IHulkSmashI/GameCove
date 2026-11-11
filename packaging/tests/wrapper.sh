#!/bin/sh
# gamecove-run places the XMX shim exactly as ClawDeck's launch wrapper does (ClawDeck tools/clawdeck-launch.sh at
# 4cf5cf9): the prefix's copy when it already is the shim, else the package folder through Z:, and the Proton the
# game runs on gets the shim as its bundled igdext64.dll (original kept as .stock), because GE-Proton, Proton
# Experimental and proton-cachyos copy their own over the prefix at every launch (black screen with FSR 4.1.2).
# Also: the second stage after Decky Framegen's fgmod (FSR 4 XMX files in, and out again), and prefixes an older
# GameCove changed are put back.
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

log() { cat "$RT/launch/42.log" 2>/dev/null; }

# 1. A Proton that bundles Intel's stock igdext64.dll (GE-Proton, Experimental), prefix with the stock copy:
#    the Proton gets the shim, its original is kept as .stock, and the path goes through Z: to the package
printf 'stamp\n' >"$PKG/run-stamp-src"
mkdir -p "$PKG/run" && : >"$PKG/run/shim-stamp" && touch -d '2026-01-02 03:04:05' "$PKG/run/shim-stamp"
run
check 'cmp -s "$BUNDLED" "$PKG/igdext64.dll"' "the Proton this game runs on gets the shim as its bundled igdext64.dll"
check 'grep -q "^intel stock$" "$BUNDLED.stock"' "the Proton's original is kept as .stock"
check '[ "$(stat -c %Y "$BUNDLED")" = "$(stat -c %Y "$PKG/run/shim-stamp")" ]' "the copy is stamped like install.sh's (its watcher leaves it alone)"
check 'grep -q "^Z:" "$T/alt" && grep -qF "xess-xmx-linux-1" "$T/alt"' "INTC_ALT_DRIVER_EXTENSIONS_PATH is the package folder through Z:"
check 'grep -q "intel stock prefix" "$STORE/igdext64.dll"' "the prefix's own copy is not rewritten by the wrapper"
check '[ ! -e "$STORE/igdext64.dll.gamecove-stock" ] && [ ! -e "$STORE/igdext64.dll.gamecove-added" ]' "no marker files in the prefix"
check 'log | grep -q "XMX shim put into this Proton"' "the launch log says the Proton got the shim"
# 2. the next launch: nothing to do, the .stock stays the real original
run
check 'grep -q "^intel stock$" "$BUNDLED.stock"' "a second launch keeps the real original in .stock"
check 'log | grep -q "already the XMX shim"' "a second launch finds the shim already there"
# 3. a Proton update put a new stock file there: shim again, .stock refreshed to the new original
printf 'intel stock v2\n' >"$BUNDLED"
run
check 'cmp -s "$BUNDLED" "$PKG/igdext64.dll" && grep -q "^intel stock v2$" "$BUNDLED.stock"' "a Proton update: shim again, .stock is the new original"
# 4. the prefix already holds the shim (Proton 11.0's proven path): the session file's path stays
cp "$PKG/igdext64.dll" "$STORE/igdext64.dll"
run
check 'grep -qx none "$T/alt"' "prefix has the shim: INTC_ALT_DRIVER_EXTENSIONS_PATH is left to the session file"
check 'log | grep -q "this prefix has it"' "the log says the prefix has it"
printf 'intel stock prefix\n' >"$STORE/igdext64.dll"
# 5. a Proton only root can write: said in the log, the game still starts
if [ "$(id -u)" != 0 ]; then
	printf 'intel stock ro\n' >"$BUNDLED"
	chmod 0444 "$BUNDLED" && chmod 0555 "$(dirname "$BUNDLED")"
	run
	check 'grep -q "intel stock ro" "$BUNDLED"' "a read-only Proton is left alone"
	chmod 0755 "$(dirname "$BUNDLED")" && chmod 0644 "$BUNDLED"
fi
# 6. XMX not wanted for this game: nothing is touched
rm "$RT/xmx-every-game"
printf 'intel stock v3\n' >"$BUNDLED"
rm -f "$BUNDLED.stock"
run
check 'grep -q "intel stock v3" "$BUNDLED" && [ ! -e "$BUNDLED.stock" ]' "XMX not used: the Proton is not touched"
check 'grep -qx none "$T/alt"' "XMX not used: no shim path"
check 'log | grep -q "XMX driver not used: nothing in this game asks for it"' "the log says why XMX isn't used"
run GAMECOVE_XMX=0
check 'log | grep -q "XMX is off for this game"' "GAMECOVE_XMX=0: said in the log"
: >"$RT/xmx-every-game"
# 7. a prefix an older GameCove changed is put back (stock copy from its marker; ours removed where it had none)
cp "$PKG/igdext64.dll" "$STORE/igdext64.dll"
printf 'intel stock prefix\n' >"$STORE/igdext64.dll.gamecove-stock"
run
check 'grep -q "intel stock prefix" "$STORE/igdext64.dll" && [ ! -e "$STORE/igdext64.dll.gamecove-stock" ]' "an older build's prefix change is undone"
cp "$PKG/igdext64.dll" "$STORE/igdext64.dll"
: >"$STORE/igdext64.dll.gamecove-added"
run
check '[ ! -e "$STORE/igdext64.dll" ] && [ ! -e "$STORE/igdext64.dll.gamecove-added" ]' "an older build's added prefix copy is removed"
# 8. Proton 11.0: no bundled igdext, no driver store, new prefix: the package through Z:, nothing created
P11="$T/steam/steamapps/common/Proton 11.0"
mkdir -p "$P11/files/lib/wine/x86_64-windows"
rm -rf "$PFX"
env -i HOME="$T" PATH="/usr/bin:/bin" GAMECOVE_RUNTIME="$RT" SteamAppId=42 STEAM_COMPAT_DATA_PATH="$PFX" \
	STEAM_COMPAT_TOOL_PATHS="$P11:/x" bash "$RUN" sh -c 'printf "%s\n" "${INTC_ALT_DRIVER_EXTENSIONS_PATH:-none}" >"$0"' "$T/alt" >/dev/null 2>&1
check 'grep -q "^Z:" "$T/alt"' "no prefix yet: the package's folder through Z:"
check '[ ! -e "$P11/files/lib/wine/igdext" ] && [ ! -e "$PFX" ]' "a Proton without a bundled igdext64.dll gets nothing added"

# 9. Decky Framegen's fgmod in the command: GameCove's second stage puts FSR 4 XMX over fgmod's files, and takes
#    them out again once it is switched off
GAME="$T/game"
SRC="$T/fsr4-xmx"
mkdir -p "$GAME" "$SRC" "$T/fg" "$T/pkgbin" "$PROTON/files/lib/wine/x86_64-windows"
printf 'nitec\n' >"$SRC/amd_fidelityfx_upscaler_dx12.dll"
printf 'orig\n' >"$SRC/fsr-original.dll"
printf 'lzms\n' >"$T/pkgbin/cabinet.dll"
printf 'wine cab\n' >"$PROTON/files/lib/wine/x86_64-windows/cabinet.dll"
: >"$GAME/Game.exe"
cat >"$T/fg/fgmod" <<'FG'
#!/bin/sh
# stand-in for Decky Framegen's fgmod: puts its own FSR 4 next to the exe, then runs the rest
for a in "$@"; do case "$a" in *.exe) printf 'fgmod fsr4\n' >"$(dirname "$a")/amd_fidelityfx_upscaler_dx12.dll" ;; esac; done
exec "$@"
FG
chmod +x "$T/fg/fgmod"
fgrun() {
	env -i HOME="$T" PATH="/usr/bin:/bin" GAMECOVE_RUNTIME="$RT" SteamAppId=42 STEAM_COMPAT_DATA_PATH="$PFX" \
		STEAM_COMPAT_TOOL_PATHS="$PROTON:/x" GAMECOVE_CABINET="$T/pkgbin/cabinet.dll" "$@" \
		bash "$RUN" "$T/fg/fgmod" sh -c 'echo started >"$0.ran"' "$GAME/Game.exe" >/dev/null 2>&1
}
fgrun GAMECOVE_FSR4_XMX=fsr4_xmx
check '[ -f "$GAME/Game.exe.ran" ]' "fgmod chain: the game still starts"
check 'grep -q nitec "$GAME/amd_fidelityfx_upscaler_dx12.dll"' "second stage: nitec's upscaler goes over fgmod's FSR 4"
check 'grep -q orig "$GAME/fsr-original.dll" && grep -q lzms "$GAME/cabinet.dll" && grep -q "wine cab" "$GAME/cabinet_wine.dll"' "second stage: fsr-original, GameCove's cabinet.dll and Wine's as cabinet_wine.dll"
check 'cmp -s "$GAME/igdext64.dll" "$PKG/igdext64.dll"' "second stage: the shim next to the exe"
check '[ "$(sort "$GAME/.gamecove-fsr4xmx" | tr "\n" " ")" = "cabinet.dll cabinet_wine.dll fsr-original.dll igdext64.dll " ]' "second stage: what was added is listed"
fgrun
check 'grep -q "fgmod fsr4" "$GAME/amd_fidelityfx_upscaler_dx12.dll"' "FSR 4 XMX off: fgmod's own FSR 4 is back"
check '[ ! -e "$GAME/cabinet.dll" ] && [ ! -e "$GAME/cabinet_wine.dll" ] && [ ! -e "$GAME/fsr-original.dll" ] && [ ! -e "$GAME/igdext64.dll" ] && [ ! -e "$GAME/.gamecove-fsr4xmx" ]' "FSR 4 XMX off: every added file is removed"
check '[ -f "$GAME/Game.exe" ]' "the game's own files stay"
# a list naming a path is never followed out of the game's folder
printf '../keep\n/abs\n' >"$GAME/.gamecove-fsr4xmx"
: >"$T/keep"
fgrun
check '[ -f "$T/keep" ]' "the removal list can't reach outside the game's folder"
# without the cabinet.dll: fgmod's FSR 4 stays, and the log says what is missing
# (a copy of the wrapper outside the checkout, so a cabinet.dll built in tools/cabinet-lzms/out isn't found)
mkdir -p "$T/usr/libexec/gamecove" && cp "$RUN" "$T/usr/libexec/gamecove/gamecove-run"
RUN="$T/usr/libexec/gamecove/gamecove-run"
fgrun GAMECOVE_FSR4_XMX=fsr4_xmx GAMECOVE_CABINET="$T/absent.dll"
check 'grep -q "fgmod fsr4" "$GAME/amd_fidelityfx_upscaler_dx12.dll" && log | grep -q "FSR 4 XMX: needs"' "no cabinet.dll: fgmod's FSR 4 stays, the log says so"

mkdir -p "$T/usr/lib/gamecove/bin" && printf 'packaged lzms\n' >"$T/usr/lib/gamecove/bin/cabinet.dll"
env -i HOME="$T" PATH="/usr/bin:/bin" GAMECOVE_RUNTIME="$RT" SteamAppId=42 STEAM_COMPAT_DATA_PATH="$PFX" \
	STEAM_COMPAT_TOOL_PATHS="$PROTON:/x" GAMECOVE_FSR4_XMX=fsr4_xmx \
	bash "$RUN" "$T/fg/fgmod" sh -c ':' "$GAME/Game.exe" >/dev/null 2>&1
check 'grep -q "packaged lzms" "$GAME/cabinet.dll"' "the second stage finds the packaged cabinet.dll (lib/gamecove/bin next to libexec/gamecove)"

echo "wrapper: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
