#!/bin/sh
# Release, supply-chain, licence and privacy checks (pre-release review H7, H8, M5, M6, M21-M28 and the lows that go
# with them). Static checks of the repo and the workflows; nothing is downloaded and nothing outside a temp folder is
# written. usage: sh packaging/tests/release.sh
set -u
REPO=$(cd "$(dirname "$0")/../.." && pwd)
PASS=0
FAILS=0
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

ok() { PASS=$((PASS + 1)); }
bad() {
	FAILS=$((FAILS + 1))
	printf 'FAIL: %s\n' "$*" >&2
}

# ------------------------------------------------------------- repo hygiene (M28)
# Only these files may sit in the repo root; anything else is a stray download or a leftover.
for f in $(git -C "$REPO" ls-files | grep -v /); do
	case "$f" in
	.gitignore | CONTRIBUTING.md | CREDITS.md | LICENSE | README.md | TRADEMARKS.md) ok ;;
	*) bad "unexpected file in the repo root: $f" ;;
	esac
done
# A path part starting with "-" is a test or command writing to its own arguments (app/-C/-xzf/ was one)
git -C "$REPO" ls-files | grep -E '(^|/)-' >"$T/dash"
if [ -s "$T/dash" ]; then bad "tracked paths with a part starting with '-': $(tr '\n' ' ' <"$T/dash")"; else ok; fi
# A document whose content isn't what its name says (guide.pdf was a saved captcha page)
git -C "$REPO" ls-files '*.pdf' '*.zip' '*.7z' '*.exe' '*.dll' '*.so' | grep -v '^app/tests/fixtures/' >"$T/bin"
if [ -s "$T/bin" ]; then bad "binary or document files tracked: $(tr '\n' ' ' <"$T/bin")"; else ok; fi

# ------------------------------------------------------------- licence texts in every artefact (H8)
LIST="$REPO/packaging/licenses.list"
grep -v '^#' "$LIST" | grep . >"$T/list"
while read -r src dest; do
	if [ -s "$REPO/$src" ]; then ok; else bad "licenses.list names a missing file: $src"; fi
	printf '%s\n' "$dest" >>"$T/dests"
done <"$T/list"
for need in LICENSE CREDITS.md GPL-2.0-only.txt OFL-Outfit.txt OFL-PlusJakartaSans.txt OFL-JetBrainsMono.txt \
	LICENSE.kenyoni-qr_code-MIT.md Godot-LICENSE.txt Godot-COPYRIGHT.txt LICENSE.ClawLab-MIT; do
	if grep -qx "$need" "$T/dests"; then ok; else bad "licenses.list lacks $need"; fi
done
grep -q "4.7.2-stable" "$REPO/LICENSES/README.md" && ok || bad "LICENSES/README.md must say which Godot tag the notices come from"
# tarball
mkdir -p "$T/app"
echo bin >"$T/app/gamecove.x86_64"
echo pck >"$T/app/gamecove.pck"
if sh "$REPO/packaging/make-app-tarball.sh" "$T/app" "$T/app.tar.gz" >"$T/out" 2>&1; then ok; else bad "make-app-tarball: $(cat "$T/out")"; fi
tar -tzf "$T/app.tar.gz" >"$T/tar" 2>/dev/null
for f in gamecove.x86_64 gamecove.pck; do grep -qx "$f" "$T/tar" && ok || bad "tarball lacks $f"; done
while read -r d; do grep -qx "licenses/$d" "$T/tar" && ok || bad "tarball lacks licenses/$d"; done <"$T/dests"
grep -q "sh packaging/make-app-tarball.sh app/build" "$REPO/.github/workflows/release.yml" && ok || bad "release.yml must build the tarball with make-app-tarball.sh"
# sysext tree
mkdir -p "$T/ss/usr/bin" "$T/ss/usr/share/gamescope-session-plus" "$T/ss/usr/lib/systemd/user"
printf '#!/bin/sh\n' >"$T/ss/usr/bin/gamescope-session-plus"
# the files build-sysext.sh's allow-list copies (review H10)
printf '#!/bin/bash\n' >"$T/ss/usr/share/gamescope-session-plus/gamescope-session-plus"
echo quirks >"$T/ss/usr/share/gamescope-session-plus/device-quirks"
printf '[Unit]\n' >"$T/ss/usr/lib/systemd/user/gamescope-session-plus@.service"
echo MIT >"$T/ss/LICENSE"
# a fake session tree: its own checksum list (build-sysext.sh checks every file against one, review M6)
(cd "$T/ss" && sha256sum usr/bin/gamescope-session-plus usr/share/gamescope-session-plus/gamescope-session-plus \
	usr/share/gamescope-session-plus/device-quirks usr/lib/systemd/user/gamescope-session-plus@.service LICENSE) >"$T/ss.sums"
if SESSION_SUMS="$T/ss.sums" sh "$REPO/packaging/sysext/build-sysext.sh" --app "$T/app" --session-src "$T/ss" --out "$T/sx" --tree-only >"$T/out" 2>&1; then ok; else bad "sysext tree: $(cat "$T/out")"; fi
while read -r d; do [ -s "$T/sx/gamecove/usr/share/licenses/gamecove/$d" ] && ok || bad "sysext lacks /usr/share/licenses/gamecove/$d"; done <"$T/dests"
# ------------------------------------------------------------- the LZMS cabinet.dll (FSR 4 on XMX) in every artefact
CAB="$REPO/tools/cabinet-lzms"
grep -Eqx '[0-9a-f]{64}  cabinet\.dll' "$CAB/cabinet.sha256" && ok || bad "tools/cabinet-lzms/cabinet.sha256 must hold the reviewed build's sha256"
for f in cabinet.c cabinet.def build.sh LICENSE wimlib/lzms_decompress.c wimlib/COPYING wimlib/COPYING.LGPL test/run.sh; do
	[ -s "$CAB/$f" ] && ok || bad "tools/cabinet-lzms/$f missing"
done
for need in LICENSE.cabinet-lzms-LGPL wimlib-COPYING wimlib-COPYING.LGPL; do
	grep -qx "$need" "$T/dests" && ok || bad "licenses.list lacks $need"
