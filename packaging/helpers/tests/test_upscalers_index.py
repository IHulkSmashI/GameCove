"""The signed upscalers index (mirror.py): accepted only with the nightly workflow's signature, every field checked,
the newest entries replace the pins, and without a verified index the pins (also on the mirror) are used. All
network is faked: mirror._fetch answers from a dict, cosign is a fake that checks what the real one checks (the
blob's hash, the issuer, the identity against --certificate-identity-regexp)."""
import hashlib
import json
import os
import stat
import sys
import textwrap

import pytest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from gamecove_upscale import cli, downloads, games, mirror, optiscaler, upkeep  # noqa: E402

GOOD_ID = "https://github.com/IHulkSmashI/GameCove/.github/workflows/upscalers.yml@refs/heads/main"
ISSUER = "https://token.actions.githubusercontent.com"
RDNA35 = {"vendor": "amd", "family": "amd-rdna3", "arch": "RDNA3.5", "xmx": False}
M = mirror.RELEASE_BASE + "upscalers/"


def sha(b: bytes) -> str:
    return hashlib.sha256(b).hexdigest()


def _w(path, text):
    os.makedirs(os.path.dirname(str(path)), exist_ok=True)
    with open(path, "wb" if isinstance(text, bytes) else "w") as f:
        f.write(text)


@pytest.fixture
def cosign(tmp_path, monkeypatch):
    """A fake cosign: verify-blob passes only when the bundle names this blob's sha256, the issuer is GitHub's and
    its identity matches the regexp the caller passed (Python's re reads cosign's (?i) the same way)."""
    p = tmp_path / "bin" / "cosign"
    _w(p, textwrap.dedent(f"""\
        #!{sys.executable}
        import hashlib, json, re, sys
        a = sys.argv[1:]
        assert a[0] == "verify-blob"
        opt = dict(zip(a[1:-1:2], a[2:-1:2]))
        b = json.load(open(opt["--bundle"]))
        blob = hashlib.sha256(open(a[-1], "rb").read()).hexdigest()
        ok = (b["sha256"] == blob and b["issuer"] == opt["--certificate-oidc-issuer"]
              and re.search(opt["--certificate-identity-regexp"], b["identity"]))
        print("Verified OK" if ok else "Error: none of the expected identities matched", file=sys.stderr)
        sys.exit(0 if ok else 1)
        """))
    os.chmod(p, os.stat(p).st_mode | stat.S_IEXEC)
    monkeypatch.setenv("GAMECOVE_COSIGN", str(p))
    return str(p)


def bundle_for(raw: bytes, identity=GOOD_ID, issuer=ISSUER) -> bytes:
    return json.dumps({"sha256": sha(raw), "identity": identity, "issuer": issuer}).encode()


def comp(version, payload: bytes, asset, upstream, inner=None, tag=None):
    name = mirror.mirror_name("x", version, sha(payload), asset)
    e = {"version": version, "tag": tag or version, "asset": asset, "upstream_url": upstream,
         "mirror_url": M + name, "sha256": sha(payload), "size": len(payload), "date": "2026-11-08"}
    if inner:
        e["inner"] = inner
    return e


def index(generated="2026-11-09T05:00:00Z", **components) -> bytes:
    return json.dumps({"schema": 1, "generated": generated, "components": components}).encode()


def serve(monkeypatch, pages):
    def fetch(url, limit, timeout):
        if url not in pages:
            raise OSError(f"404 {url}")
        return pages[url]
    monkeypatch.setattr(mirror, "_fetch", fetch)


OPTI = b"optiscaler-0.9.5 archive"
PATCHER = b"optipatcher new build"


def newest():
    return index(optiscaler=comp("0.9.5", OPTI, "Optiscaler_0.9.5.7z", "https://github.com/optiscaler/OptiScaler/releases/download/v0.9.5/Optiscaler_0.9.5.7z", tag="v0.9.5"),
                 optipatcher=comp("rolling-20261108", PATCHER, "OptiPatcher_rolling.asi",
                                  "https://github.com/xXJSONDeruloXx/OptiScaler-Bleeding-Edge/releases/download/bins-for-optipatcher-rolling/OptiPatcher_rolling.asi"))


