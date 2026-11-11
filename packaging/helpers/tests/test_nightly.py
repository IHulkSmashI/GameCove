"""The nightly's new parts and what devices do with them: the smoke check (PE headers, exports, ini generation), the
upstream watch (what moved, what changed shape), the per-game list in the signed index, withdrawals (the kill
switch), rollback after a failed self-check, the game-list generator, and lsfg-vk's install (only next to the
user's own Lossless Scaling). Nothing touches the network."""
import hashlib
import io
import json
import os
import struct
import subprocess
import sys
import tarfile

import pytest

HERE = os.path.dirname(__file__)
sys.path.insert(0, os.path.join(HERE, ".."))
sys.path.insert(0, os.path.join(HERE, "..", "..", "..", "tools", "upscalers"))

import build  # noqa: E402
import check_plan  # noqa: E402
import smoke  # noqa: E402
import watch  # noqa: E402
from gamecove_upscale import best, cli, downloads, games, launchenv, livedb, lsfg, mirror, optiscaler, selfcheck, upkeep  # noqa: E402
from test_games import _pkg, _steam_game, _w  # noqa: E402
from test_upscalers_build import _run, world  # noqa: E402

XMX = {"vendor": "intel", "family": "intel-xe3", "arch": "Xe3", "xmx": True}
Z1E = {"vendor": "amd", "family": "amd-rdna3", "arch": "RDNA3", "chip": "AMD Ryzen Z1 Extreme"}
REAL_INI = os.path.join(HERE, "fixtures", "OptiScaler-0.9.4.keys.ini")


@pytest.fixture(autouse=True)
def _no_chown(monkeypatch):
    monkeypatch.setattr(optiscaler.userexec, "chown_tree", lambda p, h: None)


def pe(exports=(), imports=(), machine=0x8664, dll=True, magic=0x20B) -> bytes:
    """A minimal PE32+ image with an export and an import table (one section)."""
    sec_rva, sec_off = 0x1000, 0x200
    body = bytearray()

    def put(b: bytes) -> int:
        o = len(body)
        body.extend(b)
        return sec_rva + o

    names = [put(n.encode() + b"\0") for n in exports]
    name_table = put(b"".join(struct.pack("<I", r) for r in names))
    exp = put(struct.pack("<IIHHIIIIIII", 0, 0, 0, 0, 0, 1, len(names), len(names), 0, name_table, 0)) if exports else 0
    imp_names = [put(n.encode() + b"\0") for n in imports]
    imp = put(b"".join(struct.pack("<IIIII", 0, 0, 0, r, 0) for r in imp_names) + b"\0" * 20) if imports else 0
    opt = struct.pack("<H", magic) + b"\0" * 110 + struct.pack("<II", exp, 0x28 if exp else 0) + struct.pack("<II", imp, 0x28 if imp else 0) + b"\0" * (14 * 8)
    coff = struct.pack("<HHIIIHH", machine, 1, 0, 0, 0, len(opt), 0x2022 if dll else 0x0022)
    sec = b".rdata\0\0" + struct.pack("<IIII", len(body), sec_rva, len(body), sec_off) + b"\0" * 16
    head = b"MZ" + b"\0" * 0x3A + struct.pack("<I", 0x40) + b"PE\0\0" + coff + opt + sec
    return head.ljust(sec_off, b"\0") + bytes(body)


FFX = sorted(smoke.FFX_EXPORTS)


# ---- smoke check ----------------------------------------------------------------------------------------------------
def test_pe_reader_finds_machine_exports_and_imports(tmp_path):
    p = tmp_path / "a.dll"
    p.write_bytes(pe(FFX, ["KERNEL32.dll", "Cabinet.dll"]))
    info = selfcheck.pe_info(str(p))
    assert info["machine"] == 0x8664 and info["dll"] and info["exports"] == set(FFX)
    assert info["imports"] == {"kernel32.dll", "cabinet.dll"}
    for bad, why in ((b"not a dll at all" * 10, "MZ"), (pe(magic=0x10B), "64-bit")):
        p.write_bytes(bad)
        with pytest.raises(ValueError, match=why):
            selfcheck.pe_info(str(p))