done
# a release tarball must have the reviewed DLL: none, or other bytes, fails
if REQUIRE_CABINET=1 sh "$REPO/packaging/make-app-tarball.sh" "$T/app" "$T/nocab.tar.gz" >"$T/out" 2>&1; then bad "REQUIRE_CABINET=1 must fail without bin/cabinet.dll"; else ok; fi
mkdir -p "$T/app/bin"
echo "not the reviewed dll" >"$T/app/bin/cabinet.dll"
if REQUIRE_CABINET=1 sh "$REPO/packaging/make-app-tarball.sh" "$T/app" "$T/badcab.tar.gz" >"$T/out" 2>&1; then bad "REQUIRE_CABINET=1 must refuse a cabinet.dll that isn't the reviewed build"; else ok; fi
# the real build when it is here (tools/cabinet-lzms/build.sh ran): accepted
if [ -s "$CAB/out/cabinet.dll" ] && (cd "$CAB/out" && sha256sum -c ../cabinet.sha256 >/dev/null 2>&1); then
	cp "$CAB/out/cabinet.dll" "$T/app/bin/cabinet.dll"
	if REQUIRE_CABINET=1 sh "$REPO/packaging/make-app-tarball.sh" "$T/app" "$T/cab.tar.gz" >"$T/out" 2>&1; then ok; else bad "the reviewed cabinet.dll is refused: $(cat "$T/out")"; fi
else
	sh "$REPO/packaging/make-app-tarball.sh" "$T/app" "$T/cab.tar.gz" >"$T/out" 2>&1 || bad "make-app-tarball with bin/: $(cat "$T/out")"
fi
tar -tzf "$T/cab.tar.gz" >"$T/cabtar" 2>/dev/null
for f in bin/cabinet.dll bin/cabinet-lzms-source.tar.gz; do grep -qx "$f" "$T/cabtar" && ok || bad "tarball lacks $f"; done
mkdir -p "$T/cabx" && tar -xzf "$T/cab.tar.gz" -C "$T/cabx" 2>/dev/null
tar -tzf "$T/cabx/bin/cabinet-lzms-source.tar.gz" >"$T/cabsrc" 2>/dev/null
for f in cabinet-lzms/cabinet.c cabinet-lzms/wimlib/lzms_decompress.c cabinet-lzms/LICENSE cabinet-lzms/wimlib/COPYING.LGPL; do
	grep -qx "$f" "$T/cabsrc" && ok || bad "the cabinet source archive lacks $f"
done
grep -q '^cabinet-lzms/out/' "$T/cabsrc" && bad "the cabinet source archive carries build output" || ok
# nitec's FSR 4.1.2 XMX files: a release tarball must carry the pinned set, and nothing else is accepted
if REQUIRE_FSR4=1 sh "$REPO/packaging/make-app-tarball.sh" "$T/app" "$T/nofsr.tar.gz" >"$T/out" 2>&1; then bad "REQUIRE_FSR4=1 must fail without bin/fsr4-xmx"; else ok; fi
mkdir -p "$T/app/bin/fsr4-xmx"
echo "not nitec's" >"$T/app/bin/fsr4-xmx/amd_fidelityfx_upscaler_dx12.dll"
echo "not nitec's" >"$T/app/bin/fsr4-xmx/fsr-original.dll"
echo '{}' >"$T/app/bin/fsr4-xmx/set.json"
if sh "$REPO/packaging/make-app-tarball.sh" "$T/app" "$T/badfsr.tar.gz" >"$T/out" 2>&1; then bad "a bin/fsr4-xmx that isn't the pinned set must be refused"; else ok; fi
rm -rf "$T/app/bin/fsr4-xmx"
# one install: the redistributable upscaler files ride in every artefact (tools/upscalers/fetch_bundle.py)
if REQUIRE_UPSCALERS=1 sh "$REPO/packaging/make-app-tarball.sh" "$T/app" "$T/noup.tar.gz" >"$T/out" 2>&1; then bad "REQUIRE_UPSCALERS=1 must fail without bin/upscalers"; else ok; fi
mkdir -p "$T/app/bin/upscalers"
echo "not OptiScaler" >"$T/app/bin/upscalers/0000000000000000000000000000000000000000000000000000000000000000"
echo '{"schema": 1, "files": {}}' >"$T/app/bin/upscalers/bundle.json"
if sh "$REPO/packaging/make-app-tarball.sh" "$T/app" "$T/badup.tar.gz" >"$T/out" 2>&1; then bad "a bin/upscalers that isn't the pinned set must be refused"; else ok; fi
rm -rf "$T/app/bin/upscalers"
python3 -I "$REPO/tools/upscalers/fetch_bundle.py" --check "$T/nowhere" >/dev/null 2>&1 && bad "fetch_bundle --check passes on a missing folder" || ok
grep -q 'python3 -I tools/upscalers/fetch_bundle.py app/build/bin/upscalers --fsr4 app/build/bin/fsr4-xmx' "$REPO/.github/workflows/release.yml" && ok || bad "release.yml must fetch the pinned upscaler files into the app"
grep -q 'bin/upscalers/bundle.json' "$REPO/.github/workflows/release.yml" && ok || bad "release.yml must check the tarball has the upscaler bundle"
grep -q 'app-export/bin/upscalers/\* %{buildroot}%{_prefix}/lib/gamecove/bin/upscalers/' "$REPO/packaging/rpm/gamecove.spec" && ok || bad "spec must install bin/upscalers"
grep -q '"/usr/lib/gamecove/bin/upscalers")$' "$REPO/packaging/helpers/gamecove_upscale/downloads.py" && ok || bad "downloads.BUNDLE_DIRS moved: packages install the bundle to /usr/lib/gamecove/bin/upscalers"
grep -q '^LICENSES/AMD-FidelityFX-SDK-license.md ' "$REPO/packaging/licenses.list" && ok || bad "AMD's FSR SDK notice must ship next to its DLL (licenses.list)"
# never in the bundle or the repo: NVIDIA's files, AMD's driver DLLs, Lossless Scaling's DLL, lsfg-vk (CC BY-NC-ND: from its author only)
if python3 -I - "$REPO" >"$T/out" 2>&1 <<'PY'
import sys
sys.path.insert(0, sys.argv[1] + "/packaging/helpers"); sys.path.insert(0, sys.argv[1] + "/tools/upscalers")
import fetch_bundle
names = " ".join((i["name"] + " " + " ".join(i["urls"])).lower() for i in fetch_bundle.items(fetch_bundle.load_pins()))
bad = [w for w in ("nvngx", "amdxcffx", "amdxc64", "lossless", "lsfg") if w in names]
assert not bad, bad
PY
then ok; else bad "the upscaler bundle names a file we must never ship: $(cat "$T/out")"; fi
python3 -I "$REPO/tools/upscalers/fetch_fsr4.py" --check "$T/nowhere" >/dev/null 2>&1 && bad "fetch_fsr4 --check passes on a missing folder" || ok
# the unpacked tarball as the sysext and the RPM see it (stand-in bytes: the real check is the one above)
mkdir -p "$T/cabx/bin/fsr4-xmx"
for f in amd_fidelityfx_upscaler_dx12.dll fsr-original.dll set.json; do echo "$f" >"$T/cabx/bin/fsr4-xmx/$f"; done
mkdir -p "$T/cabx/bin/upscalers"
for f in bundle.json 1111111111111111111111111111111111111111111111111111111111111111; do echo "$f" >"$T/cabx/bin/upscalers/$f"; done
# sysext: from the unpacked tarball to /usr/lib/gamecove/bin (the path optiscaler.SYSTEM_CABINET checks)
if SESSION_SUMS="$T/ss.sums" sh "$REPO/packaging/sysext/build-sysext.sh" --app "$T/cabx" --session-src "$T/ss" --out "$T/sxc" --tree-only >"$T/out" 2>&1; then ok; else bad "sysext tree with cabinet: $(cat "$T/out")"; fi
cmp -s "$T/cabx/bin/cabinet.dll" "$T/sxc/gamecove/usr/lib/gamecove/bin/cabinet.dll" && ok || bad "sysext lacks /usr/lib/gamecove/bin/cabinet.dll"
[ -s "$T/sxc/gamecove/usr/lib/gamecove/bin/cabinet-lzms-source.tar.gz" ] && ok || bad "sysext lacks the cabinet source archive"
for f in amd_fidelityfx_upscaler_dx12.dll fsr-original.dll set.json; do
	cmp -s "$T/cabx/bin/fsr4-xmx/$f" "$T/sxc/gamecove/usr/lib/gamecove/bin/fsr4-xmx/$f" && ok || bad "sysext lacks /usr/lib/gamecove/bin/fsr4-xmx/$f"
