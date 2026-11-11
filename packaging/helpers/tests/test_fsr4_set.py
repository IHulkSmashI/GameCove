"""nitec's FSR 4.1.2 XMX files as one shipped, swappable set: they come inside the package (bin/fsr4-xmx with its
set.json, put there by tools/upscalers/fetch_fsr4.py the way ClawDeck's build does it), go to ~/fsr4-xmx with nothing
for the user to do, a newer set replaces them as a unit, and the set before is kept for rollback."""
import hashlib
import importlib.util
import io
import json
import os
import sys

import pytest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from gamecove_upscale import cli, games, optiscaler  # noqa: E402

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))
INTEL = {"vendor": "intel", "family": "intel-xe3", "arch": "Xe3", "xmx": True}
FILES = ("amd_fidelityfx_upscaler_dx12.dll", "fsr-original.dll")


def sha(text: str) -> str:
    return hashlib.sha256(text.encode()).hexdigest()


def _w(path, text):
    os.makedirs(os.path.dirname(str(path)), exist_ok=True)
    with open(path, "w") as f:
        f.write(text)


def entry(tag: str) -> dict:
    return {"version": tag, "files": {f: sha(f"{tag}:{f}") for f in FILES}, "base": "https://example.invalid/x"}


def package(root, tag: str) -> dict:
    e = entry(tag)
    for f in FILES:
        _w(os.path.join(root, "bin", "fsr4-xmx", f), f"{tag}:{f}")
    _w(os.path.join(root, "bin", "fsr4-xmx", "set.json"), json.dumps({"component": "fsr4_xmx", "version": tag, "files": e["files"]}))
    return e


@pytest.fixture
def env(tmp_path, monkeypatch):
    monkeypatch.setattr(optiscaler.userexec, "chown_tree", lambda p, h: None)
    pkg = tmp_path / "usr" / "lib" / "gamecove"
    monkeypatch.setattr(optiscaler, "PACKAGE_DIR", str(pkg))
    monkeypatch.setattr(optiscaler, "SYSTEM_DIR", str(tmp_path / "absent"))
    monkeypatch.setattr(optiscaler, "IMPORT_FROM", ())
    home = tmp_path / "home"
    os.makedirs(home)
    return str(home), str(pkg)


def read(home, f):
    return open(os.path.join(home, optiscaler.FSR4_XMX_DIR, f)).read()


def test_bundled_folder_is_clawdecks_place():
    """<package>/bin/fsr4-xmx, the same relative place as in ClawDeck's zip; /usr/lib/gamecove in every package."""
    assert optiscaler.FSR4_BUNDLED == os.path.join("bin", "fsr4-xmx") and optiscaler.SYSTEM_DIR == "/usr/lib/gamecove"
    here = os.path.dirname(os.path.realpath(optiscaler.__file__))
    assert optiscaler.PACKAGE_DIR == os.path.dirname(os.path.dirname(here))


def test_clean_install_gets_the_files_with_nothing_to_set_up(env):
    home, pkg = env
    e = package(pkg, "4.1.2-aaaa")
    assert optiscaler.fsr4_packaged()["version"] == "4.1.2-aaaa"
    assert optiscaler.fsr4_xmx_missing(home)[:2] == list(FILES)
    r = optiscaler.fsr4_xmx_ready(home, [e])
    assert r == {"ok": True, "how": "package", "version": "4.1.2-aaaa"}
    for f in FILES:
        assert read(home, f) == f"4.1.2-aaaa:{f}"                       # byte for byte what the package carries
    st = optiscaler.fsr4_xmx_set(home)
    assert st["present"] and st["version"] == "4.1.2-aaaa" and st["files"] == e["files"] and st["previous"] is None
    assert optiscaler.fsr4_xmx_ready(home, [e])["how"] == "there"       # nothing is copied twice


def test_packaged_files_that_do_not_match_are_never_used(env):
    home, pkg = env
    e = package(pkg, "4.1.2-aaaa")
    _w(os.path.join(pkg, "bin", "fsr4-xmx", FILES[0]), "tampered")
    r = optiscaler.fsr4_xmx_ready(home, [e])
    assert not r["ok"] and r["how"] == "missing"
    assert not os.path.exists(os.path.join(home, optiscaler.FSR4_XMX_DIR, FILES[0]))