def test_smoke_refuses_a_build_that_changed_shape(tmp_path):
    p = tmp_path / "x.dll"
    rule = smoke.PE_RULES["fsr4_xmx"]["amd_fidelityfx_upscaler_dx12.dll"]
    p.write_bytes(pe(FFX, ["Cabinet.dll"]))
    assert smoke.check_pe(str(p), rule, "fsr4_xmx") == []
    p.write_bytes(pe(FFX, ["KERNEL32.dll"]))                         # no longer unpacks with Cabinet.dll
    assert "no longer imports cabinet.dll" in smoke.check_pe(str(p), rule, "fsr4_xmx")[0]
    p.write_bytes(pe(FFX[:3], ["Cabinet.dll"]))
    assert "exports gone" in smoke.check_pe(str(p), rule, "fsr4_xmx")[0]
    p.write_bytes(pe(FFX, ["Cabinet.dll"], machine=0x14C))
    assert "not a 64-bit Windows DLL" in smoke.check_pe(str(p), rule, "x")[0]
    p.write_bytes(b"<html>404</html>")
    assert smoke.check_pe(str(p), rule, "x") == ["x: not an MZ executable"]


def test_every_setting_we_write_exists_in_the_pinned_optiscaler_ini():
    """The OptiScaler.ini of the pinned 0.9.4 (its section and key names, kept as a fixture): every preset and frame
    generation choice GameCove writes is a key that version reads."""
    text = open(REAL_INI, encoding="utf-8").read()
    assert len(selfcheck.ini_keys(text)) > 250
    assert selfcheck.check_ini(text) == []
    cases = selfcheck.every_setting()
    assert len(cases) >= 28 and any("fsr4_amd" in c and "xefg" in c for c in cases)
    # an upstream that renames a key is caught, with the case that needs it
    renamed = text.replace("Fsr4ForceEnableInt8=", "Fsr4GpuSupport=")
    out = selfcheck.check_ini(renamed)
    assert out and "FSR_Fsr4ForceEnableInt8" in out[0] and "amd fsr4_amd" in out[0]
    assert selfcheck.check_ini("[Upscalers]\nDx12Upscaler=auto\n") == ["OptiScaler.ini: fewer than 50 settings found (the file changed shape)"]


def test_smoke_runs_over_a_build(tmp_path, monkeypatch):
    v, net = world()
    _rep, idx, _plan, out = _run(tmp_path, v, net)
    monkeypatch.setattr(smoke, "_7z", lambda archive, dest, names: (_w(os.path.join(dest, "OptiScaler.dll"), ""),
                                                                    open(os.path.join(dest, "OptiScaler.dll"), "wb").write(pe()),
                                                                    _w(os.path.join(dest, "OptiScaler.ini"), open(REAL_INI).read())))
    problems = smoke.run(str(out))
    # the test world's FSR files are text, not libraries: exactly those are reported, the OptiScaler archive passes
    assert problems and all("not an MZ executable" in p for p in problems), problems
    assert not any(p.startswith("optiscaler") for p in problems)
    assert smoke.main([str(out), "--report", str(tmp_path / "s.json")]) == 1
    assert json.load(open(tmp_path / "s.json"))["problems"] == problems


def test_generated_game_list_passes_the_smoke_check():
    assert smoke.check_games(games.BUNDLED_GAMES) == []


# ---- the upstream watch ---------------------------------------------------------------------------------------------
class WatchNet:
    def __init__(self, tags="v3.0.2", release="GE-Proton11-12", sha="a" * 40, lsfg="lsfg-vk-2.0.0.tar.xz", down=()):
        self.tags, self.release, self.sha, self.lsfg, self.down = tags, release, sha, lsfg, down

    def get(self, url):
        if any(d in url for d in self.down):
            raise OSError("HTTP 404")
        if url == watch.LSFG_BUILDS:
            return f'<a href="{self.lsfg}">&gt;&gt; Latest release (2.0.0) &lt;&lt;</a>'.encode()
        if url.endswith("/tags?per_page=30"):
            return json.dumps([{"name": self.tags}, {"name": "older"}]).encode()
        if url.endswith("/releases/latest"):
            return json.dumps({"tag_name": self.release}).encode()
        return json.dumps({"sha": self.sha}).encode()