done
for f in bundle.json 1111111111111111111111111111111111111111111111111111111111111111; do
	cmp -s "$T/cabx/bin/upscalers/$f" "$T/sxc/gamecove/usr/lib/gamecove/bin/upscalers/$f" && ok || bad "sysext lacks /usr/lib/gamecove/bin/upscalers/$f"
done
grep -q "no bin/upscalers" "$T/out" && bad "sysext warned about upscaler files that are there" || ok
grep -q "no bin/fsr4-xmx" "$T/out" && bad "sysext warned about FSR 4 files that are there" || ok
grep -q '^SYSTEM_DIR = "/usr/lib/gamecove"$' "$REPO/packaging/helpers/gamecove_upscale/optiscaler.py" && ok || bad "optiscaler.SYSTEM_DIR moved: packages install the FSR 4 set to /usr/lib/gamecove/bin/fsr4-xmx"
grep -q 'app-export/bin/fsr4-xmx/\* %{buildroot}%{_prefix}/lib/gamecove/bin/fsr4-xmx/' "$REPO/packaging/rpm/gamecove.spec" && ok || bad "spec must install bin/fsr4-xmx"
RELY="$REPO/.github/workflows/release.yml"
grep -q 'python3 -I tools/upscalers/fetch_fsr4.py app/build/bin/fsr4-xmx' "$RELY" && ok || bad "release.yml must fetch the pinned FSR 4.1.2 XMX files into the app"
grep -q 'REQUIRE_FSR4=1' "$RELY" && ok || bad "release.yml must require the FSR 4.1.2 XMX files in the tarball"
grep -q 'fetch_fsr4.py --check app-export/bin/fsr4-xmx' "$RELY" && ok || bad "release.yml must check the shipped FSR 4.1.2 XMX files against the pins"
grep -q '"/usr/lib/gamecove/bin/fsr4-xmx/$f" rpm-files.txt' "$RELY" && ok || bad "release.yml must check the RPM has the FSR 4.1.2 XMX files"
grep -Eq '"base": "https://raw.githubusercontent.com/IHulkSmashI/ClawDeck/[0-9a-f]{40}"' "$REPO/packaging/helpers/gamecove_upscale/data/versions.json" && ok || bad "versions.json fsr4_xmx must pin ClawDeck's fsr4-xmx-files branch by commit"
grep -q 'nitec and the OptiScaler community' "$REPO/CREDITS.md" && ok || bad "CREDITS.md must credit nitec and the OptiScaler community for FSR 4 on XMX"
grep -q "no bin/cabinet.dll" "$T/out" && bad "sysext warned about a cabinet.dll that is there" || ok
grep -q '^SYSTEM_CABINET = "/usr/lib/gamecove/bin/cabinet.dll"$' "$REPO/packaging/helpers/gamecove_upscale/optiscaler.py" && ok || bad "optiscaler.SYSTEM_CABINET moved: packages install to /usr/lib/gamecove/bin/cabinet.dll"
# RPM and workflows
SPEC0="$REPO/packaging/rpm/gamecove.spec"
grep -q 'app-export/bin/cabinet.dll %{buildroot}%{_prefix}/lib/gamecove/bin/cabinet.dll' "$SPEC0" && ok || bad "spec must install bin/cabinet.dll"
grep -qx '%{_prefix}/lib/gamecove/bin' "$SPEC0" && ok || bad "spec %files must take /usr/lib/gamecove/bin"
grep -q 'LGPL-2.1-or-later' "$SPEC0" && ok || bad "spec License must name LGPL-2.1-or-later (cabinet.dll)"
REL="$REPO/.github/workflows/release.yml"
grep -q 'bash tools/cabinet-lzms/build.sh --check' "$REL" && ok || bad "release.yml must build cabinet.dll and compare it with cabinet.sha256"
grep -q 'bash tools/cabinet-lzms/test/run.sh' "$REL" && ok || bad "release.yml must test cabinet.dll under Wine"
grep -q '"gcc-mingw-w64-x86-64=${MINGW_GCC}"' "$REL" && grep -Eq '^  MINGW_GCC: [0-9]' "$REL" && ok || bad "release.yml must pin the mingw-w64 toolchain by version"
grep -q 'REQUIRE_CABINET=1 REQUIRE_FSR4=1 REQUIRE_UPSCALERS=1 sh packaging/make-app-tarball.sh' "$REL" && ok || bad "release.yml must require the reviewed cabinet.dll in the tarball"
grep -q 'grep -qx /usr/lib/gamecove/bin/cabinet.dll rpm-files.txt' "$REL" && ok || bad "release.yml must check the RPM has cabinet.dll"
grep -q 'cp app-export/bin/cabinet.dll dist/cabinet.dll' "$REL" && grep -q 'dist/cabinet.dll$' "$REL" && ok || bad "release.yml must publish cabinet.dll so SHA256SUMS and its signature cover it"
grep -q 'bash tools/cabinet-lzms/test/run.sh' "$REPO/.github/workflows/ci.yml" && ok || bad "ci.yml must build and test cabinet.dll on every push"
rm -rf "$T/app/bin"