# ---- the signature ----------------------------------------------------------------------------------------------
def test_verified_index_replaces_the_pins(tmp_path, monkeypatch, cosign):
    raw = newest()
    serve(monkeypatch, {mirror.INDEX_URL: raw, mirror.BUNDLE_URL: bundle_for(raw)})
    home = str(tmp_path / "home")
    assert mirror.refresh(home)["state"] == "verified"
    v = games.versions(home)
    assert v["optiscaler"]["version"] == "0.9.5" and v["optiscaler"]["source"] == "index"
    assert v["optiscaler"]["mirror"].startswith(M) and v["optiscaler"]["sha256"] == sha(OPTI)
    assert v["optiscaler"]["layout"] if "layout" in games.pins()["optiscaler"] else True
    op = v["optiscaler"]["extras"][0]
    assert op["name"] == "OptiPatcher" and op["sha256"] == sha(PATCHER) and op["dest"] == "plugins/OptiPatcher.asi"
    assert v["optiscaler_v10"]["extras"][0]["sha256"] == sha(PATCHER), "OptiPatcher is the same file in both"
    assert v["optiscaler_v10"]["version"] == games.pins()["optiscaler_v10"]["version"], "not in the index: the pin"
    assert games.versions() == games.pins(), "without a home: the pins"
    # within FRESH_S the copy is used without a fetch
    serve(monkeypatch, {})
    assert mirror.refresh(home)["state"] == "cached"


def test_tampered_index_is_refused_and_the_pins_stay(tmp_path, monkeypatch, cosign):
    raw = newest()
    evil = raw.replace(b"0.9.5", b"6.6.6")
    serve(monkeypatch, {mirror.INDEX_URL: evil, mirror.BUNDLE_URL: bundle_for(raw)})
    home = str(tmp_path / "home")
    r = mirror.refresh(home)
    assert r["state"] == "bad-signature"
    assert games.versions(home) == games.pins()
    assert not os.path.exists(os.path.join(home, mirror.CACHE, mirror.INDEX_NAME))


@pytest.mark.parametrize("identity,issuer", [
    ("https://github.com/IHulkSmashI/GameCove/.github/workflows/firmware.yml@refs/heads/main", ISSUER),   # another workflow
    ("https://github.com/IHulkSmashI/GameCove/.github/workflows/upscalers.yml@refs/heads/evil", ISSUER),  # another branch
    ("https://github.com/someone/GameCove/.github/workflows/upscalers.yml@refs/heads/main", ISSUER),      # a fork
    ("https://github.com/IHulkSmashI/GameCove/.github/workflows/upscalers.yml@refs/heads/main.x", ISSUER),
    (GOOD_ID, "https://accounts.google.com"),                                                             # another issuer
])
def test_wrong_identity_is_refused(tmp_path, monkeypatch, cosign, identity, issuer):
    raw = newest()
    serve(monkeypatch, {mirror.INDEX_URL: raw, mirror.BUNDLE_URL: bundle_for(raw, identity, issuer)})
    home = str(tmp_path / "home")
    assert mirror.refresh(home)["state"] == "bad-signature"
    assert games.versions(home)["optiscaler"]["version"] == "0.9.4"


def test_identity_is_case_insensitive_like_github(tmp_path, monkeypatch, cosign):
    raw = newest()
    serve(monkeypatch, {mirror.INDEX_URL: raw, mirror.BUNDLE_URL: bundle_for(raw, GOOD_ID.replace("IHulkSmashI", "ihulksmashi"))})
    assert mirror.refresh(str(tmp_path / "h"))["state"] == "verified"