def test_watch_says_what_moved_and_what_cant_be_read():
    first = watch.watch(WatchNet(), None)
    assert first["changed"] == [] and first["failed"] == [] and set(first["seen"]) == set(watch.WATCHED)
    assert watch.markdown(first) == ""                               # first run, nothing moved: no issue
    assert watch.watch(WatchNet(), first)["changed"] == []
    second = watch.watch(WatchNet(tags="v3.1.0", sha="b" * 40, lsfg="lsfg-vk-2.1.0.tar.xz", down=("Decky-Framegen",)), first)
    moved = {c["id"]: c for c in second["changed"]}
    assert moved["intel_xess"]["now"] == "v3.1.0" and moved["amd_fsr_sdk"]["was"] == "v3.0.2"
    assert moved["fsr4_xmx_drop"]["now"] == "b" * 12 and moved["lsfg_vk"]["now"] == "lsfg-vk-2.1.0.tar.xz"
    assert [f["id"] for f in second["failed"]] == ["decky_framegen"]
    assert second["seen"]["decky_framegen"] == first["seen"]["decky_framegen"]      # kept, so it isn't "new" tomorrow
    text = watch.markdown(second, {"warnings": ["optiscaler: ValueError: no asset; kept 0.9.4"]}, {"problems": ["fsr4_amd: exports gone"]})
    for want in ("Upstreams that moved", "intel/xess", "test it on a Claw", "Couldn't read", "Decky-Framegen",
                 "kept older entries", "Smoke check failed"):
        assert want in text, want


def test_watch_covers_every_upstream_the_owner_named():
    where = " ".join(w for _k, w, _y in watch.WATCHED.values())
    for upstream in ("intel/xess", "FidelityFX-SDK", "dlssg-to-fsr3", "REFramework", "xess-xmx-linux", "fsr4-xmx-files",
                     "proton-cachyos", "proton-ge-custom", "ValveSoftware/Proton", "lsfg-vk", "Decky-Framegen", "decky-lsfg-vk"):
        assert upstream in where, upstream
    for mirrored in ("optiscaler", "optiscaler_v10", "optipatcher", "fakenvapi", "xess_xmx_linux", "reframework", "fsr4_amd", "fsr4_xmx"):
        assert mirrored in build.SOURCES
    assert build.MIN_AGE_H == 72


def test_watch_cli_writes_state_and_issue(tmp_path, monkeypatch):
    monkeypatch.setattr(watch, "Net", lambda token="": WatchNet(release="GE-Proton11-13"))
    prev = tmp_path / "prev.json"
    prev.write_text(json.dumps({"seen": {"proton_ge": "GE-Proton11-12"}}))
    assert watch.main(["--previous", str(prev), "--out", str(tmp_path / "w.json"), "--issue", str(tmp_path / "issue.md")]) == 0
    assert json.load(open(tmp_path / "w.json"))["seen"]["proton_ge"] == "GE-Proton11-13"
    assert "GE-Proton11-12" in open(tmp_path / "issue.md").read()
    monkeypatch.setattr(watch, "Net", lambda token="": WatchNet(release="GE-Proton11-13"))
    assert watch.main(["--previous", str(tmp_path / "w.json"), "--out", str(tmp_path / "w2.json"), "--issue", str(tmp_path / "i2.md")]) == 0
    assert open(tmp_path / "i2.md").read() == ""                     # nothing moved: no issue


# ---- the per-game list in the signed index ------------------------------------------------------------------------
def _games_file(tmp_path, generated="2026-11-10T04:00:00Z", extra=None):
    doc = json.load(open(games.BUNDLED_GAMES))
    doc["generated"] = generated
    if extra:
        doc["games"].append(extra)
    p = tmp_path / "games-new.json"
    p.write_text(json.dumps(doc))
    return str(p)