# RPM: run the spec's %prep licence loop against the repo and check %files takes the result
SPEC="$REPO/packaging/rpm/gamecove.spec"
awk '/^# licence and notice texts/{f=1;next} f&&/^done < packaging\/licenses.list/{print;exit} f' "$SPEC" >"$T/prep.sh"
if (cd "$REPO" && mkdir -p "$T/rpm" && cd "$T/rpm" && ln -s "$REPO/packaging" packaging && for s in LICENSE CREDITS.md LICENSES fixes app tools; do ln -s "$REPO/$s" "$s"; done && sh "$T/prep.sh") >"$T/out" 2>&1; then ok; else bad "spec %prep licence loop: $(cat "$T/out")"; fi
while read -r d; do [ -s "$T/rpm/licenses/$d" ] && ok || bad "RPM %prep doesn't stage licenses/$d"; done <"$T/dests"
grep -qx '%license licenses/\*' "$SPEC" && ok || bad "spec %files must take %license licenses/*"
grep -q "missing from the RPM" "$REPO/.github/workflows/release.yml" && ok || bad "release.yml must check the built RPM's licence files"
grep -q "missing from the sysext" "$REPO/.github/workflows/release.yml" && ok || bad "release.yml must check the built sysext's licence files"
grep -q "missing from gamecove.pck" "$REPO/.github/workflows/release.yml" && ok || bad "release.yml must check the pck's licence files"
# export include_filter and the in-app copy
inc=$(sed -n 's/^include_filter="\(.*\)"$/\1/p' "$REPO/app/export_presets.cfg")
for pat in CREDITS.md 'fonts/OFL-*.txt' addons/kenyoni/qr_code/LICENSE.md 'assets/boot/*.ogv'; do
	case ", $inc," in *", $pat,"*) ok ;; *) bad "export include_filter lacks $pat ($inc)" ;; esac
done
if [ -L "$REPO/app/CREDITS.md" ] && cmp -s "$REPO/app/CREDITS.md" "$REPO/CREDITS.md"; then ok; else bad "app/CREDITS.md must link to the repo's CREDITS.md"; fi

# ------------------------------------------------------------- release workflow supply chain (M5, M6, L26-L28)
W="$REPO/.github/workflows/release.yml"
# The export stamps the spec's Version into project.godot (else About says "Development build"):
# run the workflow's own line on a copy and check Godot's setting lands under [application].
stamp=$(grep -o "sed -i \"/^config.*app/project.godot" "$W" | head -n 1)
cp "$REPO/app/project.godot" "$T/project.godot"
if [ -n "$stamp" ] && VERSION=0.1.0 sh -c "$(printf '%s' "$stamp" | sed "s#app/project.godot#$T/project.godot#")" &&
	awk '/^\[/{s=$0} /^config\/version=/{print s; print}' "$T/project.godot" | tr '\n' ' ' | grep -qx '\[application\] config/version="0.1.0" '; then ok; else bad "release.yml must stamp the spec's Version into app/project.godot before exporting"; fi
ex=$(grep -n -- "--export-release" "$W" | head -n 1 | cut -d: -f1)
st=$(grep -n "config/version" "$W" | head -n 1 | cut -d: -f1)
[ -n "$st" ] && [ -n "$ex" ] && [ "$st" -lt "$ex" ] && ok || bad "the version stamp must come before the export"
GG="$REPO/packaging/get-gamecove.sh"
# M5: the identity ends with this tag, identical in the installer and the workflow's self-check
for f in "$GG" "$W"; do
	id=$(sed -n 's/^[[:space:]]*ident="\(.*\)"$/\1/p' "$f")
	case "$id" in *'@refs/tags/$(printf '"'"'%s'"'"' "$tag" |'*'\$') ok ;; *) bad "$f: identity must end with the escaped tag and \$ ($id)" ;; esac
	# evaluate it for a tag and check what it accepts
	REPO_=IHulkSmashI/GameCove
	got=$(REPO=$REPO_ tag=v0.2.0-rc.1 sh -c "printf '%s' \"$id\"" 2>/dev/null)
	python3 -I - "$got" >"$T/out" 2>&1 <<'PY' && ok || bad "$f identity regex: $(cat "$T/out")"