def test_no_cosign_means_pins(tmp_path, monkeypatch):
    raw = newest()
    serve(monkeypatch, {mirror.INDEX_URL: raw, mirror.BUNDLE_URL: bundle_for(raw)})
    monkeypatch.setattr(mirror.shutil, "which", lambda name: None)
    home = str(tmp_path / "home")
    assert mirror.refresh(home)["state"] == "unverified"      # the pinned cosign download is faked offline too
    assert games.versions(home) == games.pins()


def test_cosign_download_is_checked_against_the_pin(tmp_path, monkeypatch):
    monkeypatch.setattr(mirror.shutil, "which", lambda name: None)
    serve(monkeypatch, {mirror.COSIGN_URL: b"not cosign"})
    home = str(tmp_path / "home")
    assert mirror.cosign_path(home) is None
    assert not os.path.exists(os.path.join(home, mirror.TOOLS, "cosign-" + mirror.COSIGN_VERSION))


def test_offline_falls_back_to_the_pins_and_a_verified_copy_wins_over_them(tmp_path, monkeypatch, cosign):
    home = str(tmp_path / "home")
    assert mirror.refresh(home)["state"] == "offline"
    assert games.versions(home) == games.pins()
    raw = newest()
    serve(monkeypatch, {mirror.INDEX_URL: raw, mirror.BUNDLE_URL: bundle_for(raw)})
    mirror.refresh(home)
    serve(monkeypatch, {})
    assert mirror.refresh(home, force=True)["state"] == "offline"
    assert games.versions(home)["optiscaler"]["version"] == "0.9.5", "the last verified list still counts offline"
    # a cached file changed afterwards no longer counts
    p = os.path.join(home, mirror.CACHE, mirror.INDEX_NAME)
    _w(p, raw.replace(b"0.9.5", b"0.9.6"))
    mirror._memo.clear()
    assert games.versions(home) == games.pins()
    # and an old verification expires
    _w(p, raw)
    st = os.path.join(home, mirror.CACHE, "verified.json")
    s = json.load(open(st))
    s["verified_at"] -= mirror.MAX_AGE_S + 1
    _w(st, json.dumps(s))
    assert mirror.load(home) is None


def test_an_older_signed_index_never_replaces_a_newer_one(tmp_path, monkeypatch, cosign):
    home = str(tmp_path / "home")
    new = newest()
    serve(monkeypatch, {mirror.INDEX_URL: new, mirror.BUNDLE_URL: bundle_for(new)})
    mirror.refresh(home)
    old = index("2026-10-01T00:00:00Z")
    serve(monkeypatch, {mirror.INDEX_URL: old, mirror.BUNDLE_URL: bundle_for(old)})
    assert mirror.refresh(home, force=True)["state"] == "older"
    assert games.versions(home)["optiscaler"]["version"] == "0.9.5"


@pytest.mark.parametrize("mutate", [
    lambda e: e.update(mirror_url="https://evil.example/x.7z"),
    lambda e: e.update(mirror_url=M + "../firmware/x.7z"),
    lambda e: e.update(mirror_url="https://github.com/IHulkSmashI/GameCove/releases/download/v1.0.0/x.7z"),
    lambda e: e.update(version="../../.ssh"),
    lambda e: e.update(sha256="abc"),
    lambda e: e.update(upstream_url="http://plain/x"),
    lambda e: e.update(asset="../x.7z"),
])
def test_parse_checks_every_field(mutate):
    d = json.loads(newest())
    mutate(d["components"]["optiscaler"])
    with pytest.raises(ValueError):
        mirror.parse(json.dumps(d).encode())
    with pytest.raises(ValueError):
        mirror.parse(b'{"schema": 2, "generated": "2026-11-09T00:00:00Z", "components": {}}')