def _build_with_games(tmp_path, gfile, name="dist", previous=None, withdrawn=None):
    v, net = world()
    vp = tmp_path / "versions.json"
    vp.write_text(json.dumps(v))
    (tmp_path / "games.json").write_bytes(open(games.BUNDLED_GAMES, "rb").read())
    wp = tmp_path / "withdrawn.json"
    wp.write_text(json.dumps({"withdrawn": withdrawn or {}}))
    out = tmp_path / name
    rep = build.build(net, str(vp), str(out), None, previous, now="2026-11-10T05:41:00Z", games=gfile, withdrawn_path=str(wp))
    return rep, mirror.parse((out / "upscalers.json").read_bytes()), out, vp


def test_a_new_game_list_rides_in_the_signed_index(tmp_path):
    new = {"id": "new-game", "name": "New Game", "exes": ["newgame.exe"], "ue_exes": [], "ini": {"Spoofing_Dxgi": "false"},
           "when": {}, "quirks": [], "later": {}, "source": "optiscaler"}
    gfile = _games_file(tmp_path, extra=new)
    rep, idx, out, vp = _build_with_games(tmp_path, gfile)
    e = mirror.data_entry(idx, "games")
    assert e and e["sha256"] == hashlib.sha256(open(gfile, "rb").read()).hexdigest() and e["version"] == "20261110040000"
    assert mirror.is_mirror_url(e["mirror_url"]) and "games-20261110040000-" in e["mirror_url"]
    assert any(n.startswith("games-") for _t, n, _p in (ln.split("\t") for ln in (out / "upload-plan.tsv").read_text().splitlines()))
    assert check_plan.check(str(out), str(vp)) == []                 # the publish job accepts it, by its hash
    assert rep["components"]["games (data)"] == "20261110040000"
    # the same list as the package's (only the timestamp differs): nothing published
    _rep2, idx2, _o, _v = _build_with_games(tmp_path, _games_file(tmp_path, "2026-11-11T04:00:00Z"), "dist2")
    assert mirror.data_entry(idx2, "games") is None
    # a list of another shape is refused, last night's entry kept
    bad = tmp_path / "bad.json"
    bad.write_text(json.dumps({"schema": 9, "games": []}))
    rep3, idx3, _o, _v = _build_with_games(tmp_path, str(bad), "dist3", previous=str(out / "upscalers.json"))
    assert mirror.data_entry(idx3, "games") == e and any("games:" in w for w in rep3["warnings"])


def test_devices_take_the_signed_list_and_only_that(tmp_path, monkeypatch):
    home = str(tmp_path)
    new = {"id": "new-game", "name": "New Game", "exes": ["newgame.exe"], "ue_exes": [], "ini": {}, "when": {}, "quirks": [],
           "later": {}, "source": "optiscaler", "anticheat": True}
    raw = open(_games_file(tmp_path, "2027-01-01T00:00:00Z", new), "rb").read()
    entry = {"version": "20270101000000", "sha256": hashlib.sha256(raw).hexdigest(), "size": len(raw),
             "mirror_url": mirror.mirror_url(mirror.mirror_name("games", "20270101000000", hashlib.sha256(raw).hexdigest(), "games.json"))}
    monkeypatch.setattr(mirror, "load", lambda h, now=None: {"data": {"games": entry}})
    monkeypatch.setattr(mirror, "refresh", lambda h, **k: {})
    monkeypatch.setattr(mirror, "_fetch", lambda url, limit, timeout: raw if url == entry["mirror_url"] else b"")
    monkeypatch.setattr(livedb, "_get", lambda url, timeout=20.0: b"")
    out = cli.run(["refresh", "--home", home])
    assert out["lists"]["games"] == "updated"
    assert games.games_path(home).startswith(os.path.join(home, games.LISTS))
    # a new game arrived without an app update, and its anti-cheat flag is honoured at once
    d = _steam_game(home, "700", "NewGame", ["NewGame.exe", "nvngx_dlss.dll", "D3D12Core.dll"])
    _pkg(home)
    p = best.plan(home, "700", Z1E)
    assert p["known"] and p["refused"] == "anticheat"
    # tampered on the way: refused, the list on the device stays
    monkeypatch.setattr(mirror, "_fetch", lambda url, limit, timeout: raw[:-1] + b" ")
    assert "error" in livedb.refresh(os.path.join(home, games.LISTS), games.BUNDLED_GAMES, force=True,
                                     signed=lambda: mirror.fetch_data(home, "games"))["games"]
    for bad in ({**entry, "mirror_url": "https://example.com/games.json"}, {**entry, "sha256": "zz"}, {**entry, "size": 0}):
        assert mirror.data_entry({"data": {"games": bad}}) is None
    assert d