import re, sys
r = re.compile(sys.argv[1])
base = "https://github.com/IHulkSmashI/GameCove/.github/workflows/release.yml@refs/tags/"
assert r.search(base + "v0.2.0-rc.1"), "the requested tag must match"
assert r.search(base.lower() + "v0.2.0-rc.1"), "any case"
for other in ("v0.1.0", "v0.2.0-rc.10", "v0.2.0-rcX1", "v0.2.0-rc.1-evil"):
    assert not r.search(base + other), "must not match " + other
PY
done
# M6: actions pinned by commit with the tag in a comment, container by digest, downloads by sha256
for f in "$REPO"/.github/workflows/*.yml; do
	grep -nE '^[[:space:]]*(- )?uses:' "$f" | grep -v 'uses: [^ ]*@[0-9a-f]\{40\} # v[0-9]' >"$T/unpinned"
	if [ -s "$T/unpinned" ]; then bad "$f: actions not pinned by commit: $(tr '\n' ' ' <"$T/unpinned")"; else ok; fi
	if grep -n 'container:\|image:' "$f" | grep -v '@sha256:[0-9a-f]\{64\}' | grep -v '^[0-9]*:[[:space:]]*#' | grep -q .; then bad "$f: container not pinned by digest"; else ok; fi
done
for v in GODOT_EDITOR_SHA256 GODOT_TEMPLATES_SHA256 UHB_SHA256; do
	grep -q "^  $v: [0-9a-f]\{64\}$" "$W" && ok || bad "release.yml lacks the $v pin"
	grep -q "\${$v}  .*| sha256sum -c -" "$W" && ok || bad "release.yml doesn't check $v"
done
# M6: every pip install is hash-pinned; CI's Godot download is checked against release.yml's pin
for f in "$REPO"/.github/workflows/*.yml; do
	if grep -n 'pip install' "$f" | grep -v 'pip install --require-hashes --no-deps -r [./]*tools/ci/requirements-[a-z]*\.txt$' | grep -q .; then
		bad "$f: pip install without hashes: $(grep -n 'pip install' "$f" | tr '\n' ' ')"
	else ok; fi
done
for r in "$REPO"/tools/ci/requirements-*.txt; do
	if grep -v '^[[:space:]]*#' "$r" | grep -v '^[[:space:]]*$' | grep -v '^-r ' | grep -v '^[[:space:]]*--hash=sha256:[0-9a-f]\{64\}' |
		grep -v '^[A-Za-z0-9_.-]*==[0-9][^ ]* \(--hash=sha256:[0-9a-f]\{64\}\|\\\)$' | grep -q .; then
		bad "$r: every requirement needs ==version and --hash=sha256"
	else ok; fi
done
CI="$REPO/.github/workflows/ci.yml"
ci_pin=$(sed -n 's/^  GODOT_EDITOR_SHA256: \([0-9a-f]\{64\}\)$/\1/p' "$CI")
rel_pin=$(sed -n 's/^  GODOT_EDITOR_SHA256: \([0-9a-f]\{64\}\)$/\1/p' "$W")
[ -n "$ci_pin" ] && [ "$ci_pin" = "$rel_pin" ] && ok || bad "ci.yml must pin the same Godot editor sha256 as release.yml ($ci_pin vs $rel_pin)"
[ "$(grep -c 'godot.zip "https://' "$CI")" = "$(grep -c '${GODOT_EDITOR_SHA256}  godot.zip" | sha256sum -c -' "$CI")" ] && ok || bad "ci.yml must check every Godot download"
# L26: draft, upload, publish
awk '/gh release create/{c=NR} /gh release upload/{u=NR} /gh release edit "\$TAG" --draft=false/{p=NR} END{exit !(c && u && p && c<u && u<p)}' "$W" && ok || bad "release.yml must create a draft, upload, then publish"
grep -q 'gh release create "$TAG" --draft' "$W" && ok || bad "the release must start as a draft"
# L27: no ${{ }} expressions inside run: blocks
python3 -I - "$W" >"$T/out" 2>&1 <<'PY' && ok || bad "release.yml: \${{ }} inside run: ($(cat "$T/out"))"
import sys, yaml
doc = yaml.safe_load(open(sys.argv[1]))
bad = [s.get("name", "?") for j in doc["jobs"].values() for s in j.get("steps", []) if "${{" in s.get("run", "")]
assert not bad, bad
PY
# review problem 8: only main is tagged and released
python3 -I - "$W" >"$T/out" 2>&1 <<'PY' && ok || bad "release.yml main-only release: $(cat "$T/out")"
import sys, yaml
jobs = yaml.safe_load(open(sys.argv[1]))["jobs"]
assert "github.ref == 'refs/heads/main'" in jobs["tag"]["if"], "the tag job must require refs/heads/main: " + jobs["tag"]["if"]
assert "ref_type == 'branch'" not in jobs["tag"]["if"], "any branch may not tag"
runs = [s.get("run", "") for s in jobs["release"]["steps"]]
main = [i for i, r in enumerate(runs) if "compare/main...$GITHUB_SHA" in r]
sign = [i for i, r in enumerate(runs) if "cosign sign-blob" in r]
assert main and sign and main[0] < sign[0], "the release job must check the tag's commit is on main before signing"
ver = [s for s in jobs["app"]["steps"] if s.get("id") == "version"][0]
assert "PUBLISH" in ver.get("env", {}) and 'if [ "$PUBLISH" = true ]' in ver["run"], "publish=true off main must fail"
PY
# L28: CI signs and verifies with the cosign devices use
grep -q 'cosign-release: ${{ steps.cosign.outputs.version }}' "$W" && ok || bad "cosign-installer must install get-gamecove.sh's COSIGN_VERSION"
grep -q "COSIGN_SHA256=" "$W" && ok || bad "release.yml must check cosign against get-gamecove.sh's COSIGN_SHA256"

# ------------------------------------------------------------- firmware index signature (M21)
FW="$REPO/.github/workflows/firmware.yml"
grep -q "cosign sign-blob --yes --bundle dist/firmware.json.gz.sigstore.json dist/firmware.json.gz" "$FW" && ok || bad "firmware.yml must sign the index"
grep -q "dist/firmware.json.gz.sigstore.json --clobber" "$FW" && ok || bad "firmware.yml must publish the signature"
grep -q "id-token: write" "$FW" && ok || bad "firmware.yml needs id-token: write"
# review problem 2: build (scrapers, pip packages) can't sign or publish; publish runs only pinned cosign and gh
python3 -I - "$FW" >"$T/out" 2>&1 <<'PY' && ok || bad "firmware.yml jobs: $(cat "$T/out")"
import re, sys, yaml
doc = yaml.safe_load(open(sys.argv[1]))
assert doc.get("permissions") == {}, "nothing at the top level"
jobs = doc["jobs"]
assert set(jobs) == {"build", "publish"}, list(jobs)
b, p = jobs["build"], jobs["publish"]
assert b.get("permissions") == {"contents": "read"}, b.get("permissions")
assert b.get("if") == "github.ref == 'refs/heads/main'", "build for publishing only on main"
assert p.get("needs") == "build" and p.get("permissions") == {"contents": "write", "id-token": "write"}, p.get("permissions")
brun = "\n".join(s.get("run", "") for s in b["steps"])
prun = "\n".join(s.get("run", "") for s in p["steps"])
assert "cosign" not in brun and "gh release" not in brun, "build must not sign or publish"
assert "pip install" not in prun and "gamedb" not in prun, "publish must not run the scrapers or third-party packages"
assert "cosign sign-blob" in prun and "COSIGN_SHA256=" in prun
for j in (b, p):
    for s in j["steps"]:
        if s.get("uses", "").startswith("actions/checkout@"):
            assert s.get("with", {}).get("persist-credentials") is False, "checkout keeps no token"
        assert "${{" not in s.get("run", ""), "${{ }} inside run:"
PY
app_cos=$(sed -n 's/^const COSIGN_VERSION := "\(.*\)"$/\1/p' "$REPO/app/scripts/system/updates.gd")
gg_cos=$(sed -n 's/^COSIGN_VERSION=//p' "$REPO/packaging/get-gamecove.sh")
[ -n "$app_cos" ] && [ "$app_cos" = "$gg_cos" ] && ok || bad "updates.gd COSIGN_VERSION ($app_cos) must match get-gamecove.sh ($gg_cos)"
grep -q 'workflows/firmware\\\\.yml@refs/heads/main\$' "$REPO/app/scripts/system/firmware_index.gd" && ok || bad "firmware_index.gd SIGNER_IDENTITY must name firmware.yml on main"

# ------------------------------------------------------------- upscalers index and mirror (owner decision 2026-11-09)
UW="$REPO/.github/workflows/upscalers.yml"
MP="$REPO/packaging/helpers/gamecove_upscale/mirror.py"
python3 -I - "$UW" "$MP" "$GG" >"$T/out" 2>&1 <<'PY' && ok || bad "upscalers.yml / mirror.py: $(cat "$T/out")"
import re, subprocess, sys, yaml
wf, mp, gg = sys.argv[1:4]
doc = yaml.safe_load(open(wf))
on = doc.get("on", doc.get(True))
assert "schedule" in on and "workflow_dispatch" in on, "nightly and by hand (gh workflow run upscalers.yml)"
assert doc.get("permissions") == {}, "least privilege: nothing at the top level"
jobs = doc["jobs"]
# review problem 2 pattern: build (tests, builder, third-party downloads) read-only; publish signs and uploads
assert list(jobs) == ["build", "publish"], list(jobs)
b, p = jobs["build"], jobs["publish"]
assert b.get("permissions") == {"contents": "read"}, b.get("permissions")
assert b.get("if") == "github.ref == 'refs/heads/main'", "build for publishing only on main (the signing identity)"
assert p.get("needs") == "build" and p.get("permissions") == {"contents": "write", "id-token": "write"}, p.get("permissions")
brun = "\n".join(x.get("run", "") for x in b["steps"])
prun = "\n".join(x.get("run", "") for x in p["steps"])
assert "sign-blob" not in brun and "gh release upload" not in brun and "gh release create" not in brun, "build must not sign or publish"
assert "pip install" not in prun and "tools/upscalers/build.py" not in prun and "pytest" not in prun, "publish must not run the builder or third-party packages"
assert set(re.findall(r"tools/upscalers/[A-Za-z_./]+", prun)) <= {"tools/upscalers/check_plan.py"}, "publish runs only check_plan.py of ours"
assert any(x.get("uses", "").startswith("actions/upload-artifact@") for x in b["steps"])
assert any(x.get("uses", "").startswith("actions/download-artifact@") for x in p["steps"])
steps = b["steps"] + p["steps"]
bad = [s.get("name", s.get("uses", "?")) for s in steps if "${{" in s.get("run", "")]
assert not bad, "${{ }} inside run: " + str(bad)
for s in steps:
    if "uses" in s:
        assert re.match(r"^[^@ ]+@[0-9a-f]{40}$", s["uses"]), "unpinned: " + s["uses"]
    if s.get("uses", "").startswith("actions/checkout@"):
        assert s.get("with", {}).get("persist-credentials") is False, "checkout keeps no token"
runs = "\n".join(s.get("run", "") for s in steps)
assert "cosign sign-blob --yes --bundle dist/upscalers.json.sigstore.json dist/upscalers.json" in runs
assert runs.count("--clobber") == 1 and "dist/upscalers.json.sigstore.json dist/upscalers.json.sha256 --clobber" in runs, \
    "only the index is replaced; mirror files never"
assert runs.index('gh release upload "$tag" "dist/$path"') < runs.index("--clobber"), "files first, the index last"
assert "--latest=false" in runs, "the mirror release must never become 'latest' (get-gamecove.sh reads releases/latest)"
assert "cosign-release: ${{ steps.cosign.outputs.version }}" in open(wf).read()
# the workflow's own check, for this repository, is the identity the helper requires
ident = [l.strip()[len('ident="'):-1] for l in runs.splitlines() if l.strip().startswith('ident="')]
assert len(ident) == 2 and ident[0] == ident[1], ident
got = subprocess.run(["sh", "-c", 'printf "%s" "' + ident[0] + '"'], env={"REPO": "IHulkSmashI/GameCove", "PATH": "/usr/bin:/bin"},
                     capture_output=True, text=True, check=True).stdout
src = open(mp).read()
helper = re.search(r'^SIGNER_IDENTITY = r"(.*)"$', src, re.M).group(1)
assert got == helper, (got, helper)
r = re.compile(helper)
base = "https://github.com/IHulkSmashI/GameCove/.github/workflows/"
assert r.search(base + "upscalers.yml@refs/heads/main") and r.search(base.lower() + "upscalers.yml@refs/heads/main")
for other in ("firmware.yml@refs/heads/main", "upscalers.yml@refs/heads/dev", "upscalers.yml@refs/tags/v1.0.0",
              "upscalers.yml@refs/heads/main2"):
    assert not r.search(base + other), other
assert not r.search("https://github.com/fork/GameCove/.github/workflows/upscalers.yml@refs/heads/main")
# the helper checks signatures with the cosign the installer pins
ggs = open(gg).read()
for k in ("COSIGN_VERSION", "COSIGN_SHA256"):
    a = re.search(r"^%s=(\S+)$" % k, ggs, re.M).group(1)
    b = re.search(r'^%s = "(\S+)"$' % k, src, re.M).group(1)
    assert a == b, (k, a, b)
PY

# ------------------------------------------------------------- brand logos (M23)
python3 -I - "$REPO" >"$T/out" 2>&1 <<'PY' && ok || bad "brand logos: $(cat "$T/out")"
import json, os, sys
repo = sys.argv[1]
doc = json.load(open(os.path.join(repo, "app/data/brand_logos.json")))
bad, files = [], set()
for key, b in doc["brands"].items():
    for f in ("owner", "source", "license"):
        if not str(b.get(f, "")).strip():
            bad.append("%s has no %s" % (key, f))
    if b.get("file"):
        files.add(b["file"].replace("res://", "app/"))
for f in sorted(os.listdir(os.path.join(repo, "app/assets/brand"))):
    if f.endswith(".svg") and "app/assets/brand/" + f not in files:
        bad.append("app/assets/brand/%s has no entry in brand_logos.json" % f)
assert not bad, bad
PY
[ -s "$REPO/app/assets/brand/LICENSE.md" ] && grep -q "not\*\* licensed under GameCove's GPL" "$REPO/app/assets/brand/LICENSE.md" && ok || bad "app/assets/brand/LICENSE.md must say the logos aren't GPL"
grep -q "^app/assets/brand/LICENSE.md " "$REPO/packaging/licenses.list" && ok || bad "licenses.list must ship the brand licence note"
grep -q "Trademark use" "$REPO/docs/BRANDS.md" && grep -q "Logo removal requests" "$REPO/docs/BRANDS.md" && ok || bad "docs/BRANDS.md must document trademark use and removal"
grep -q "not GPL-licensed" "$REPO/README.md" && ok || bad "README must say the brand logos aren't GPL"
grep -q "LicenseRef-.*[Tt]rademark" "$REPO/packaging/rpm/gamecove.spec" && ok || bad "spec License must name the logos' trademark status"
# review problem 3: a bundled maker picture is named in CREDITS and the spec, and no notice says none are bundled
for f in "$REPO"/app/assets/device_photos/*.webp "$REPO"/app/assets/device_photos/*.png "$REPO"/app/assets/device_photos/*.jpg; do
	[ -f "$f" ] || continue
	rel="app/assets/device_photos/${f##*/}"
	grep -qF "$rel" "$REPO/CREDITS.md" && ok || bad "CREDITS.md must name the bundled picture $rel"
	grep -q "^License:.*LicenseRef-Maker-image" "$SPEC" && ok || bad "spec License must cover the bundled maker picture ($rel): LicenseRef-Maker-image"
