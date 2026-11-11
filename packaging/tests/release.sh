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
# RPM: run the spec's %prep licence loop against the repo and check %files takes the result
SPEC="$REPO/packaging/rpm/gamecove.spec"
awk '/^# licence and notice texts/{f=1;next} f&&/^done < packaging\/licenses.list/{print;exit} f' "$SPEC" >"$T/prep.sh"
if (cd "$REPO" && mkdir -p "$T/rpm" && cd "$T/rpm" && ln -s "$REPO/packaging" packaging && for s in LICENSE CREDITS.md LICENSES fixes app; do ln -s "$REPO/$s" "$s"; done && sh "$T/prep.sh") >"$T/out" 2>&1; then ok; else bad "spec %prep licence loop: $(cat "$T/out")"; fi
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

# ------------------------------------------------------------- data releases live in GameCove-data (owner decision 2026-11-11)
# The gamedb, firmware, upscalers and device-photos releases are built, signed and published by the workflows of
# github.com/IHulkSmashI/GameCove-data (its tests/check_workflows.py checks them); this repo's Releases page only has
# the v* app releases. The app names that repo in one place (data_repo.gd), the helper in mirror.py; they must agree.
for n in upscalers.yml firmware.yml gamedb.yml device-photos.yml fixes.yml; do
	[ ! -e "$REPO/.github/workflows/$n" ] && ok || bad ".github/workflows/$n publishes data: it belongs in IHulkSmashI/GameCove-data"
done
DR="$REPO/app/scripts/system/data_repo.gd"
MP="$REPO/packaging/helpers/gamecove_upscale/mirror.py"
FI="$REPO/app/scripts/system/firmware_index.gd"
python3 -I - "$DR" "$MP" "$FI" "$GG" >"$T/out" 2>&1 <<'PY' && ok || bad "data repo pins: $(cat "$T/out")"
import re, sys
dr, mp, fi, gg = (open(p).read() for p in sys.argv[1:5])
def gd(name):
    return re.search(r'^const %s := "(.*)"$' % name, dr, re.M).group(1).replace("\\\\", "\\")
def py(name):
    return re.search(r'^%s = r?"(.*)"$' % name, mp, re.M).group(1)
assert gd("REPO") == py("REPO") == "IHulkSmashI/GameCove-data", (gd("REPO"), py("REPO"))
assert gd("RELEASES") == "https://github.com/IHulkSmashI/GameCove-data/releases/download/"
assert 'RELEASE_BASE = f"https://github.com/{REPO}/releases/download/"' in mp
assert gd("OIDC_ISSUER") == py("OIDC_ISSUER") == "https://token.actions.githubusercontent.com"
assert gd("UPSCALERS_SIGNER") == py("SIGNER_IDENTITY"), (gd("UPSCALERS_SIGNER"), py("SIGNER_IDENTITY"))
assert "const SIGNER_IDENTITY := DataRepo.FIRMWARE_SIGNER" in fi and "const OIDC_ISSUER := DataRepo.OIDC_ISSUER" in fi
assert "const URL := DataRepo.FIRMWARE_URL" in fi
assert "IHulkSmashI/GameCove-data/releases/download/upscalers(" in mp
base = "https://github.com/IHulkSmashI/GameCove-data/.github/workflows/"
for name, wf in (("FIRMWARE_SIGNER", "firmware.yml"), ("UPSCALERS_SIGNER", "upscalers.yml")):
    r = re.compile(gd(name))
    assert r.search(base + wf + "@refs/heads/main") and r.search((base + wf + "@refs/heads/main").lower()), name
    for other in ("https://github.com/IHulkSmashI/GameCove/.github/workflows/" + wf + "@refs/heads/main",
                  base + wf + "@refs/heads/dev", base + wf + "@refs/tags/v1.0.0", base + wf + "@refs/heads/main2",
                  "https://github.com/fork/GameCove-data/.github/workflows/" + wf + "@refs/heads/main",
                  base + ("upscalers.yml" if wf == "firmware.yml" else "firmware.yml") + "@refs/heads/main"):
        assert not r.search(other), (name, other)
