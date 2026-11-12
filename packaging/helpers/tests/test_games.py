"""GameCove's additions to the ported ClawDeck modules: every GPU (games.py), the AMD presets in launchenv and
optiscaler, the CLI, and the conflict rules (Decky Framegen, ClawDeck)."""
import json
import os
import subprocess
import sys

import pytest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from gamecove_upscale import cli, games, launchenv, optiscaler  # noqa: E402

HERE = os.path.dirname(__file__)
INTEL_XMX = {"vendor": "intel", "family": "intel-xe2", "arch": "Xe2", "xmx": True}
INTEL_LPG = {"vendor": "intel", "family": "intel-xe-lpg", "arch": "Xe-LPG", "xmx": False}
RDNA2 = {"vendor": "amd", "family": "amd-rdna2", "arch": "RDNA2"}
RDNA35 = {"vendor": "amd", "family": "amd-rdna3", "arch": "RDNA3.5"}


def _w(path, text="x"):
    os.makedirs(os.path.dirname(str(path)), exist_ok=True)
    with open(path, "w") as f:
        f.write(text)


def _pkg(home, ver="0.9.4"):
    d = os.path.join(home, optiscaler.ROOT, ver)
    for f, t in (("OptiScaler.dll", "opti"), ("OptiScaler.ini", "[Upscalers]\nDx12Upscaler=auto\n\n[FrameGen]\nEnabled=false\n"),
                 ("libxess.dll", "xess-opti"), ("amd_fidelityfx_upscaler_dx12.dll", "pkg-fsr"),
                 ("plugins/OptiPatcher.asi", "op")):
        _w(os.path.join(d, f), t)
    return d


def _steam_game(home, appid, name, files):
    lib = os.path.join(home, ".local/share/Steam/steamapps")
    _w(os.path.join(lib, f"appmanifest_{appid}.acf"),
       f'"AppState"\n{{\n "appid" "{appid}"\n "name" "{name}"\n "installdir" "{name}"\n}}\n')
    d = os.path.join(lib, "common", name)
    for f in files:
        _w(os.path.join(d, f), "x" * 10)
    return d


def _accept(home, key, risk="unknown"):
    """The player pressed Add for this game (best.opt_in's record): games no list knows are never changed without it."""
    st = games.load_state(home)
    st.setdefault("optin", {})[str(key)] = {"at": 1, "risk": risk}
    games.save_state(home, st)


@pytest.fixture(autouse=True)
def _no_chown(monkeypatch):
    monkeypatch.setattr(optiscaler.userexec, "chown_tree", lambda p, h: None)


def test_choices_follow_the_gpu():
    assert games.upscalers_for(INTEL_XMX) == ["own", "xess", "fsr4_xmx", "fsr4_xmx_lite"]
    assert games.fg_for(INTEL_XMX) == [0, 2, 3, 4]
    assert games.upscalers_for(INTEL_LPG) == ["own", "xess"] and games.fg_for(INTEL_LPG) == [0, 2]
    assert games.upscalers_for(RDNA35) == ["own", "fsr31", "fsr4_amd"] and games.fg_for(RDNA35) == [0, 2]
    # Van Gogh (Steam Deck): FSR 4.1.2 is offered (AMD's own DLL, INT8 switched on), never picked by itself
    assert games.upscalers_for(RDNA2) == ["own", "fsr31", "fsr4_amd"]
    assert games.upscalers_for({}) == ["own"] and games.fg_for({}) == [0]
    assert games.vendor({"family": "intel-xe3"}) == "intel" and games.vendor({"family": "amd-rdna2"}) == "amd"


def test_amd_compose_has_no_xmx_switches_and_refuses_intel_presets():
    env = launchenv.compose({"opti": "fsr31", "opti_fg": "upscaler", "fg": 2, "opti_dll": "dxgi"}, True, "amd")
    assert env["Dx12Upscaler"] == "fsr31" and env["FrameGen_FGOutput"] == "fsrfg"
    assert env["WINEDLLOVERRIDES"] == "dxgi=n,b;"
    assert not any(k.startswith("GAMECOVE_") or k in ("XESS_FG", "FSR", "DXVK_CONFIG") for k in env)
    for bad in ({"opti": "xess"}, {"opti": "fsr4_xmx"}, {"fg": 3}, {"fsr": "xess"}):
        with pytest.raises(ValueError):
            launchenv.compose(bad, True, "amd")
    # Intel is ClawDeck's composition, unchanged
    assert launchenv.compose({"opti": "xess", "fg": 3, "opti_fg": "upscaler"}, True) == \
        launchenv.compose({"opti": "xess", "fg": 3, "opti_fg": "upscaler"})