done
if grep -n -i "never bundled\|not in this repository, the app package" "$REPO/README.md" "$REPO/CREDITS.md" "$REPO/docs/DEVICES.md" >"$T/out"; then bad "a notice still says maker photos are never bundled: $(cat "$T/out")"; else ok; fi

# ------------------------------------------------------------- network disclosure (M22, L34)
for host in cheapshark.com gg.deals GitHub GameStream "Wake-on-LAN" SteamGridDB "maker" "Affiliate links"; do
	grep -q "$host" "$REPO/README.md" && ok || bad "README's Network and privacy section doesn't mention $host"
	grep -qi "$host" "$REPO/docs/PRIVACY.md" && ok || bad "docs/PRIVACY.md doesn't mention $host"
done
grep -q "^## Network and privacy" "$REPO/README.md" && ok || bad "README needs a Network and privacy section"
# review problem 4: the Stream tab's subnet probe is described as what it is, not just "PCs on your LAN"
for f in "$REPO/README.md" "$REPO/docs/PRIVACY.md" "$REPO/app/scripts/system/privacy.gd"; do
	grep -qi "47989 on every address\|every address of your local IPv4 networks" "$f" && ok || bad "$f must describe the Stream tab's probe of every local address on port 47989"
done
for sw in "Background lookups" "Look up deals and prices" "Show maker photos"; do
	grep -q "$sw" "$REPO/README.md" && ok || bad "README must name the '$sw' switch"