# ---- the pins live on the mirror too (part A) ---------------------------------------------------------------------
def test_every_pin_has_its_expected_mirror_name():
    v = games.pins()
    comps = {"optiscaler": "optiscaler", "optiscaler_v10": "optiscaler_v10", "xess_xmx_linux": "xess_xmx_linux",
             "reframework": "reframework"}
    for key, c in comps.items():
        e = v[key]
        fn = e.get("asset") or e["url"].rsplit("/", 1)[1]
        assert e["mirror"] == mirror.mirror_url(mirror.mirror_name(c, e["version"], e["sha256"], fn)), key
        assert mirror.is_mirror_url(e["mirror"]) and e["url"].startswith("https://")
        for x in e.get("extras", []):
            xc = {"OptiPatcher": "optipatcher", "fakenvapi": "fakenvapi"}[x["name"]]
            assert x["mirror"] == mirror.mirror_url(mirror.mirror_name(xc, x["version"], x["sha256"], x["url"].rsplit("/", 1)[1]))
    for key in mirror.FILES_COMPONENTS:
        e = v[key]
        assert set(e["mirror"]) == set(e["files"])
        for n, s in e["files"].items():
            assert e["mirror"][n] == mirror.mirror_url(mirror.mirror_name(key, e["version"], s, n))


# ---- downloads: mirror first, sha256 always ---------------------------------------------------------------------------
def _fake_dl(pages, calls):
    def dl(url, dest, timeout=60.0):
        calls.append(url)
        if url not in pages:
            raise OSError("404")
        _w(dest, pages[url])
        return dest
    return dl


def test_hash_mismatch_is_never_installed(tmp_path, monkeypatch):
    calls = []
    item = {"mirror": M + "x-1-aaaa-f.asi", "url": "https://up.example/f.asi", "sha256": sha(b"good")}
    monkeypatch.setattr(downloads, "download", _fake_dl({item["mirror"]: b"evil", item["url"]: b"evil too"}, calls))
    dest = str(tmp_path / "f.asi")
    _w(dest, b"old good file")
    with pytest.raises(ValueError):
        downloads.get_verified(downloads.sources(item), item["sha256"], dest)
    assert open(dest, "rb").read() == b"old good file", "the file already there stays"
    assert calls == [item["mirror"], item["url"]] and not os.path.exists(dest + ".new")
    # a tampered mirror, a good upstream: the upstream bytes (same sha256) are used
    monkeypatch.setattr(downloads, "download", _fake_dl({item["mirror"]: b"evil", item["url"]: b"good"}, []))
    downloads.get_verified(downloads.sources(item), item["sha256"], dest)
    assert open(dest, "rb").read() == b"good"
    # no pin: nothing downloaded
    with pytest.raises(PermissionError):
        downloads.get_verified(downloads.sources(item), "", dest)
    # a "mirror" off GameCove's release is ignored
    assert downloads.sources({"mirror": "https://evil.example/x", "url": "https://up/x"}) == ["https://up/x"]


def test_pinned_release_entry_comes_from_the_mirror_without_the_api(tmp_path, monkeypatch):
    import zipfile
    z = tmp_path / "x.zip"
    with zipfile.ZipFile(z, "w") as zf:
        zf.writestr("pkg/install.sh", "echo")
    data = z.read_bytes()
    e = dict(games.pins()["xess_xmx_linux"], sha256=sha(data))
    calls = []
    monkeypatch.setattr(downloads, "download", _fake_dl({e["mirror"]: data}, calls))
    monkeypatch.setattr(downloads, "release", lambda *a: pytest.fail("no API call for a mirrored pin"))
    got = downloads.fetch(e, str(tmp_path / "w"))
    assert calls == [e["mirror"]] and got["tag"] == "20261104" and os.path.isfile(os.path.join(got["dir"], "pkg/install.sh"))


def test_link_in_an_archive_is_refused_from_the_mirror_too(tmp_path, monkeypatch):
    import zipfile
    z = tmp_path / "x.zip"
    with zipfile.ZipFile(z, "w") as zf:
        zi = zipfile.ZipInfo("pkg/install.sh")
        zi.external_attr = 0o120777 << 16
        zf.writestr(zi, "/etc/passwd")
    data = z.read_bytes()
    e = dict(games.pins()["xess_xmx_linux"], sha256=sha(data))
    monkeypatch.setattr(downloads, "download", _fake_dl({e["mirror"]: data}, []))
    with pytest.raises(ValueError):
        downloads.fetch(e, str(tmp_path / "w"))