# ---- withdrawals ----------------------------------------------------------------------------------------------------
def test_a_withdrawn_component_is_named_in_the_index(tmp_path):
    rep, idx, _out, _vp = _build_with_games(tmp_path, None, withdrawn={"fsr4_xmx": "asked by its author", "not_a_component": "x"})
    assert idx["withdrawn"] == {"fsr4_xmx": "asked by its author"}
    assert any("withdrawn" in w for w in rep["warnings"])
    assert json.load(open(build.WITHDRAWN))["withdrawn"] == {}       # nothing is withdrawn in the repository


def test_withdrawn_files_leave_games_and_arent_offered(tmp_path, monkeypatch):
    home = str(tmp_path)
    _pkg(home)
    _w(os.path.join(home, optiscaler.FSR4_AMD_DIR, optiscaler.FSR4_AMD_FILE), "amd-sdk-4.1.2")
    d = _steam_game(home, "710", "DlssGame", ["DlssGame.exe", "nvngx_dlss.dll", "D3D12Core.dll"])
    assert best.opt_in(home, "710", Z1E)["did"] == "set up"
    assert open(os.path.join(d, "amd_fidelityfx_upscaler_dx12.dll")).read() == "amd-sdk-4.1.2"
    assert mirror.withdrawn(home) == {}                              # no verified index: nothing is withdrawn
    monkeypatch.setattr(mirror, "load", lambda h, now=None: {"withdrawn": {"fsr4_amd": "pulled for now", "bogus": "x"}})
    assert mirror.withdrawn(home) == {"fsr4_amd": "pulled for now"}
    assert games.offered(home, Z1E) == ["own", "fsr31"]
    r = games.choose(home, "710", "fsr4_amd", 0, Z1E)
    assert r["ok"] is False and r["withdrawn"] == "fsr4_amd" and "pulled for now" in r["error"]
    r = best.prepare(home, "710", Z1E)                               # the next look takes it out of the game
    assert "taken out of GameCove" in r["did"] and "FSR 3.1" in r["did"]
    assert open(os.path.join(d, "amd_fidelityfx_upscaler_dx12.dll")).read() == "pkg-fsr"
    assert "Fsr4Update" not in open(os.path.join(d, "OptiScaler.ini")).read().replace("Fsr4Update=auto", "")
    assert best.plan(home, "710", Z1E)["upscaler"] == "fsr31"        # and Best no longer picks it
    best.set_mode(home, "710", "custom")                             # also for a game the user set up by hand
    monkeypatch.setattr(mirror, "load", lambda h, now=None: {})
    assert games.choose(home, "710", "fsr4_amd", 0, Z1E)["ok"]
    monkeypatch.setattr(mirror, "load", lambda h, now=None: {"withdrawn": {"fsr4_amd": "pulled"}})
    assert "taken out" in best.prepare(home, "710", Z1E)["did"]


# ---- rollback after a failed self-check ----------------------------------------------------------------------------
@pytest.mark.selfcheck
def test_a_package_that_fails_its_check_is_rolled_back(tmp_path):
    home = str(tmp_path)
    good = _pkg(home, "0.9.4")
    open(os.path.join(good, "OptiScaler.dll"), "wb").write(pe())
    _w(os.path.join(good, "OptiScaler.ini"), open(REAL_INI).read())
    assert selfcheck.package(good) == []
    bad = _pkg(home, "0.9.5")                                        # a text file as the DLL, a three-line ini
    e = {"version": "0.9.5", "layout": "flat"}
    r = upkeep._checked(home, e, {"ok": True})
    assert r["ok"] is False and r["rolled_back"] and "kept the one before" in r["error"]
    assert not os.path.exists(bad) and os.path.isdir(good)           # the device is back on what worked
    assert games.load_state(home)["bad_versions"] == ["0.9.5"]
    assert upkeep._checked(home, {"version": "0.9.4"}, {"ok": True}) == {"ok": True}