done

# ------------------------------------------------------------- signing waits for the owner; scrapers can't write (review 2, problem 10)
python3 -I - "$REPO/.github/workflows" >"$T/out" 2>&1 <<'PY' && ok || bad "workflow jobs: $(cat "$T/out")"
import os, re, sys, yaml
d = sys.argv[1]
def load(n):
    return yaml.safe_load(open(os.path.join(d, n)))
# every job that can mint the signing identity runs in a protected environment: "release" (owner approves) for
# GameCove releases, "nightly" (main only, no daily approval) for the firmware and upscaler lists
for n in sorted(os.listdir(d)):
    for name, j in load(n)["jobs"].items():
        if (j.get("permissions") or {}).get("id-token") == "write":
            assert j.get("environment") in ("release", "nightly"), f"{n}:{name} signs without a protected environment"
assert load("release.yml")["jobs"]["release"].get("environment") == "release"
for n in ("firmware.yml", "upscalers.yml"):
    assert load(n)["jobs"]["publish"].get("environment") == "nightly", n
# gamedb and device photos: scrapers in a read-only job, the release written only by a job that runs gh
for n, scraper in (("gamedb.yml", "gamedb.build"), ("device-photos.yml", "tools/device_photos/build.py")):
    doc = load(n)
    assert doc.get("permissions") == {}, n + ": nothing at the top level"
    b, p = doc["jobs"]["build"], doc["jobs"]["publish"]
    assert b.get("permissions") == {"contents": "read"}, (n, b.get("permissions"))
    assert b.get("if") == "github.ref == 'refs/heads/main'", n + ": build for publishing only on main"
    assert p.get("needs") == "build" and p.get("permissions") == {"contents": "write"}, (n, p.get("permissions"))
    brun = "\n".join(s.get("run", "") for s in b["steps"])
    prun = "\n".join(s.get("run", "") for s in p["steps"])
    assert scraper in brun and "gh release upload" not in brun and "gh release create" not in brun, n + ": build must not publish"
    assert "pip install" not in prun and scraper not in prun and "pytest" not in prun, n + ": publish must not run the scrapers"
    assert not any(s.get("uses", "").startswith("actions/checkout@") for s in p["steps"]), n + ": publish needs no code"
    assert any(s.get("uses", "").startswith("actions/upload-artifact@") for s in b["steps"])
    assert any(s.get("uses", "").startswith("actions/download-artifact@") for s in p["steps"])
    for j in doc["jobs"].values():
        for s in j["steps"]:
            if s.get("uses", "").startswith("actions/checkout@"):
                assert s.get("with", {}).get("persist-credentials") is False, n + ": checkout keeps no token"
            assert "${{" not in s.get("run", ""), n + ": ${{ }} inside run:"