# the helper checks signatures with the cosign the installer pins
for k in ("COSIGN_VERSION", "COSIGN_SHA256"):
    a = re.search(r"^%s=(\S+)$" % k, gg, re.M).group(1)
    b = re.search(r'^%s = "(\S+)"$' % k, mp, re.M).group(1)
    assert a == b, (k, a, b)
PY
app_cos=$(sed -n 's/^const COSIGN_VERSION := "\(.*\)"$/\1/p' "$REPO/app/scripts/system/updates.gd")
gg_cos=$(sed -n 's/^COSIGN_VERSION=//p' "$GG")
[ -n "$app_cos" ] && [ "$app_cos" = "$gg_cos" ] && ok || bad "updates.gd COSIGN_VERSION ($app_cos) must match get-gamecove.sh ($gg_cos)"
# nothing downloads data from this repo's releases any more (only the v* app releases are here); the tests that
# name the old home on purpose (to check it's refused) are the only exceptions
git -C "$REPO" grep -nI -i "IHulkSmashI/GameCove/releases/download" -- . \
	':!packaging/tests/release.sh' ':!app/tests/test_data_repo.gd' ':!packaging/helpers/tests/test_upscalers_index.py' >"$T/old" 2>/dev/null
if [ -s "$T/old" ]; then bad "still downloads data from the app repo's releases: $(head -5 "$T/old" | tr '\n' ' ')"; else ok; fi
# only release.yml writes releases here, and only v* tags: get-gamecove.sh and the README badge never see a data release
for f in "$REPO"/.github/workflows/*.yml; do
	case "$f" in */release.yml) continue ;; esac
	if grep -n "gh release \(create\|upload\|edit\)\|releases/assets\|action-gh-release" "$f" >"$T/rel"; then bad "$f writes a release: $(tr '\n' ' ' <"$T/rel")"; else ok; fi
done

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
# every job that can mint the signing identity runs in the protected "release" environment (owner approves); the
# nightly data lists sign in GameCove-data's "nightly" environment, not here
for n in sorted(os.listdir(d)):
    for name, j in load(n)["jobs"].items():
        if (j.get("permissions") or {}).get("id-token") == "write":
            assert j.get("environment") == "release", f"{n}:{name} signs without the protected release environment"
assert load("release.yml")["jobs"]["release"].get("environment") == "release"
# the weekly maker image link check (it reads this repo's data and files its issue here) needs no write to contents
mk = load("maker-links.yml")
assert mk.get("permissions") == {} and list(mk["jobs"]) == ["maker-links"], "maker-links.yml: one job, nothing at the top"
mk = mk["jobs"]["maker-links"]
assert mk.get("permissions") == {"contents": "read", "issues": "write"}, mk.get("permissions")
for s in mk["steps"]:
    if s.get("uses", "").startswith("actions/checkout@"):
        assert s.get("with", {}).get("persist-credentials") is False, "maker-links: checkout keeps no token"
    assert "${{" not in s.get("run", ""), "maker-links: ${{ }} inside run:"
assert "tools/device_photos/makers.py --check" in "\n".join(s.get("run", "") for s in mk["steps"])
# the tag job starts the release run on the full tag ref; a re-run never unpublishes a release (review 2, low 22)
rel = load("release.yml")["jobs"]
assert 'gh workflow run release.yml --ref "refs/tags/$tag"' in "\n".join(s.get("run", "") for s in rel["tag"]["steps"])
pub = "\n".join(s.get("run", "") for s in rel["release"]["steps"])
assert "--draft=true" not in pub and "isDraft" in pub, "a published release must not go back to draft"
PY
test -s "$REPO/docs/RELEASING.md" && grep -q "Release tags" "$REPO/docs/RELEASING.md" && grep -q "environment" "$REPO/docs/RELEASING.md" && ok || bad "docs/RELEASING.md must describe the tag ruleset and the release environment"

# ------------------------------------------------------------- IGDB / ProtonDB attribution (M24)
grep -q "Game data from IGDB" "$REPO/gamedb/NOTICE.md" && grep -q "ODbL" "$REPO/gamedb/NOTICE.md" && ok || bad "gamedb/NOTICE.md must credit IGDB and ProtonDB (ODbL)"
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