def test_a_bad_version_is_never_used_for_new_games(tmp_path, monkeypatch):
    home = str(tmp_path)
    newer = games.pins()
    newer["optiscaler"] = {**newer["optiscaler"], "version": "0.9.5"}
    monkeypatch.setattr(games, "versions", lambda h=None: newer)
    assert games._opti_entry({}, home)["version"] == "0.9.5"
    s = games.load_state(home)
    s["bad_versions"] = ["0.9.5"]
    games.save_state(home, s)
    assert games._opti_entry({}, home)["version"] == games.pins()["optiscaler"]["version"]


# ---- the generator --------------------------------------------------------------------------------------------------
def test_gen_games_from_optiscaler_sources_and_wiki(tmp_path):
    src = tmp_path / "opti" / "OptiScaler"
    _w(src / "Config.cpp", 'DxgiSpoofing.set_from_config(readBool("Spoofing", "Dxgi"));\n'
                           'RestoreComputeSignature.set_from_config(readBool("Hotfix", "RestoreComputeSignature"));\n')
    cfg = open(os.path.join(HERE, "fixtures", "GameConfigs.sample.cpp")).read()
    _w(src / "misc" / "GameConfigs.cpp", cfg)
    wiki = tmp_path / "wiki"
    _w(wiki / "Compatibility-List.md", "| Game | Compatibility | Upscaler <br>Inputs | OptiPatcher | Notes | Images |\n| ---- | :--: | :--: | :--: | ----- | :--: |\n"
       "| [Enshrouded](Enshrouded) | ✅ | DLSS, FSR3 | ✨ | Vulkan game | |\n"
       "| Online Shooter | ❌ | DLSS |  | Anti-cheat blocks it | |\n"
       "| Solo Game | ✅ | XeSS |  | Make sure **EAC** is disabled. | |\n")
    _w(wiki / "Enshrouded.asciidoc", "|===\n|**Filename**\n|`winmm.dll`, `dbghelp.dll`\n\n|**OS**\n|W11\n\n|**Known Issues**\na|\n* Needs Vulkan spoofing\n\n|===\n")
    ini = tmp_path / "OptiScaler.ini"
    ini.write_text("[Spoofing]\nDxgi=auto\n[Hotfix]\nRestoreComputeSignature=auto\n")
    extra = tmp_path / "extra.json"
    extra.write_text(json.dumps({"re_engine_exes": ["dd2.exe"], "capcom": {"tested": {}}, "games": {}}))
    out = tmp_path / "games.json"
    r = subprocess.run([sys.executable, os.path.join(HERE, "..", "..", "..", "tools", "upscalers", "gen_games.py"),
                        "--optiscaler", str(tmp_path / "opti"), "--wiki", str(wiki), "--ini", str(ini), "--ini-version", "0.9.4",
                        "--extra", str(extra), "--out", str(out), "--commit", "abc1234", "--generated", "2026-11-10T00:00:00Z"],
                       capture_output=True, text=True, timeout=120, check=False)
    assert r.returncode == 0, r.stderr
    doc = json.load(open(out))
    assert doc["schema"] == 2 and doc["generated"] == "2026-11-10T00:00:00Z" and doc["re_engine_exes"] == ["dd2.exe"]
    assert doc["games"], r.stderr
    c = doc["compat"]
    assert c["enshrouded"]["proxies"] == ["winmm.dll", "dbghelp.dll"] and c["enshrouded"]["optipatcher"] is True
    assert c["enshrouded"]["inputs"] == ["DLSS", "FSR3"] and c["enshrouded"]["issues"] == ["Needs Vulkan spoofing"]
    assert c["onlineshooter"]["status"] == "broken" and c["onlineshooter"]["anticheat"] is True
    assert "anticheat" not in c["sologame"]                          # "EAC off" is a game that works
    assert smoke.check_games(str(out)) == []