mk = load("device-photos.yml")["jobs"]["maker-links"]
assert mk.get("permissions") == {"contents": "read", "issues": "write"}, mk.get("permissions")
# the upscalers publish job re-checks the artifact with GameCove's own code before signing (review 2, problem 15)
up = load("upscalers.yml")["jobs"]["publish"]
runs = [s.get("run", "") for s in up["steps"]]
chk = [i for i, r in enumerate(runs) if "tools/upscalers/check_plan.py dist" in r]
sig = [i for i, r in enumerate(runs) if "cosign sign-blob" in r]
assert chk and sig and chk[0] < sig[0], "check_plan.py must run before signing"
# the tag job starts the release run on the full tag ref; a re-run never unpublishes a release (review 2, low 22)
rel = load("release.yml")["jobs"]
assert 'gh workflow run release.yml --ref "refs/tags/$tag"' in "\n".join(s.get("run", "") for s in rel["tag"]["steps"])
pub = "\n".join(s.get("run", "") for s in rel["release"]["steps"])
assert "--draft=true" not in pub and "isDraft" in pub, "a published release must not go back to draft"
PY
test -s "$REPO/docs/RELEASING.md" && grep -q "Release tags" "$REPO/docs/RELEASING.md" && grep -q "environment" "$REPO/docs/RELEASING.md" && ok || bad "docs/RELEASING.md must describe the tag ruleset and the release environment"

# ------------------------------------------------------------- IGDB / ProtonDB attribution (M24)
grep -q "Game data from IGDB" "$REPO/gamedb/NOTICE.md" && grep -q "ODbL" "$REPO/gamedb/NOTICE.md" && ok || bad "gamedb/NOTICE.md must credit IGDB and ProtonDB (ODbL)"
grep -q "gh release upload gamedb dist/NOTICE.md" "$REPO/.github/workflows/gamedb.yml" && grep -q "gh release edit gamedb --notes-file dist/NOTICE.md" "$REPO/.github/workflows/gamedb.yml" && ok || bad "gamedb.yml must publish NOTICE.md as an asset and as the notes"
grep -q "Game data from \[IGDB\](https://www.igdb.com)" "$REPO/README.md" && ok || bad "README must credit IGDB with a link"
# ------------------------------------------------------------- no SteamGridDB key in any build
# Users sign in to SteamGridDB in the Game art step; a key inside a public build could be pulled out.
if grep -rn "STEAMGRIDDB_API_KEY\|project_keys" "$REPO/.github/workflows" "$REPO/packaging" --include=*.yml --include=*.sh --include=*.spec 2>/dev/null | grep -v "packaging/tests/" >"$T/sgdbkey"; then bad "a build reads a SteamGridDB key: $(head -3 "$T/sgdbkey" | tr '\n' ' ')"; else ok; fi
if git -C "$REPO" grep -nI "project_keys\|PROJECT_KEYS" -- app/scripts >"$T/sgdbkey" 2>/dev/null; then bad "the app reads a bundled key: $(head -3 "$T/sgdbkey" | tr '\n' ' ')"; else ok; fi

grep -q "Game data from IGDB" "$REPO/CREDITS.md" && ok || bad "CREDITS.md must credit IGDB"

# ------------------------------------------------------------- no personal data or machine paths in tests (L37)
git -C "$REPO" grep -nI -o '7656119[0-9]\{10\}' -- app/tests packaging/tests >"$T/ids" 2>/dev/null || true
sed 's/.*:\(7656119[0-9]*\)$/\1/' "$T/ids" | sort -u | while read -r id; do
	case "$id" in
	76561197960265728 | 76561197972611406 | 76561198047920049 | 76561197960266729 | 76561197960267730 | 76561198000000001 | 76561198000000002 | 76561198012345678) ;;
	*) echo "$id" ;;
	esac
done >"$T/unknown_ids"
if [ -s "$T/unknown_ids" ]; then bad "SteamID64s in tests that aren't the synthetic ones (app/tests/fixtures/STEAM_IDS.md): $(tr '\n' ' ' <"$T/unknown_ids")"; else ok; fi
if git -C "$REPO" grep -nI '/home/clau''de/' -- app tools packaging gamedb fixes session >"$T/paths" 2>/dev/null; then bad "machine-specific paths: $(head -5 "$T/paths" | tr '\n' ' ')"; else ok; fi

echo "$PASS passed, $FAILS failed"
[ "$FAILS" -eq 0 ]