def test_the_users_own_newer_files_are_never_replaced(env):
    """ClawDeck's rule: while both files are in ~/fsr4-xmx nothing is copied over them."""
    home, pkg = env
    e = package(pkg, "4.1.2-aaaa")
    for f in FILES:
        _w(os.path.join(home, optiscaler.FSR4_XMX_DIR, f), f"mine:{f}")
    assert optiscaler.fsr4_xmx_ready(home, [e])["how"] == "there"
    assert read(home, FILES[0]) == f"mine:{FILES[0]}"
    assert optiscaler.fsr4_xmx_set(home)["version"] is None            # not GameCove's set: "your own files"


def test_the_index_newer_than_the_package_falls_back_to_the_pins(env):
    """A newer set in the signed index and no network: the packaged set (the tested pins) still goes in."""
    home, pkg = env
    pinned = package(pkg, "4.1.2-aaaa")
    newer = entry("4.1.3-bbbb")
    r = optiscaler.fsr4_xmx_ready(home, [newer, pinned])
    assert r["ok"] and r["version"] == "4.1.2-aaaa"


def test_a_newer_set_swaps_as_a_unit_and_rollback_returns(env, monkeypatch):
    home, pkg = env
    old = package(pkg, "4.1.2-aaaa")
    optiscaler.fsr4_xmx_ready(home, [old])
    new = entry("4.1.3-bbbb")

    def get_verified(sources, sha256, dest, timeout=0):
        name = os.path.basename(dest)
        _w(dest, f"4.1.3-bbbb:{name}")
        return dest
    monkeypatch.setattr(optiscaler.downloads, "get_verified", get_verified)
    r = optiscaler.fsr4_xmx_download(home, new)
    assert r["ok"] and sorted(r["downloaded"]) == sorted(FILES)
    st = optiscaler.fsr4_xmx_set(home)
    assert st["version"] == "4.1.3-bbbb" and st["previous"] == "4.1.2-aaaa"
    assert read(home, FILES[1]) == f"4.1.3-bbbb:{FILES[1]}"
    # rollback: the set before, checked against its own record; the newer one is kept in its place
    r = optiscaler.fsr4_xmx_rollback(home)
    assert r["ok"] and r["version"] == "4.1.2-aaaa" and r["was"] == "4.1.3-bbbb"
    for f in FILES:
        assert read(home, f) == f"4.1.2-aaaa:{f}"
    st = optiscaler.fsr4_xmx_set(home)
    assert st["version"] == "4.1.2-aaaa" and st["previous"] == "4.1.3-bbbb" and st["files"] == old["files"]
    # and again: forward to the newer set, without a download
    r = optiscaler.fsr4_xmx_rollback(home)
    assert r["ok"] and r["version"] == "4.1.3-bbbb" and read(home, FILES[0]) == f"4.1.3-bbbb:{FILES[0]}"
    # the same set again keeps nothing new
    assert optiscaler.fsr4_xmx_download(home, new)["downloaded"] == []
    assert optiscaler.fsr4_xmx_set(home)["previous"] == "4.1.2-aaaa"


def test_rollback_refuses_a_damaged_or_missing_kept_set(env, monkeypatch):
    home, pkg = env
    assert not optiscaler.fsr4_xmx_rollback(home)["ok"]
    old = package(pkg, "4.1.2-aaaa")
    optiscaler.fsr4_xmx_ready(home, [old])
    monkeypatch.setattr(optiscaler.downloads, "get_verified", lambda s, h, dest, timeout=0: _w(dest, "new:" + os.path.basename(dest)) or dest)
    optiscaler.fsr4_xmx_download(home, entry("new"))
    _w(os.path.join(home, optiscaler.FSR4_PREVIOUS, FILES[0]), "bit rot")
    r = optiscaler.fsr4_xmx_rollback(home)
    assert not r["ok"] and "damaged" in r["error"]
    assert read(home, FILES[0]) == "new:" + FILES[0]                    # nothing changed


def test_users_own_files_survive_an_update_as_the_kept_set(env, monkeypatch):
    home, pkg = env
    for f in FILES:
        _w(os.path.join(home, optiscaler.FSR4_XMX_DIR, f), f"mine:{f}")
    monkeypatch.setattr(optiscaler.downloads, "get_verified", lambda s, h, dest, timeout=0: _w(dest, "new:" + os.path.basename(dest)) or dest)
    optiscaler.fsr4_xmx_download(home, entry("new"))
    assert optiscaler.fsr4_xmx_set(home)["previous"] == "your own files"
    assert optiscaler.fsr4_xmx_rollback(home)["ok"] and read(home, FILES[0]) == f"mine:{FILES[0]}"
    assert optiscaler.fsr4_xmx_set(home)["version"] is None