def test_amd_ini_uses_fsr_fg_and_the_capcom_setup_on_fsr():
    ini = launchenv.opti_ini({"opti": "fsr4_amd", "opti_fg": "dlssg", "fg": 2}, "amd")
    assert ini["Upscalers_Dx12Upscaler"] == "fsr31" and ini["FSR_Fsr4Update"] == "true"
    assert ini["FrameGen_FGOutput"] == "fsrfg" and "XeFG_InterpolationCount" not in ini
    cap = launchenv.opti_ini({"opti": "fsr31", "opti_fg": "dlssg", "reframework": True, "fg": 2}, "amd")
    assert cap["FrameGen_FGOutput"] == "FSRFG" and cap["Upscalers_VulkanUpscaler"] == "fsr31"
    assert "FrameGen_FGNvngxReplacement" not in cap and cap["DLSSG_OverrideInterpolationCount"] == "1"
    intel = launchenv.opti_ini({"opti": "xess", "opti_fg": "dlssg", "reframework": True, "fg": 3})
    assert intel["FrameGen_FGOutput"] == "XeFG" and intel["DLSSG_OverrideInterpolationCount"] == "2"


def test_amd_recommendation_keeps_a_games_own_fsr_and_takes_over_dlss(tmp_path):
    home = str(tmp_path)
    _steam_game(home, "100", "FsrGame", ["FsrGame.exe", "amd_fidelityfx_upscaler_dx12.dll"])
    _steam_game(home, "200", "DlssGame", ["DlssGame.exe", "nvngx_dlss.dll", "nvngx_dlssg.dll"])
    _steam_game(home, "300", "XessGame", ["XessGame.exe", "libxess.dll"])
    fsr = games.recommend(home, "100", RDNA35)
    assert fsr["route"] == "own_fsr" and not fsr["optiscaler"] and "FSR 4" in fsr["reasons"][0]
    dlss = games.recommend(home, "200", RDNA2)
    assert dlss["route"] == "optiscaler" and dlss["launch"]["opti"] == "fsr31" and dlss["launch"]["opti_fg"] == "dlssg"
    assert "XMX" not in dlss["reasons"][0] and "FSR 3.1" in dlss["reasons"][0]
    xs = games.recommend(home, "300", RDNA35)
    assert xs["route"] == "optiscaler" and xs["launch"]["opti"] == "fsr31"
    # the same XeSS game on the Claw: its own XeSS, nothing added (ClawDeck's route)
    claw = games.recommend(home, "300", INTEL_XMX)
    assert claw["route"] == "own_xess" and not claw["launch"]
    # Meteor Lake: XeSS without XMX, no XeSS-FG
    lpg = games.recommend(home, "200", INTEL_LPG)
    assert lpg["launch"]["opti"] == "xess" and lpg["launch"]["opti_fg"] == "off" and "XMX" not in lpg["reasons"][0]
    unknown = games.recommend(home, "200", {})
    assert unknown["route"] == "own" and not unknown["optiscaler"]


def test_choose_on_amd_puts_optiscaler_in_and_takes_it_out(tmp_path):
    home = str(tmp_path)
    _pkg(home)
    v = games.versions()["optiscaler"]
    d = _steam_game(home, "200", "DlssGame", ["DlssGame.exe", "nvngx_dlss.dll"])
    before = sorted(os.listdir(d))
    _accept(home, "200")
    r = games.choose(home, "200", "fsr31", 2, RDNA35)
    assert r["ok"], r
    assert r["env"]["WINEDLLOVERRIDES"] == "dxgi=n,b;" and r["env"]["FrameGen_FGOutput"] == "fsrfg"
    ini = open(os.path.join(d, "OptiScaler.ini")).read()
    assert "Dx12Upscaler=fsr31" in ini and "FGOutput=fsrfg" in ini
    env = open(os.path.join(home, ".local/share/gamecove/launch/200.env")).read()
    assert "WINEDLLOVERRIDES=dxgi=n,b;" in env and "GAMECOVE_XMX" not in env
    st = games.status(home, "200", RDNA35)
    assert st["owner"] == "gamecove" and st["upscaler"] == "fsr31" and st["fg"] == 2
    assert games.choose(home, "200", "xess", 0, RDNA35)["ok"] is False          # Intel only
    assert games.choose(home, "200", "fsr31", 3, RDNA35)["ok"] is False         # FSR-FG is 2x
    out = games.choose(home, "200", "own", 0, RDNA35)
    assert out["ok"] and sorted(os.listdir(d)) == before
    assert not os.path.exists(os.path.join(home, ".local/share/gamecove/launch/200.env"))
    assert v["version"] == "0.9.4"


