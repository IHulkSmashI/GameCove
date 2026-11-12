"""One install: the upscaler files that come inside the package (tools/upscalers/fetch_bundle.py, downloads.bundled).
With the bundle there nothing is downloaded when a game is first set up; without it the mirror and upstream are
used as before; a bundle with the wrong bytes is never used."""
import hashlib
import json
import os
import re
import sys

import pytest

HERE = os.path.dirname(__file__)
sys.path.insert(0, os.path.join(HERE, ".."))
sys.path.insert(0, os.path.join(HERE, "..", "..", "..", "tools", "upscalers"))

import fetch_bundle  # noqa: E402
from gamecove_upscale import downloads  # noqa: E402


def sha(b: bytes) -> str:
    return hashlib.sha256(b).hexdigest()


def _pins(tmp_path, monkeypatch):
    blobs = {n: (n + " bytes").encode() for n in ("opti.7z", "v10.7z", "patcher.asi", "fakenvapi.7z", "ref.zip", "xmx.zip", "amd.dll")}
    pins = {
        "optiscaler": {"version": "0.9.4", "asset": "opti.7z", "url": "https://github.com/optiscaler/OptiScaler/releases/download/v0.9.4/opti.7z",
                       "sha256": sha(blobs["opti.7z"]), "extras": [{"name": "OptiPatcher", "version": "r1", "url": "https://x/patcher.asi", "sha256": sha(blobs["patcher.asi"])}]},
        "optiscaler_v10": {"version": "10", "asset": "v10.7z", "url": "https://x/v10.7z", "sha256": sha(blobs["v10.7z"]),
                           "extras": [{"name": "OptiPatcher", "version": "r1", "url": "https://x/patcher.asi", "sha256": sha(blobs["patcher.asi"])},
                                      {"name": "fakenvapi", "version": "1.4.1", "url": "https://x/fakenvapi.7z", "sha256": sha(blobs["fakenvapi.7z"])}]},
        "reframework": {"version": "15", "asset": "ref.zip", "url": "https://x/ref.zip", "sha256": sha(blobs["ref.zip"])},
        "xess_xmx_linux": {"version": "20261104", "asset": "xmx.zip", "url": "https://x/xmx.zip", "sha256": sha(blobs["xmx.zip"])},
        "fsr4_amd": {"version": "sdk2.4.0", "base": "https://amd/signedbin", "files": {"amd_fidelityfx_upscaler_dx12.dll": sha(blobs["amd.dll"])}},
    }
    monkeypatch.setattr(fetch_bundle, "load_pins", lambda: pins)
    by_url = {"opti.7z": "opti.7z", "v10.7z": "v10.7z", "patcher.asi": "patcher.asi", "fakenvapi.7z": "fakenvapi.7z", "ref.zip": "ref.zip",
              "xmx.zip": "xmx.zip", "amd_fidelityfx_upscaler_dx12.dll": "amd.dll"}
    calls = []

    def fake(url, dest, timeout=60.0):
        calls.append(url)
        with open(dest, "wb") as f:
            f.write(blobs[by_url[url.rsplit("/", 1)[1]]])
        return dest
    monkeypatch.setattr(downloads, "download", fake)
    return pins, blobs, calls


def test_bundle_holds_every_redistributable_file_once(tmp_path, monkeypatch):
    pins, blobs, calls = _pins(tmp_path, monkeypatch)
    dest = tmp_path / "bin" / "upscalers"
    assert fetch_bundle.main([str(dest)]) == 0
    m = json.load(open(dest / "bundle.json"))["files"]
    assert {v["component"] for v in m.values()} == {"optiscaler", "optiscaler_v10", "optipatcher", "fakenvapi", "reframework", "xess_xmx_linux", "fsr4_amd"}
    assert len(m) == 7 and len(calls) == 7                           # OptiPatcher is in two packages, stored once
    for s, v in m.items():
        assert v["path"] == s and sha(open(dest / s, "rb").read()) == s and v["license"] and v["size"] > 0
    assert sorted(os.listdir(dest)) == sorted(list(m) + ["bundle.json"])
    assert fetch_bundle.main(["--check", str(dest)]) == 0
    assert fetch_bundle.main([str(dest)]) == 0 and len(calls) == 7   # a second run downloads nothing
    # nothing from NVIDIA, no driver DLL, no lsfg-vk, no XMX FSR build in here
    names = " ".join(v["name"].lower() for v in m.values())
    for never in ("nvngx", "amdxcffx", "lsfg", "lossless", "fsr-original"):
        assert never not in names