# ---- check / update / a game's own copy -------------------------------------------------------------------------------
def _pkg(home, ver, patcher=b"op-old", layout="flat"):
    d = optiscaler.package_dir(home, ver)
    sub = "OptiScaler/" if layout == "subfolder" else ""
    for f, t in (("OptiScaler.dll", "opti-" + ver), ("OptiScaler.ini", "[Upscalers]\nDx12Upscaler=auto\n"),
                 (sub + "libxess.dll", "xess-" + ver), (sub + "plugins/OptiPatcher.asi", patcher)):
        _w(os.path.join(d, f), t)
    _w(os.path.join(d, optiscaler.PACKAGE_RECORD), json.dumps({"version": ver, "layout": layout, "installed": 1.0}))
    return d


def test_fallback_pins_report_no_update_for_the_tested_versions(tmp_path):
    home = str(tmp_path)
    pin = games.pins()["optiscaler"]
    _pkg(home, pin["version"])
    r = upkeep.check(home, RDNA35)
    row = next(c for c in r["components"] if c["id"] == "optiscaler")
    assert row == {"id": "optiscaler", "name": "OptiScaler", "installed": "0.9.4", "latest": "0.9.4", "update": False}
    assert r["index"]["verified"] is False and r["update"] is False


def test_check_update_and_game_update(tmp_path, monkeypatch, cosign):
    home = str(tmp_path / "home")
    monkeypatch.setattr(optiscaler.userexec, "chown_tree", lambda p, h: None)
    raw = newest()
    serve(monkeypatch, {mirror.INDEX_URL: raw, mirror.BUNDLE_URL: bundle_for(raw)})
    _pkg(home, "0.9.4", b"op-old")
    # a game with GameCove's 0.9.4, and a file the user changed since (kept by the update, as by undo)
    lib = os.path.join(home, ".local/share/Steam/steamapps")
    _w(os.path.join(lib, "appmanifest_200.acf"), '"AppState"\n{\n "appid" "200"\n "name" "G"\n "installdir" "G"\n}\n')
    g = os.path.join(lib, "common", "G")
    _w(os.path.join(g, "G.exe"), "x" * 10)
    _w(os.path.join(g, "nvngx_dlss.dll"), "x" * 10)
    assert games.choose(home, "200", "fsr31", 0, RDNA35)["ok"]          # offline at this point: 0.9.4 is used
    assert open(os.path.join(g, "dxgi.dll")).read() == "opti-0.9.4"
    _w(os.path.join(g, "libxess.dll"), "the user's own build")
    # the background check: OptiScaler 0.9.5 is out
    r = cli.run(["check", "--home", home, "--gpu", json.dumps(RDNA35), "--online"])
    rows = {c["id"]: c for c in r["components"]}
    assert r["update"] and rows["optiscaler"]["installed"] == "0.9.4" and rows["optiscaler"]["latest"] == "0.9.5"
    assert rows["optiscaler"]["update"] is True and r["index"]["verified"] is True
    st = cli.run(["status", "--home", home, "--key", "200", "--gpu", json.dumps(RDNA35)])
    assert st["game_update"] is True and st["opti_version"] == "0.9.4" and st["opti_latest"] == "0.9.5"
    # Update: the newest package comes from the mirror (install faked: no 7z here)
    installs = []

    def fake_install(h, entry):
        installs.append(entry)
        assert entry["mirror"].startswith(M) and entry["sha256"] == sha(OPTI)
        _pkg(h, entry["version"], PATCHER)
        return {"ok": True, "version": entry["version"]}
    monkeypatch.setattr(optiscaler, "install", fake_install)
    out = cli.run(["update", "--home", home, "--gpu", json.dumps(RDNA35)])
    assert out["ok"] and [e["version"] for e in installs] == ["0.9.5"] and out["games"] == ["200"]
    assert open(os.path.join(g, "dxgi.dll")).read() == "opti-0.9.4", "games keep theirs until their own update"
    assert optiscaler.installed(home, "0.9.4"), "0.9.4 stays while a game runs it"
    # the game's own update: 0.9.5 in, the user's changed file kept, settings and proxy name the same
    up = cli.run(["game-update", "--home", home, "--key", "200", "--gpu", json.dumps(RDNA35)])
    assert up["ok"] and up["version"] == "0.9.5" and up["was"] == "0.9.4", up
    assert open(os.path.join(g, "dxgi.dll")).read() == "opti-0.9.5"
    assert open(os.path.join(g, "plugins/OptiPatcher.asi"), "rb").read() == PATCHER
    # the user's changed file wasn't deleted: it is kept aside as the game's own, as any game file OptiScaler replaces
    assert open(os.path.join(g, optiscaler.STATE, "backup", "libxess.dll")).read() == "the user's own build"
    assert "Dx12Upscaler=fsr31" in open(os.path.join(g, "OptiScaler.ini")).read()
    assert games.status(home, "200", RDNA35)["game_update"] is False
    assert not optiscaler.installed(home, "0.9.4"), "nothing runs 0.9.4 any more: pruned"
    assert cli.run(["game-update", "--home", home, "--key", "200", "--gpu", json.dumps(RDNA35)])["up_to_date"]
    # undo still puts the game back as it was, the user's file included
    assert games.undo(home, "200", RDNA35)["ok"]
    assert not os.path.exists(os.path.join(g, "dxgi.dll")) and not os.path.exists(os.path.join(g, "OptiScaler.ini"))
    assert open(os.path.join(g, "libxess.dll")).read() == "the user's own build"