def test_fsr4_on_amd_uses_amds_own_upscaler_and_puts_the_packages_back(tmp_path, monkeypatch):
    home = str(tmp_path)
    _pkg(home)
    d = _steam_game(home, "200", "DlssGame", ["DlssGame.exe", "nvngx_dlss.dll"])
    # AMD's file isn't there: the download is tried (sha256 checked) and a mismatch stops before anything is written
    calls = []

    def fake_download(url, dest, timeout=60.0):
        calls.append(url)
        _w(dest, "not amd")
        return dest
    monkeypatch.setattr(optiscaler.downloads, "download", fake_download)
    _accept(home, "200")
    r = games.choose(home, "200", "fsr4_amd", 0, RDNA35)
    assert not r["ok"] and "sha256" in r["error"] and not os.path.exists(os.path.join(d, "OptiScaler.ini"))
    # GameCove's mirror first, then AMD's own repository at the pinned commit; both refused on the hash
    assert calls[0].startswith("https://github.com/IHulkSmashI/GameCove-data/releases/download/upscalers/fsr4_amd-")
    assert calls[1].startswith("https://raw.githubusercontent.com/GPUOpen-LibrariesAndSDKs/FidelityFX-SDK/7539ae8b")
    _w(os.path.join(home, optiscaler.FSR4_AMD_DIR, optiscaler.FSR4_AMD_FILE), "amd-sdk-4.1.2")
    r = games.choose(home, "200", "fsr4_amd", 0, RDNA35)
    assert r["ok"], r
    assert open(os.path.join(d, "amd_fidelityfx_upscaler_dx12.dll")).read() == "amd-sdk-4.1.2"
    assert "Fsr4Update=true" in open(os.path.join(d, "OptiScaler.ini")).read()
    assert games.choose(home, "200", "fsr31", 0, RDNA35)["ok"]
    assert open(os.path.join(d, "amd_fidelityfx_upscaler_dx12.dll")).read() == "pkg-fsr"
    assert games.choose(home, "200", "fsr4_amd", 0, {"vendor": "amd", "arch": "Vega"})["ok"] is False   # not on Vega


def test_foreign_optiscaler_is_never_touched(tmp_path):
    home = str(tmp_path)
    _pkg(home)
    d = _steam_game(home, "200", "DlssGame", ["DlssGame.exe", "nvngx_dlss.dll"])
    _w(os.path.join(d, ".clawdeck-optiscaler", "manifest.json"), "{}")
    r = games.choose(home, "200", "fsr31", 0, RDNA35)
    assert not r["ok"] and r["owner"] == "clawdeck" and "ClawDeck" in r["error"]
    os.remove(os.path.join(d, ".clawdeck-optiscaler", "manifest.json"))
    _w(os.path.join(d, "FRAMEGEN_PATCH"))                     # Decky Framegen v0.17's marker
    r = games.choose(home, "200", "fsr31", 0, RDNA35)
    assert not r["ok"] and r["owner"] == "decky-framegen" and "Unpatch" in r["error"]
    assert not os.path.exists(os.path.join(d, "OptiScaler.ini"))


def test_amd_fsr4_pin_is_amds_sdk():
    e = games.versions()["fsr4_amd"]
    assert e["files"] == {"amd_fidelityfx_upscaler_dx12.dll": "aad4fccccb29084a655f9a4f9f613bd22c8c03fb4a0f8840148cc6543b4ccace"}
    # the same file ClawDeck keeps as fsr-original.dll beside nitec's build
    assert games.versions()["fsr4_xmx"]["files"]["fsr-original.dll"] == e["files"]["amd_fidelityfx_upscaler_dx12.dll"]


def test_cli_answers_json_and_refuses_bad_usage(tmp_path, capsys):
    home = str(tmp_path)
    _steam_game(home, "100", "FsrGame", ["FsrGame.exe", "amd_fidelityfx_upscaler_dx12.dll"])
    assert cli.main(["recommend", "--home", home, "--key", "100", "--gpu", json.dumps(RDNA35)]) == 0
    out = json.loads(capsys.readouterr().out)
    assert out["ok"] and out["route"] == "own_fsr" and out["upscalers"] == ["own", "fsr31", "fsr4_amd"]
    assert cli.main(["status", "--home", home, "--gpu", "{}"]) == 0
    assert json.loads(capsys.readouterr().out) == {"ok": False, "error": "status needs --key"}
    assert cli.main(["bogus", "--home", home]) == 2
    capsys.readouterr()
    assert cli.main(["state", "--home", home, "--gpu", json.dumps(INTEL_XMX)]) == 0
    st = json.loads(capsys.readouterr().out)
    assert st["vendor"] == "intel" and st["xess"]["installed"] is False