def test_amds_dll_isnt_stored_twice_next_to_the_xmx_set(tmp_path, monkeypatch):
    pins, blobs, calls = _pins(tmp_path, monkeypatch)
    fsr4 = tmp_path / "bin" / "fsr4-xmx"
    os.makedirs(fsr4)
    (fsr4 / "fsr-original.dll").write_bytes(blobs["amd.dll"])
    (fsr4 / "set.json").write_text(json.dumps({"version": "x", "files": {"fsr-original.dll": sha(blobs["amd.dll"]), "amd_fidelityfx_upscaler_dx12.dll": "0" * 64}}))
    dest = tmp_path / "bin" / "upscalers"
    assert fetch_bundle.main([str(dest), "--fsr4", str(fsr4)]) == 0
    m = json.load(open(dest / "bundle.json"))["files"]
    amd = m[sha(blobs["amd.dll"])]
    assert amd["path"] == os.path.join("..", "fsr4-xmx", "fsr-original.dll") and not (dest / sha(blobs["amd.dll"])).exists()
    assert len(calls) == 6 and fetch_bundle.main(["--check", str(dest)]) == 0
    # the release build passes a relative path (app/build/bin/upscalers): the shared file is still inside bin/
    monkeypatch.chdir(tmp_path)
    assert fetch_bundle.main(["--check", os.path.join("bin", "upscalers")]) == 0
    # but a path that leaves bin/ is refused
    m[sha(blobs["amd.dll"])]["path"] = os.path.join("..", "..", "elsewhere.dll")
    json.dump({"files": m}, open(dest / "bundle.json", "w"))
    assert fetch_bundle.main(["--check", os.path.join("bin", "upscalers")]) == 1
    m[sha(blobs["amd.dll"])]["path"] = os.path.join("..", "fsr4-xmx", "fsr-original.dll")
    json.dump({"files": m}, open(dest / "bundle.json", "w"))
    monkeypatch.setenv("GAMECOVE_BUNDLE", str(dest))
    assert downloads.bundled(sha(blobs["amd.dll"])) == str(fsr4 / "fsr-original.dll")


def test_check_refuses_wrong_missing_and_extra_files(tmp_path, monkeypatch):
    pins, blobs, _calls = _pins(tmp_path, monkeypatch)
    dest = tmp_path / "bin" / "upscalers"
    fetch_bundle.main([str(dest)])
    one = sha(blobs["ref.zip"])
    (dest / one).write_bytes(b"swapped")
    assert fetch_bundle.main(["--check", str(dest)]) == 1
    (dest / one).write_bytes(blobs["ref.zip"])
    (dest / "stray.dll").write_bytes(b"x")
    assert fetch_bundle.main(["--check", str(dest)]) == 1
    os.remove(dest / "stray.dll")
    os.remove(dest / one)
    assert fetch_bundle.main(["--check", str(dest)]) == 1
    assert fetch_bundle.main(["--check", str(tmp_path / "nothing")]) == 1


def test_the_helper_installs_from_the_bundle_without_the_network(tmp_path, monkeypatch):
    pins, blobs, calls = _pins(tmp_path, monkeypatch)
    dest = tmp_path / "bin" / "upscalers"
    fetch_bundle.main([str(dest)])
    calls.clear()
    monkeypatch.setenv("GAMECOVE_BUNDLE", str(dest))

    def offline(url, d, timeout=60.0):
        raise OSError("offline")
    monkeypatch.setattr(downloads, "download", offline)
    out = tmp_path / "got.7z"
    assert downloads.get_verified(["https://mirror/opti.7z"], pins["optiscaler"]["sha256"], str(out)) == str(out)
    assert out.read_bytes() == blobs["opti.7z"]
    assert downloads.get_verified([], pins["reframework"]["sha256"], str(out)) == str(out)       # no URL needed at all
    info = downloads.bundle_info()
    assert info["files"] == 7 and info["bytes"] == sum(len(b) for b in blobs.values())
    # not in the bundle: the network is asked (and here it is down)
    with pytest.raises(OSError):
        downloads.get_verified(["https://mirror/other"], "1" * 64, str(out))
    # a packaged copy with the wrong bytes is never used: the download decides
    (dest / pins["xess_xmx_linux"]["sha256"]).write_bytes(b"tampered")

    def online(url, d, timeout=60.0):
        with open(d, "wb") as f:
            f.write(blobs["xmx.zip"])
        return d
    monkeypatch.setattr(downloads, "download", online)
    assert downloads.get_verified(["https://mirror/xmx.zip"], pins["xess_xmx_linux"]["sha256"], str(out)) == str(out)
    assert out.read_bytes() == blobs["xmx.zip"]
    monkeypatch.delenv("GAMECOVE_BUNDLE")
    assert downloads.bundled(pins["optiscaler"]["sha256"]) is None and downloads.bundle_info() == {}


