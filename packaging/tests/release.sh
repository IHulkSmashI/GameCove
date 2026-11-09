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
	.gitignore | CONTRIBUTING.md | CREDITS.md | LICENSE | README.md) ok ;;
	*) bad "unexpected file in the repo root: $f" ;;
	esac
done
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
mkdir -p "$T/ss/usr/bin"
printf '#!/bin/sh\n' >"$T/ss/usr/bin/gamescope-session-plus"
if sh "$REPO/packaging/sysext/build-sysext.sh" --app "$T/app" --session-src "$T/ss" --out "$T/sx" --tree-only >"$T/out" 2>&1; then ok; else bad "sysext tree: $(cat "$T/out")"; fi
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
for pat in CREDITS.md 'fonts/OFL-*.txt' addons/kenyoni/qr_code/LICENSE.md; do
	case ", $inc," in *", $pat,"*) ok ;; *) bad "export include_filter lacks $pat ($inc)" ;; esac
done
if [ -L "$REPO/app/CREDITS.md" ] && cmp -s "$REPO/app/CREDITS.md" "$REPO/CREDITS.md"; then ok; else bad "app/CREDITS.md must link to the repo's CREDITS.md"; fi

# ------------------------------------------------------------- release workflow supply chain (M5, M6, L26-L28)
W="$REPO/.github/workflows/release.yml"
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
	grep -n 'uses:' "$f" | grep -v 'uses: [^ ]*@[0-9a-f]\{40\} # v[0-9]' >"$T/unpinned"
	if [ -s "$T/unpinned" ]; then bad "$f: actions not pinned by commit: $(tr '\n' ' ' <"$T/unpinned")"; else ok; fi
	if grep -n 'container:\|image:' "$f" | grep -v '@sha256:[0-9a-f]\{64\}' | grep -v '^[0-9]*:[[:space:]]*#' | grep -q .; then bad "$f: container not pinned by digest"; else ok; fi
done
for v in GODOT_EDITOR_SHA256 GODOT_TEMPLATES_SHA256 UHB_SHA256; do
	grep -q "^  $v: [0-9a-f]\{64\}$" "$W" && ok || bad "release.yml lacks the $v pin"
	grep -q "\${$v}  .*| sha256sum -c -" "$W" && ok || bad "release.yml doesn't check $v"
done
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
# L28: CI signs and verifies with the cosign devices use
grep -q 'cosign-release: ${{ steps.cosign.outputs.version }}' "$W" && ok || bad "cosign-installer must install get-gamecove.sh's COSIGN_VERSION"
grep -q "COSIGN_SHA256=" "$W" && ok || bad "release.yml must check cosign against get-gamecove.sh's COSIGN_SHA256"

# ------------------------------------------------------------- firmware index signature (M21)
FW="$REPO/.github/workflows/firmware.yml"
grep -q "cosign sign-blob --yes --bundle dist/firmware.json.gz.sigstore.json dist/firmware.json.gz" "$FW" && ok || bad "firmware.yml must sign the index"
grep -q "dist/firmware.json.gz.sigstore.json --clobber" "$FW" && ok || bad "firmware.yml must publish the signature"
grep -q "id-token: write" "$FW" && ok || bad "firmware.yml needs id-token: write"
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
assert list(jobs) == ["build"], "one job"
job = jobs["build"]
assert job.get("permissions") == {"contents": "write", "id-token": "write"}, job.get("permissions")
assert job.get("if") == "github.ref == 'refs/heads/main'", "publish only from main (the signing identity)"
steps = job["steps"]
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

# ------------------------------------------------------------- network disclosure (M22, L34)
for host in cheapshark.com gg.deals GitHub GameStream "Wake-on-LAN" SteamGridDB "maker" "Affiliate links"; do
	grep -q "$host" "$REPO/README.md" && ok || bad "README's Network and privacy section doesn't mention $host"
	grep -qi "$host" "$REPO/docs/PRIVACY.md" && ok || bad "docs/PRIVACY.md doesn't mention $host"
done
grep -q "^## Network and privacy" "$REPO/README.md" && ok || bad "README needs a Network and privacy section"
for sw in "Background lookups" "Look up deals and prices" "Show maker photos"; do
	grep -q "$sw" "$REPO/README.md" && ok || bad "README must name the '$sw' switch"
done

# ------------------------------------------------------------- IGDB / ProtonDB attribution (M24)
grep -q "Game data from IGDB" "$REPO/gamedb/NOTICE.md" && grep -q "ODbL" "$REPO/gamedb/NOTICE.md" && ok || bad "gamedb/NOTICE.md must credit IGDB and ProtonDB (ODbL)"
grep -q "gh release upload gamedb NOTICE.md" "$REPO/.github/workflows/gamedb.yml" && grep -q "gh release edit gamedb --notes-file NOTICE.md" "$REPO/.github/workflows/gamedb.yml" && ok || bad "gamedb.yml must publish NOTICE.md as an asset and as the notes"
grep -q "Game data from \[IGDB\](https://www.igdb.com)" "$REPO/README.md" && ok || bad "README must credit IGDB with a link"
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