def test_gpu_argument_as_pairs_or_json():
    assert cli.parse_gpu("vendor=amd,family=amd-rdna3,arch=RDNA3.5,xmx=0") == \
        {"vendor": "amd", "family": "amd-rdna3", "arch": "RDNA3.5", "xmx": False}
    assert cli.parse_gpu('{"vendor": "intel", "xmx": true}') == {"vendor": "intel", "xmx": True}
    assert cli.parse_gpu("") == {}
    with pytest.raises(ValueError):
        cli.parse_gpu("evil=1")


def test_entry_script_runs_the_package(tmp_path):
    script = os.path.join(HERE, "..", "..", "libexec", "gamecove-upscale")
    r = subprocess.run(["sh", script, "state", "--home", str(tmp_path), "--gpu", json.dumps(RDNA2)],
                       capture_output=True, text=True, timeout=60, check=False)
    assert r.returncode == 0 and json.loads(r.stdout)["upscalers"] == ["own", "fsr31", "fsr4_amd"]


def test_cli_xess_install_is_for_xmx_only_and_uses_the_pinned_release(tmp_path, capsys, monkeypatch):
    from gamecove_upscale import xess
    seen = {}
    monkeypatch.setattr(xess, "install", lambda home, entry, unpinned=False: seen.update(home=home, entry=entry) or {"ok": True})
    monkeypatch.setattr(xess, "remove_for_uninstall", lambda home: {"ok": True, "ours": False})
    home = str(tmp_path)
    assert cli.main(["xess-install", "--home", home, "--gpu", "vendor=amd,xmx=0"]) == 0
    assert json.loads(capsys.readouterr().out)["ok"] is False and not seen, "never on AMD"
    assert cli.main(["xess-install", "--home", home, "--gpu", json.dumps(INTEL_LPG)]) == 0
    assert json.loads(capsys.readouterr().out)["ok"] is False and not seen, "never without XMX"
    assert cli.main(["xess-install", "--home", home, "--gpu", "vendor=intel,xmx=1"]) == 0
    assert json.loads(capsys.readouterr().out) == {"ok": True}
    assert seen["entry"] == games.versions()["xess_xmx_linux"] and seen["home"] == home
    assert cli.main(["xess-remove", "--home", home]) == 0
    assert json.loads(capsys.readouterr().out)["ok"] is True


def _tree(d):
    out = {}
    for r, _d, f in os.walk(d):
        for x in f:
            out[os.path.relpath(os.path.join(r, x), d)] = open(os.path.join(r, x), "rb").read()
    return out


def test_a_game_moved_to_another_library_keeps_its_upscaler_and_undo(tmp_path):
    """Review M: the folder was saved by path, so a game moved between libraries (Steam's "Move install folder")
    was orphaned: Native left our files in it. Games are keyed by their id and the folder is followed."""
    import shutil
    home = str(tmp_path / "home")
    _pkg(home)
    d = _steam_game(home, "620", "Moving", ["Moving/Binaries/Win64/Moving-Win64-Shipping.exe", "Moving/Binaries/Win64/nvngx_dlss.dll",
                                            "Moving/Binaries/Win64/D3D12Core.dll"])
    before = _tree(d)
    _accept(home, "620")
    assert games.choose(home, "620", "fsr31", 0, RDNA2)["ok"]
    # Steam moves it to the SD card library: the manifest goes along, the old path is gone
    sd = tmp_path / "sd"
    os.makedirs(sd / "steamapps" / "common")
    lib = os.path.join(home, ".local/share/Steam/steamapps")
    shutil.move(os.path.join(lib, "appmanifest_620.acf"), sd / "steamapps" / "appmanifest_620.acf")
    shutil.move(d, sd / "steamapps" / "common" / "Moving")
    _w(os.path.join(lib, "libraryfolders.vdf"), f'"libraryfolders"\n{{\n "1"\n {{\n  "path" "{sd}"\n }}\n}}\n')
    moved = str(sd / "steamapps" / "common" / "Moving")
    st = games.status(home, "620", RDNA2)
    assert st["owner"] == "gamecove" and st["upscaler"] == "fsr31" and st["folder"].startswith(moved)
    assert games.load_state(home)["opti_games"]["620"].startswith(moved)          # saved for next time
    assert games.undo(home, "620", RDNA2)["ok"]
    assert _tree(moved) == before                                               # Native reaches the moved copy