# ---- lsfg-vk: only next to the user's own Lossless Scaling --------------------------------------------------------
def _lsfg_tar(extra=()):
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w:xz") as t:
        for name, data in (("lib/liblsfg-vk-layer.so", b"so"), ("share/vulkan/implicit_layer.d/VkLayer_LSFGVK_frame_generation.json", b"{}"),
                           ("bin/lsfg-vk-cli", b"cli"), ("bin/lsfg-vk-ui", b"ui"), ("share/applications/x.desktop", b"d"), *extra):
            ti = tarfile.TarInfo(name)
            ti.size = len(data)
            t.addfile(ti, io.BytesIO(data))
    return buf.getvalue()


def _owned(home, dll="lsfg-vk.dll"):
    _w(os.path.join(home, ".local/share/Steam/steamapps/appmanifest_993090.acf"), '"AppState"\n{\n}\n')
    _w(os.path.join(home, ".local/share/Steam/steamapps/common/Lossless Scaling", dll), "dll")


def test_lsfg_vk_is_only_installed_for_owners(tmp_path, monkeypatch):
    home = str(tmp_path)
    data = _lsfg_tar()
    entry = {"version": "2.0.0", "url": "https://builds.lsfg-vk.dev/lsfg-vk-2.0.0.tar.xz", "sha256": hashlib.sha256(data).hexdigest()}
    calls = []

    def fake(url, dest, timeout=60.0):
        calls.append(url)
        open(dest, "wb").write(data)
        return dest
    monkeypatch.setattr(downloads, "download", fake)
    r = lsfg.install(home, entry)
    assert r["ok"] is False and "paid app on Steam" in r["error"] and calls == []     # nothing fetched, nothing installed
    _w(os.path.join(home, ".local/share/Steam/steamapps/common/Lossless Scaling/Lossless.dll"), "copied in")
    assert lsfg.install(home, entry)["ok"] is False                  # a DLL without Steam's install record isn't ownership
    _owned(home)
    r = lsfg.install(home, entry)
    assert r["ok"] and r["how"] == "installed" and calls == [entry["url"]]            # from its author's site only
    assert r["files"] == ["bin/lsfg-vk-cli", "lib/liblsfg-vk-layer.so", "share/vulkan/implicit_layer.d/VkLayer_LSFGVK_frame_generation.json"]
    assert os.path.isfile(os.path.join(home, ".local/lib/liblsfg-vk-layer.so"))
    assert not os.path.exists(os.path.join(home, ".local/bin/lsfg-vk-ui"))            # only what the layer needs
    assert lsfg.state(home) == {"installed": True, "version": "2.0.0", "files": r["files"]}
    assert lsfg.install(home, entry)["how"] == "there"
    assert lsfg.remove(home)["removed"] == 3 and not os.path.exists(os.path.join(home, ".local/lib/liblsfg-vk-layer.so"))
    assert lsfg.state(home)["installed"] is False


def test_lsfg_vk_install_never_replaces_another_install_or_a_wrong_file(tmp_path, monkeypatch):
    home = str(tmp_path)
    _owned(home)
    data = _lsfg_tar()
    monkeypatch.setattr(downloads, "download", lambda url, dest, timeout=60.0: open(dest, "wb").write(data) and dest)
    entry = {"version": "2.0.0", "url": "https://builds.lsfg-vk.dev/lsfg-vk-2.0.0.tar.xz", "sha256": "0" * 64}
    r = lsfg.install(home, entry)
    assert r["ok"] is False and "couldn't be downloaded" in r["error"] and not os.path.exists(os.path.join(home, ".local/lib"))
    entry["sha256"] = hashlib.sha256(data).hexdigest()
    _w(os.path.join(home, ".local/lib/liblsfg-vk-layer.so"), "someone else's")
    r = lsfg.install(home, entry)
    assert r["ok"] is False and "isn't ours" in r["error"]
    assert open(os.path.join(home, ".local/lib/liblsfg-vk-layer.so")).read() == "someone else's"
    pinned = games.pins()["lsfg_vk"]
    assert pinned["url"].startswith("https://builds.lsfg-vk.dev/") and len(pinned["sha256"]) == 64 and "mirror" not in pinned