def test_real_pins_are_all_bundled_and_hash_pinned():
    items = fetch_bundle.items(fetch_bundle.load_pins())
    comps = {i["component"] for i in items}
    assert comps == {"optiscaler", "optiscaler_v10", "optipatcher", "fakenvapi", "reframework", "xess_xmx_linux", "fsr4_amd"}
    for i in items:
        assert len(i["sha256"]) == 64 and i["urls"] and all(u.startswith("https://") for u in i["urls"]), i
        assert i["component"] in fetch_bundle.LICENSES


# ---- one managed place: its size (Settings > Device > Storage) and the clean uninstall ----------------------------
from gamecove_upscale import best, cli, games, optiscaler, upkeep  # noqa: E402
from test_games import _accept, _pkg, _steam_game, _w  # noqa: E402

Z1E = {"vendor": "amd", "family": "amd-rdna3", "arch": "RDNA3", "chip": "AMD Ryzen Z1 Extreme"}


@pytest.fixture(autouse=True)
def _no_chown(monkeypatch):
    monkeypatch.setattr(optiscaler.userexec, "chown_tree", lambda p, h: None)


def _tree(d):
    out = {}
    for r, _d, f in os.walk(d):
        for x in f:
            out[os.path.relpath(os.path.join(r, x), d)] = sha(open(os.path.join(r, x), "rb").read())
    return out


def _set_up(home):
    _pkg(home)
    _w(os.path.join(home, optiscaler.FSR4_AMD_DIR, optiscaler.FSR4_AMD_FILE), "amd-sdk-4.1.2")
    d = _steam_game(home, "400", "DlssGame", ["DlssGame.exe", "nvngx_dlss.dll", "D3D12Core.dll"])
    before = _tree(d)
    assert best.opt_in(home, "400", Z1E)["did"] == "set up" and _tree(d) != before
    return d, before


def test_storage_says_what_upscaling_takes_and_in_how_many_games(tmp_path, monkeypatch):
    home = str(tmp_path / "home")
    assert cli.run(["storage", "--home", home]) == {"ok": True, "bytes": 0, "parts": [], "games": 0, "bundle_bytes": 0, "bundle_files": 0,
                                                    "folder": os.path.join(home, games.DATA)}
    _set_up(home)
    r = cli.run(["storage", "--home", home])
    names = {p["name"]: p["bytes"] for p in r["parts"]}
    assert r["ok"] and r["games"] == 1 and names["OptiScaler packages"] > 0 and names["FSR 4 (AMD)"] == len("amd-sdk-4.1.2")
    assert r["bytes"] == sum(names.values()) and "Launch settings" in names
    # what came inside the install is counted apart (read-only, it goes with the package)
    _pins(tmp_path, monkeypatch)
    dest = tmp_path / "bin" / "upscalers"
    fetch_bundle.main([str(dest)])
    monkeypatch.setenv("GAMECOVE_BUNDLE", str(dest))
    r2 = cli.run(["storage", "--home", home])
    assert r2["bundle_files"] == 7 and r2["bundle_bytes"] > 0 and r2["bytes"] == r["bytes"]


def test_native_and_a_purge_without_gpu_clear_frame_generation(tmp_path):
    """Review low: uninstall runs purge without --gpu; a game set to 3x frame generation on Intel made undo raise,
    and Native left XESS_FG=3 and GAMECOVE_XMX=1 in the launch file."""
    home = str(tmp_path / "home")
    _pkg(home)
    d = _steam_game(home, "480", "DlssGame", ["DlssGame.exe", "nvngx_dlss.dll", "D3D12Core.dll"])
    before = _tree(d)
    xmx = {"vendor": "intel", "family": "intel-xe2", "arch": "Xe2", "xmx": True}
    _accept(home, "480")
    assert games.choose(home, "480", "xess", 3, xmx)["ok"]
    env = os.path.join(home, ".local/share/gamecove/launch/480.env")
    assert "XESS_FG=3" in open(env).read()
    r = cli.run(["purge", "--home", home])                  # what the installer runs: no --gpu
    assert r["ok"] and "480" in r["games"] and _tree(d) == before and not os.path.exists(env)
    _pkg(home)                                              # purge took the package out with the managed folders
    _accept(home, "480")                                    # ...and the opt-in with the rest of the state
    assert games.choose(home, "480", "xess", 3, xmx)["ok"]
    assert best.native(home, "480", xmx)["ok"] and not os.path.exists(env)
    assert games.get_launch(home, "480").get("fg") is None