def test_newer_optipatcher_alone_updates_the_package_in_place(tmp_path, monkeypatch, cosign):
    home = str(tmp_path / "home")
    raw = index(optipatcher=comp("rolling-20261108", PATCHER, "OptiPatcher_rolling.asi", "https://up.example/OptiPatcher_rolling.asi"))
    serve(monkeypatch, {mirror.INDEX_URL: raw, mirror.BUNDLE_URL: bundle_for(raw)})
    mirror.refresh(home)
    old = b"tested optipatcher"
    real_pins = games.pins()
    real_pins["optiscaler"]["extras"][0]["sha256"] = sha(old)      # the tested build, as these bytes
    monkeypatch.setattr(games, "pins", lambda: json.loads(json.dumps(real_pins)))
    mirror._memo.clear()
    _pkg(home, "0.9.4", old)
    rows = {c["id"]: c for c in upkeep.check(home, RDNA35)["components"]}
    assert rows["optipatcher"]["update"] and rows["optipatcher"]["installed"] == "rolling-dfg017"
    assert rows["optiscaler"]["update"] is False
    calls = []
    monkeypatch.setattr(downloads, "download", _fake_dl({games.versions(home)["optiscaler"]["extras"][0]["mirror"]: PATCHER}, calls))
    monkeypatch.setattr(optiscaler.userexec, "chown_tree", lambda p, h: None)
    out = upkeep.update(home, RDNA35)
    assert out["ok"] and out["results"]["optiscaler"]["updated_extras"] == ["OptiPatcher"], out
    assert open(os.path.join(optiscaler.package_dir(home, "0.9.4"), "plugins/OptiPatcher.asi"), "rb").read() == PATCHER
    assert len(calls) == 1 and calls[0].startswith(M)


def test_files_the_user_put_there_are_never_called_outdated(tmp_path):
    home = str(tmp_path)
    _w(os.path.join(home, optiscaler.FSR4_AMD_DIR, optiscaler.FSR4_AMD_FILE), "a build from somewhere else")
    rows = {c["id"]: c for c in upkeep.check(home, RDNA35)["components"]}
    assert rows["fsr4_amd"]["installed"] == "your own files" and rows["fsr4_amd"]["update"] is False