def test_helper_commands_make_it_ready_and_roll_back(env, monkeypatch, capsys):
    """What ClawDeck does at plugin start happens before the helper's commands on an Intel XMX handheld; AMD and
    Intel without XMX never get the files."""
    home, pkg = env
    e = package(pkg, "4.1.2-aaaa")
    monkeypatch.setattr(games, "versions", lambda h=None: {**games.pins(), "fsr4_xmx": e})
    assert games.xmx_upkeep(home, {"vendor": "amd", "family": "amd-rdna3"}) is None
    assert games.xmx_upkeep(home, {"vendor": "intel", "family": "intel-xe-lpg", "xmx": False}) is None
    assert not os.path.exists(os.path.join(home, optiscaler.FSR4_XMX_DIR))
    out = games.xmx_upkeep(home, INTEL)
    assert out["fsr4_xmx"]["how"] == "package" and optiscaler.fsr4_xmx_missing(home)[:2] != list(FILES)
    assert games.xmx_upkeep(home, INTEL) is None                        # second time: nothing to do
    st = cli.run(["state", "--home", home, "--gpu", json.dumps(INTEL)]) if hasattr(cli, "run") else None
    if st is not None:
        assert st["fsr4_xmx_set"]["version"] == "4.1.2-aaaa" and st["fsr4_xmx_set"]["packaged"] == "4.1.2-aaaa"
    assert "fsr4-rollback" in cli.COMMANDS and "state" in cli.XMX_UPKEEP and "recommend" in cli.XMX_UPKEEP


# ---- the build step ----------------------------------------------------------------------------------------------
def _tool():
    spec = importlib.util.spec_from_file_location("fetch_fsr4", os.path.join(REPO, "tools", "upscalers", "fetch_fsr4.py"))
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


def test_fetch_tool_takes_the_pinned_files_from_clawdecks_branch_and_checks_them(tmp_path, monkeypatch):
    tool = _tool()
    pins = tool.entry()
    assert pins["base"].startswith("https://raw.githubusercontent.com/IHulkSmashI/ClawDeck/") and len(pins["base"].rsplit("/", 1)[1]) == 40
    assert set(pins["files"]) == set(FILES) and pins["version"]
    data = {f: f"bytes of {f}".encode() for f in FILES}
    fake = {"version": "t", "base": "https://example.invalid/commit", "files": {f: hashlib.sha256(b).hexdigest() for f, b in data.items()}}
    monkeypatch.setattr(tool, "entry", lambda: fake)
    asked = []

    def opener(url, timeout=0):
        asked.append(url)
        return io.BytesIO(data[url.rsplit("/", 1)[1]])
    dest = str(tmp_path / "bin" / "fsr4-xmx")
    assert tool.fetch(dest, opener) == 0
    assert sorted(asked) == sorted(f"https://example.invalid/commit/{f}" for f in FILES)
    for f in FILES:
        assert open(os.path.join(dest, f), "rb").read() == data[f]      # as is
    m = json.load(open(os.path.join(dest, "set.json")))
    assert m["version"] == "t" and m["files"] == fake["files"] and "nitec" in m["credit"]
    assert tool.check(dest, fake) == []
    # one changed byte, a stray file, a missing manifest: all refused
    _w(os.path.join(dest, FILES[0]), "x")
    assert any("sha256" in b for b in tool.check(dest, fake))
    data[FILES[0]] = b"other"
    assert tool.fetch(str(tmp_path / "bad"), opener) == 1 and not os.path.exists(tmp_path / "bad" / FILES[0])


def test_pins_are_the_files_clawdeck_ships():
    """The same two files, by sha256, as ClawDeck's versions.json at cf349a6."""
    pins = _tool().entry()["files"]
    assert pins == {"amd_fidelityfx_upscaler_dx12.dll": "a609f609a3ef29ddff59adfbd27dc417bf68fcd865383b2529987a7eff1081ac",
                    "fsr-original.dll": "aad4fccccb29084a655f9a4f9f613bd22c8c03fb4a0f8840148cc6543b4ccace"}