def test_purge_puts_every_game_back_and_deletes_the_managed_folders(tmp_path):
    home = str(tmp_path / "home")
    d, before = _set_up(home)
    _w(os.path.join(home, ".config/lsfg-vk/conf.toml"), "version = 2\n")           # the user's own: stays
    save = os.path.join(home, ".local/share/Steam/steamapps/compatdata/400/pfx/save.dat")
    _w(save, "save")
    r = cli.run(["purge", "--home", home, "--gpu", json.dumps(Z1E)])
    assert r["ok"] and r["games"] == ["400"] and not r["failed"], r
    assert _tree(d) == before                                                       # byte for byte as the game shipped
    for _name, rel in upkeep.MANAGED:
        assert not os.path.exists(os.path.join(home, rel)), rel
    assert not os.path.exists(os.path.join(home, games.STATE))
    assert os.path.isfile(save) and os.path.isfile(os.path.join(home, ".config/lsfg-vk/conf.toml"))
    assert cli.run(["purge", "--home", home, "--gpu", json.dumps(Z1E)])["ok"]       # a second run has nothing to do
    assert cli.run(["storage", "--home", home])["bytes"] == 0


def test_purge_keeps_fsr4_xmx_files_the_user_put_there(tmp_path):
    home = str(tmp_path / "home")
    for n in optiscaler.FSR4_XMX_FILES:
        _w(os.path.join(home, optiscaler.FSR4_XMX_DIR, n), "the user's own build of " + n)
    assert cli.run(["purge", "--home", home])["ok"]
    assert sorted(os.listdir(os.path.join(home, optiscaler.FSR4_XMX_DIR))) == sorted(optiscaler.FSR4_XMX_FILES)
    assert upkeep._our_fsr4_set(home) is False


# ---- where every FSR 4 file came from (data/fsr4_files.json) ------------------------------------------------------
def test_every_shipped_fsr4_file_has_its_provenance_and_matches_the_pins():
    from gamecove_upscale import chips
    root = os.path.join(HERE, "..", "..", "..")
    doc = json.load(open(os.path.join(HERE, "..", "gamecove_upscale", "data", "fsr4_files.json"), encoding="utf-8"))
    pins = fetch_bundle.load_pins()
    rows = doc["files"]
    # every pinned FSR 4 file has exactly one row, and no row names a file that isn't pinned
    pinned = {(c, n): s for c in ("fsr4_amd", "fsr4_xmx") for n, s in pins[c]["files"].items()}
    assert {(r["component"], r["file"]): r["sha256"] for r in rows} == pinned
    for r in rows:
        for k in ("what", "author", "source", "sha256", "date", "delivery", "why"):
            assert str(r[k]).strip(), (r["file"], k)
        assert r["source"].startswith("https://github.com/") and len(r["sha256"]) == 64 and r["size"] > 1 << 20
        assert r["date"][:4].isdigit() and len(r["date"]) == 10
        commit = re.search(r"/([0-9a-f]{40})(/|$)", pins["fsr4_amd" if r["official"] else "fsr4_xmx"]["base"]).group(1)
        assert commit in r["source"], (r["file"], "the source names the pinned commit")
        assert r["official"] is (r["author"].startswith("Advanced Micro Devices"))
        assert r["terms"] if r["official"] else r["terms"] == ""      # terms only where the author published some
    # every chip that is offered FSR 4 has a file, and the official one wherever it does the job
    covered = {t for r in rows for t in r["tiers"]}
    assert covered == set(chips.FSR4) | {"intel_xmx"}
    for t in chips.FSR4:
        assert [r["component"] for r in rows if t in r["tiers"]] == ["fsr4_amd"], t
    # the credit is in CREDITS.md, in plain words, and says nothing about anyone's say-so
    credits = open(os.path.join(root, "CREDITS.md"), encoding="utf-8").read()
    assert "FSR 4 on XMX** by nitec and the OptiScaler community" in credits and "AMD FSR SDK" in credits
    for path in ("CREDITS.md", "README.md", "docs/UPSCALING.md", "packaging/helpers/gamecove_upscale/data/fsr4_files.json",
                 "packaging/helpers/gamecove_upscale/data/versions.json", "tools/upscalers/fetch_fsr4.py"):
        text = open(os.path.join(root, path), encoding="utf-8").read().lower()
        for m in re.finditer("nitec", text):
            near = text[max(0, m.start() - 160): m.start() + 160]
            for word in ("permission", "allowed us", "'s ok", "consent", "agreed", "approved", "blessing", "authoris", "authoriz"):
                assert word not in near, (path, word)
    names = " ".join(str(n["what"]).lower() for n in doc["never_shipped"])
    assert "leaked" in names and "amdxcffx64" in names and "nvidia" in names
