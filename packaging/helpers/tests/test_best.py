"""Best for your handheld: the chip table (chips.py), the guard (anti-cheat, other injectors), the plan and what
prepare() does by itself, the read-out after a start (active.py), and Native (exact undo)."""
import hashlib
import json
import os
import sys
import time

import pytest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from gamecove_upscale import active, best, chips, cli, gamedb, games, guard, launchenv, optiscaler  # noqa: E402
from test_games import _pkg, _steam_game, _w  # noqa: E402

HERE = os.path.dirname(__file__)
FIXTURE = os.path.join(HERE, "..", "..", "..", "app", "tests", "fixtures", "gpu_tiers.json")
XMX = {"vendor": "intel", "family": "intel-xe3", "arch": "Xe3", "xmx": True, "chip": "Intel Panther Lake"}
Z1E = {"vendor": "amd", "family": "amd-rdna3", "arch": "RDNA3", "chip": "AMD Ryzen Z1 Extreme"}
Z2E = {"vendor": "amd", "family": "amd-rdna3", "arch": "RDNA3.5", "chip": "AMD Ryzen Z2 Extreme"}
DECK = {"vendor": "amd", "family": "amd-rdna2", "arch": "RDNA2", "chip": "AMD Van Gogh (Aerith)"}
NVIDIA = {"vendor": "nvidia", "family": "nvidia", "chip": "Desktop", "gpu": "NVIDIA GeForce RTX 4070"}


@pytest.fixture(autouse=True)
def _no_chown(monkeypatch):
    monkeypatch.setattr(optiscaler.userexec, "chown_tree", lambda p, h: None)


def _amd_fsr4(home):
    _w(os.path.join(home, optiscaler.FSR4_AMD_DIR, optiscaler.FSR4_AMD_FILE), "amd-sdk-4.1.2")


def _tree(d):
    out = {}
    for r, _d, f in os.walk(d):
        for x in f:
            p = os.path.join(r, x)
            out[os.path.relpath(p, d)] = hashlib.sha256(open(p, "rb").read()).hexdigest()
    return out


# ---- the chip table -----------------------------------------------------------------------------------------------
def test_every_chip_in_the_device_table_gets_its_tier_and_choices():
    rows = json.load(open(FIXTURE))["rows"]
    assert len(rows) >= 40
    for r in rows:
        g = r["gpu"]
        assert chips.tier(g) == r["tier"], r["from"]
        assert chips.upscalers(g) == r["upscalers"] and chips.frame_gens(g) == r["frame_gens"], r["from"]
        assert chips.generators(g) == r["generators"] and chips.latency(g) == r["latency"], r["from"]
        assert chips.tier({**g, "tier": r["tier"]}) == r["tier"]
    assert {r["tier"] for r in rows} == set(chips.TIERS)            # every tier has a real chip behind it


def test_multipliers_are_only_what_the_chip_really_does():
    assert chips.frame_gens(XMX) == [0, 2, 3, 4]                    # XeSS multi-frame generation: Intel Arc with XMX only
    for g in (Z1E, Z2E, DECK, {"vendor": "intel", "arch": "Xe-LPG", "xmx": False}):
        assert chips.frame_gens(g) == [0, 2], g
    assert chips.frame_gens(NVIDIA) == [0] and chips.upscalers(NVIDIA) == ["own"]     # native DLSS is left alone
    assert chips.generators(Z1E) == ["fsrfg", "xefg"] and chips.generators(DECK) == ["fsrfg"]
    assert chips.latency(Z1E, "xefg") == "xell" and chips.latency(Z1E, "fsrfg") == "antilag2" and chips.latency(NVIDIA) == "reflex"
    assert games.choose("/nonexistent", "1", "fsr31", 3, Z1E)["ok"] is False
    assert games.choose("/nonexistent", "1", "own", 2, NVIDIA)["ok"] is False


def test_fsr4_default_follows_the_chip():
    assert chips.default_upscaler(XMX, True, True) == "fsr4_xmx" and chips.default_upscaler(XMX, True, False) == "xess"
    assert chips.default_upscaler(XMX, False, True) == "xess"                      # FSR 4 on XMX is DirectX 12 only
    assert chips.default_upscaler(Z1E, True) == "fsr4_amd" and chips.default_upscaler(Z2E, True) == "fsr4_amd"
    assert chips.default_upscaler(Z1E, False) == "fsr31"
    assert chips.default_upscaler(DECK, True) == "fsr31" and "fsr4_amd" in chips.upscalers(DECK)   # offered, never picked
    assert chips.capabilities(Z1E)["fsr4_listed"] is False and chips.capabilities(Z2E)["fsr4_listed"] is True
    assert chips.capabilities(Z2E)["fsr4_model"] == "INT8 Lite"


def test_amd_launch_env_for_fsr4_and_xess_frame_generation():
    env = launchenv.compose({"opti": "fsr4_amd", "fsr4_int8": True, "opti_dll": "dxgi"}, True, "amd")
    assert env["FSR_Fsr4ForceEnableInt8"] == "true" and env["FSR_Fsr4Update"] == "true"
    assert env["PROTON_FSR4_UPGRADE"] == "1"                                       # OptiScaler's own Linux setup
    assert "FSR_Fsr4ForceEnableInt8" not in launchenv.compose({"opti": "fsr4_amd"}, True, "amd")
    ini = launchenv.opti_ini({"opti": "fsr4_amd", "fsr4_int8": True, "opti_fg": "dlssg", "fg": 2, "fg_out": "xefg"}, "amd")
    assert ini["FSR_Fsr4ForceEnableInt8"] == "true" and ini["FrameGen_FGOutput"] == "xefg" and ini["FrameGen_FGInput"] == "dlssg"
    assert launchenv.opti_ini({"opti": "fsr31", "opti_fg": "dlssg", "fg": 2}, "amd")["FrameGen_FGOutput"] == "fsrfg"
    assert "XeFG_InterpolationCount" not in ini                                    # 2x only: no multi-frame count off Intel
    assert launchenv.compose({"proton_fsr4": True}, True, "amd") == {"PROTON_FSR4_UPGRADE": "1"}
    with pytest.raises(ValueError):
        launchenv.compose({"opti": "fsr31", "opti_fg": "dlssg", "fg_out": "dlssg"}, True, "amd")
    # Intel: OptiScaler's own XeSS always shows the Intel GPU to the game (DP4a otherwise), appended by the wrapper
    assert launchenv.compose({"opti": "xess"})["DXVK_CONFIG"] == launchenv.SHOW_INTEL
    assert launchenv.compose({"opti": "fsr4_xmx"})["FSR4_XMX_NO_DIALOG"] == "1"


# ---- the guard ----------------------------------------------------------------------------------------------------
@pytest.mark.parametrize("files,system", [
    (["EasyAntiCheat/EasyAntiCheat_x64.dll"], "Easy Anti-Cheat"), (["start_protected_game.exe"], "Easy Anti-Cheat"),
    (["BattlEye/BEService_x64.exe"], "BattlEye"), (["Game_BE.exe"], "BattlEye"), (["bin/GameGuard.des"], "nProtect GameGuard"),
    (["mhyprot3.sys"], "miHoYo Protect"), (["AntiCheatExpert/ACE-BASE.sys"], "Anti-Cheat Expert"),
    (["EAAntiCheat.GameServiceLauncher.exe", "EAAntiCheat.GameServiceLauncher.dll"], "EA Javelin"),
    (["NeacClient.exe"], "NetEase Anti-Cheat"), (["bin/NeacSafe64.sys"], "NetEase Anti-Cheat"),
    (["bin/xhunter1.sys"], "XIGNCODE3"), (["BlackCipher/BlackCipher64.aes"], "Nexon Game Security"),
    (["TenProtect/TP3Helper.dat"], "Tencent TP"), (["EQU8/equ8_conf.json"], "EQU8")])
def test_anticheat_in_the_folder_is_found(tmp_path, files, system):
    for f in files:
        _w(tmp_path / "g" / f)
    assert guard.anticheat(str(tmp_path / "g")) == [system]


def test_anticheat_scan_reaches_every_folder_optiscaler_can_go_into(tmp_path):
    """Review H4: the scan stopped one level short of placement. An exe as deep as main_exe_dir() looks, with
    EasyAntiCheat next to it, is where OptiScaler would go, so the scan must see it."""
    deep = os.path.join(*["d%d" % i for i in range(optiscaler.EXE_DEPTH)])
    _w(tmp_path / "g" / deep / "Game.exe", "x" * 4096)
    _w(tmp_path / "g" / deep / "EasyAntiCheat" / "Settings.json")
    g = str(tmp_path / "g")
    assert optiscaler.main_exe_dir(g) == os.path.join(g, deep)
    assert guard.anticheat(g) == ["Easy Anti-Cheat"]
    assert guard.DEPTH > optiscaler.EXE_DEPTH                       # derived from placement, never shallower


def test_anticheat_scan_looks_up_to_the_games_own_folder(tmp_path):
    """An app that passes the game's Binaries folder still sees EasyAntiCheat/ at the game's top; the scan never
    climbs into the library (another game's anti-cheat isn't this game's)."""
    common = tmp_path / "lib" / "steamapps" / "common"
    _w(common / "Game" / "EasyAntiCheat" / "EasyAntiCheat_x64.dll")
    _w(common / "Game" / "Game" / "Binaries" / "Win64" / "Game-Win64-Shipping.exe")
    assert guard.anticheat(str(common / "Game" / "Game" / "Binaries" / "Win64")) == ["Easy Anti-Cheat"]
    _w(common / "Other" / "BattlEye" / "BEClient_x64.dll")
    _w(common / "Clean" / "Clean.exe")
    assert guard.anticheat(str(common / "Clean")) == []


def test_no_anticheat_false_positives(tmp_path):
    for f in ("Game.exe", "pb/readme.txt", "Engine/Binaries/ThirdParty/x.dll", "beta/notes.txt", "nvngx_dlss.dll"):
        _w(tmp_path / "g" / f)
    assert guard.anticheat(str(tmp_path / "g")) == [] and guard.refusal(str(tmp_path / "g"), str(tmp_path / "g")) is None
    assert guard.anticheat(None) == []


def test_anticheat_games_are_refused_everywhere(tmp_path):
    home = str(tmp_path)
    _pkg(home)
    d = _steam_game(home, "300", "Online", ["Online.exe", "nvngx_dlss.dll", "EasyAntiCheat/EasyAntiCheat_x64.dll"])
    before = _tree(d)
    for g in (XMX, Z1E):
        r = games.choose(home, "300", chips.upscalers(g)[1], 0, g)
        assert r["ok"] is False and r["refused"] == "anticheat" and "anti-cheat" in r["error"]
        assert games.apply_recommended(home, "300", g)["ok"] is False
        p = best.plan(home, "300", g)
        assert p["refused"] == "anticheat" and p["auto"] is False
        assert best.prepare(home, "300", g)["did"] == ""
    assert _tree(d) == before and not os.path.exists(os.path.join(home, ".local/share/gamecove/launch/300.env"))
    # the app's own data says anti-cheat although the folder shows nothing
    d2 = _steam_game(home, "301", "Quiet", ["Quiet.exe", "nvngx_dlss.dll"])
    assert games.choose(home, "301", "fsr31", 0, Z1E, anticheat=True)["refused"] == "anticheat"
    assert cli.run(["plan", "--home", home, "--key", "301", "--gpu", json.dumps(Z1E), "--anticheat"])["refused"] == "anticheat"
    assert _tree(d2) == {"Quiet.exe": _tree(d2)["Quiet.exe"], "nvngx_dlss.dll": _tree(d2)["nvngx_dlss.dll"]}


def test_a_game_that_gains_anticheat_gets_everything_taken_out(tmp_path):
    home = str(tmp_path)
    _pkg(home)
    d = _steam_game(home, "302", "Later", ["Later.exe", "nvngx_dlss.dll", "D3D12Core.dll"])
    before = _tree(d)
    assert best.opt_in(home, "302", DECK)["did"] == "set up"
    _w(os.path.join(d, "EasyAntiCheat", "EasyAntiCheat_x64.dll"), "eac")
    r = best.prepare(home, "302", DECK)
    assert "anti-cheat" in r["did"]
    after = _tree(d)
    after.pop(os.path.join("EasyAntiCheat", "EasyAntiCheat_x64.dll"))
    assert after == before


def test_other_injectors_are_left_alone(tmp_path):
    home = str(tmp_path)
    _pkg(home)
    d = _steam_game(home, "303", "Shaded", ["Shaded.exe", "nvngx_dlss.dll", "ReShade.ini", "dxgi.dll"])
    before = _tree(d)
    r = games.choose(home, "303", "fsr31", 0, Z1E)
    assert r["ok"] is False and "ReShade" in r["error"]
    p = best.plan(home, "303", Z1E)
    assert p["refused"] == "mod" and best.prepare(home, "303", Z1E)["did"] == "" and _tree(d) == before


ONLINE_TITLES = ["Wuthering Waves", "Zenless Zone Zero", "Arknights: Endfield", "Where Winds Meet", "GOALS"]


def test_online_games_in_the_list_are_flagged():
    """Review H5: the list's "Online game, use at your own risk" titles are status "works"; each carries the online
    flag, in the bundled data and when read from the notes of an older list."""
    doc = gamedb.load(games.BUNDLED_GAMES)
    for name in ONLINE_TITLES:
        k = gamedb.knowledge(doc, None, None, name)
        assert k["known"] and k["status"] == "works" and k["online"] is True, name
        assert gamedb.compat_row(doc, name).get("online") is True, name
    assert gamedb.online_risk("**Online game, use at your own risk!**") and gamedb.online_risk("Disable EAC to load OptiScaler.")
    for safe in ("Free online co-op game, no anticheat", "Online co-op game, does not use anticheat", "Use DX12", ""):
        assert not gamedb.online_risk(safe), safe


@pytest.mark.parametrize("name", ONLINE_TITLES)
def test_online_games_are_never_set_up_by_themselves(tmp_path, name):
    home = str(tmp_path)
    _pkg(home)
    _amd_fsr4(home)
    d = _steam_game(home, "450", name, ["Client.exe", "nvngx_dlss.dll", "D3D12Core.dll"])
    before = _tree(d)
    p = best.plan(home, "450", Z1E)
    assert p["online"] and p["auto"] is False and p["offer"] and p["refused"] is None
    assert "online game" in p["line"] and "banned" in p["line"]
    assert best.prepare(home, "450", Z1E)["did"] == "" and _tree(d) == before
    assert not os.path.exists(os.path.join(home, ".local/share/gamecove/launch/450.env"))
    r = cli.run(["opt-in", "--home", home, "--key", "450", "--gpu", json.dumps(Z1E)])     # the player's own pick
    assert r["ok"] and r["did"] == "set up" and _tree(d) != before
    assert best.plan(home, "450", Z1E)["opted_in"] and best.prepare(home, "450", Z1E)["did"] == ""
    assert best.native(home, "450", Z1E)["ok"] and _tree(d) == before and not best.opted_in(home, "450")


def test_an_online_game_set_up_before_it_was_flagged_comes_out(tmp_path):
    home = str(tmp_path)
    _pkg(home)
    d = _steam_game(home, "451", "Wuthering Waves", ["Client.exe", "nvngx_dlss.dll", "D3D12Core.dll"])
    before = _tree(d)
    assert games.apply_recommended(home, "451", DECK)["ok"] and _tree(d) != before    # an older GameCove's doing
    r = best.prepare(home, "451", DECK)
    assert "online game" in r["did"] and _tree(d) == before


def test_opt_in_still_refuses_anticheat(tmp_path):
    home = str(tmp_path)
    _pkg(home)
    d = _steam_game(home, "452", "Zenless Zone Zero", ["ZZZ.exe", "nvngx_dlss.dll", "D3D12Core.dll", "mhypbase.dll"])
    before = _tree(d)
    r = best.opt_in(home, "452", Z1E)
    assert r["ok"] is False and r["refused"] == "anticheat" and _tree(d) == before and not best.opted_in(home, "452")


# ---- plan and prepare ---------------------------------------------------------------------------------------------
def test_z1_extreme_gets_fsr4_by_default_with_amds_own_file(tmp_path):
    home = str(tmp_path)
    _pkg(home)
    _amd_fsr4(home)
    d = _steam_game(home, "400", "DlssGame", ["DlssGame.exe", "nvngx_dlss.dll", "D3D12Core.dll"])
    p = best.plan(home, "400", Z1E)
    assert p["upscaler"] == "fsr4_amd" and p["launch"]["fsr4_int8"] is True and "FSR 4.1.2" in p["line"]
    assert p["auto"] is False and p["offer"] == "fsr4_amd"         # a game no list knows: offered, not done
    assert best.prepare(home, "400", Z1E)["did"] == ""
    r = best.opt_in(home, "400", Z1E)
    assert r["ok"] and r["did"] == "set up", r
    assert open(os.path.join(d, "amd_fidelityfx_upscaler_dx12.dll")).read() == "amd-sdk-4.1.2"
    ini = open(os.path.join(d, "OptiScaler.ini")).read()
    assert "Fsr4ForceEnableInt8=true" in ini and "Fsr4Update=true" in ini and "LogToFile=true" in ini
    env = open(os.path.join(home, ".local/share/gamecove/launch/400.env")).read()
    assert "PROTON_FSR4_UPGRADE=1" in env and "WINEDLLOVERRIDES=dxgi=n,b;" in env
    assert best.prepare(home, "400", Z1E)["did"] == ""             # already there: nothing done twice
    assert best.plan(home, "400", Z2E)["launch"].get("fsr4_int8") is None          # on AMD's list: no switch needed
    assert best.plan(home, "400", DECK)["upscaler"] == "fsr31"


def test_a_game_with_fsr31_gets_protons_upgrade_and_no_files(tmp_path):
    home = str(tmp_path)
    _pkg(home)
    d = _steam_game(home, "401", "FsrGame", ["FsrGame.exe", "amd_fidelityfx_dx12.dll"])
    before = _tree(d)
    p = best.plan(home, "401", Z1E)
    assert p["route"] == "own_fsr" and p["launch"] == {"proton_fsr4": True} and p["files"] is False and p["auto"]
    assert best.prepare(home, "401", Z1E)["did"] == "set up" and _tree(d) == before
    assert open(os.path.join(home, ".local/share/gamecove/launch/401.env")).read().count("PROTON_FSR4_UPGRADE=1") == 1
    st = best.status(home, "401", Z1E)
    assert st["active"]["state"] == "waiting" and "FSR 4" in st["active"]["line"]
    assert best.plan(home, "401", DECK)["launch"] == {}             # RDNA 2: the game's own FSR, nothing set
    assert best.native(home, "401", Z1E)["ok"] and not os.path.exists(os.path.join(home, ".local/share/gamecove/launch/401.env"))


def test_an_unknown_game_without_clear_signs_is_never_touched(tmp_path):
    home = str(tmp_path)
    _pkg(home)
    d = _steam_game(home, "402", "Mystery", ["Mystery.exe", "nvngx_dlss.dll"])      # DLSS but not provably DirectX 12
    before = _tree(d)
    p = best.plan(home, "402", DECK)
    assert p["auto"] is False and p["known"] is False and "don't know this game" in p["why_not"]
    assert best.prepare(home, "402", DECK)["did"] == "" and _tree(d) == before
    assert games.choose(home, "402", "fsr31", 0, DECK)["ok"]        # by hand it still works


def test_an_unknown_dx12_game_gets_the_upscaler_only(tmp_path):
    home = str(tmp_path)
    _pkg(home)
    d = _steam_game(home, "403", "Plain", ["Plain.exe", "nvngx_dlss.dll", "nvngx_dlssg.dll", "D3D12Core.dll"])
    before = _tree(d)
    p = best.plan(home, "403", DECK)
    assert p["auto"] is False and p["offer"] == "fsr31" and "FSR 3.1" in p["line"]       # review H5: opt-in only
    assert best.prepare(home, "403", DECK)["did"] == "" and _tree(d) == before
    assert best.opt_in(home, "403", DECK)["did"] == "set up"
    ini = open(os.path.join(d, "OptiScaler.ini")).read()
    assert "Dx12Upscaler=fsr31" in ini and "FGInput=nofg" in ini    # no frame generation by itself
    assert best.get_mode(home, "403") == "best" and best.prepare(home, "403", DECK)["did"] == ""


def test_native_takes_everything_out_and_stays_out(tmp_path):
    home = str(tmp_path)
    _pkg(home)
    _amd_fsr4(home)
    d = _steam_game(home, "404", "DlssGame", ["DlssGame.exe", "nvngx_dlss.dll", "D3D12Core.dll", "amd_fidelityfx_upscaler_dx12.dll.keep"])
    before = _tree(d)
    assert best.opt_in(home, "404", Z1E)["did"] == "set up" and _tree(d) != before
    r = cli.run(["mode", "--home", home, "--key", "404", "--gpu", json.dumps(Z1E), "--mode", "native"])
    assert r["ok"] and r["mode"] == "native"
    assert _tree(d) == before                                       # byte for byte as the game shipped
    assert not os.path.exists(os.path.join(home, ".local/share/gamecove/launch/404.env"))
    assert best.prepare(home, "404", Z1E)["did"] == "" and _tree(d) == before       # and nothing comes back by itself
    r = cli.run(["mode", "--home", home, "--key", "404", "--gpu", json.dumps(Z1E), "--mode", "best"])
    assert r["mode"] == "best" and r["did"] == "" and _tree(d) == before      # Native forgot the opt-in: offered again
    r = cli.run(["opt-in", "--home", home, "--key", "404", "--gpu", json.dumps(Z1E)])
    assert r["did"] == "set up" and best.get_mode(home, "404") == "best"


def test_custom_choices_are_kept_and_repaired_after_a_game_update(tmp_path):
    home = str(tmp_path)
    _pkg(home)
    d = _steam_game(home, "405", "DlssGame", ["DlssGame.exe", "nvngx_dlss.dll", "D3D12Core.dll"])
    r = cli.run(["choose", "--home", home, "--key", "405", "--gpu", json.dumps(Z1E), "--upscaler", "fsr31", "--fg", "2",
                 "--generator", "xefg"])
    assert r["ok"] and best.get_mode(home, "405") == "custom"
    assert "FGOutput=xefg" in open(os.path.join(d, "OptiScaler.ini")).read()
    assert best.prepare(home, "405", Z1E)["did"] == ""              # best mode would pick FSR 4: the user's pick stays
    st = best.status(home, "405", Z1E)
    assert st["upscaler"] == "fsr31" and st["generator"] == "xefg" and st["fg"] == 2
    os.remove(os.path.join(d, "dxgi.dll"))                          # Steam "verify files" / a game update
    assert best.prepare(home, "405", Z1E)["did"] == "put back after a game update"
    assert os.path.isfile(os.path.join(d, "dxgi.dll")) and "FGOutput=xefg" in open(os.path.join(d, "OptiScaler.ini")).read()
    assert cli.run(["choose", "--home", home, "--key", "405", "--gpu", json.dumps(DECK), "--upscaler", "fsr31", "--fg", "2",
                    "--generator", "xefg"])["ok"] is False          # XeSS frame generation isn't offered on RDNA 2


# ---- the read-out -------------------------------------------------------------------------------------------------
def _start(home, key, at=None):
    p = os.path.join(home, ".local/share/gamecove/launch", f"{key}.started")
    _w(p, "")
    if at:
        os.utime(p, (at, at))


def test_the_readout_follows_what_really_happened(tmp_path):
    home = str(tmp_path)
    _pkg(home)
    _amd_fsr4(home)
    d = _steam_game(home, "500", "DlssGame", ["DlssGame.exe", "nvngx_dlss.dll", "D3D12Core.dll"])
    assert best.status(home, "500", Z1E)["active"]["state"] == "own"
    assert games.choose(home, "500", "fsr4_amd", 2, Z1E)["ok"]
    a = best.status(home, "500", Z1E)["active"]
    assert a["state"] == "waiting" and "FSR 4.1.2, FSR frame generation 2x, Anti-Lag 2" in a["line"]
    now = time.time() + 30
    _start(home, "500", now)                                        # the game ran, OptiScaler wrote nothing
    assert best.status(home, "500", Z1E)["active"]["state"] == "not_loaded"
    log = os.path.join(d, "OptiScaler.log")
    _w(log, "[info] OptiScaler v0.9.4 loaded\n[info] Dxgi spoofing enabled\n")
    os.utime(log, (now + 1, now + 1))
    a = best.status(home, "500", Z1E)["active"]
    assert a["state"] == "loaded" and "switch on DLSS or FSR" in a["line"]
    _w(log, "[info] OptiScaler loaded\n[info] FSR31FeatureDx12::Init Creating new FSR 3.X upscaler\n")
    os.utime(log, (now + 1, now + 1))
    a = best.status(home, "500", Z1E)["active"]
    assert a["state"] == "active" and "Frame generation hasn't started" in a["line"]
    _w(log, "[info] Creating new FSR 3.X upscaler\n[info] FSRFG_Dx12 CreateContext FSRFG context created\n")
    os.utime(log, (now + 1, now + 1))
    a = best.status(home, "500", Z1E)["active"]
    assert a == {"state": "active", "line": "Active: FSR 4.1.2, FSR frame generation 2x, Anti-Lag 2",
                 "what": "FSR 4.1.2, FSR frame generation 2x, Anti-Lag 2", "errors": []}
    assert active.describe("fsr4_xmx", 3, "xefg", "xell") == "FSR 4.1.2 on XMX, XeSS frame generation 3x, XeLL low latency"
    assert active.read_log(None)["lines"] == 0


def test_fsr4_that_never_starts_falls_back_to_fsr31_once(tmp_path):
    home = str(tmp_path)
    _pkg(home)
    _amd_fsr4(home)
    d = _steam_game(home, "501", "DlssGame", ["DlssGame.exe", "nvngx_dlss.dll", "D3D12Core.dll"])
    assert best.opt_in(home, "501", Z1E)["did"] == "set up"
    t = time.time() + 30
    _start(home, "501", t)
    assert best.prepare(home, "501", Z1E)["did"] == ""              # one bad start isn't enough
    assert best.prepare(home, "501", Z1E)["did"] == ""              # the same start isn't counted twice
    _start(home, "501", t + 60)
    r = best.prepare(home, "501", Z1E)
    assert "switched to FSR 3.1" in r["did"]
    assert "Dx12Upscaler=fsr31" in open(os.path.join(d, "OptiScaler.ini")).read()
    assert open(os.path.join(d, "amd_fidelityfx_upscaler_dx12.dll")).read() == "pkg-fsr"
    assert best.prepare(home, "501", Z1E)["did"] == ""              # it doesn't flip back by itself
    assert "didn't start here" in best.status(home, "501", Z1E)["active"]["line"]
    assert games.choose(home, "501", "fsr4_amd", 0, Z1E)["ok"]      # one tap brings it back
    best.set_mode(home, "501", "custom")
    assert best.status(home, "501", Z1E)["fell_back"] is None


def test_a_good_start_clears_the_strikes(tmp_path):
    home = str(tmp_path)
    _pkg(home)
    _amd_fsr4(home)
    d = _steam_game(home, "502", "DlssGame", ["DlssGame.exe", "nvngx_dlss.dll", "D3D12Core.dll"])
    best.opt_in(home, "502", Z1E)
    t = time.time() + 30
    for i, good in enumerate((False, True, False)):
        _start(home, "502", t + i * 60)
        log = os.path.join(d, "OptiScaler.log")
        if good:
            _w(log, "[info] Creating new FSR 3.X upscaler\n")
            os.utime(log, (t + i * 60 + 1,) * 2)
        elif os.path.exists(log):
            os.remove(log)
        assert best.prepare(home, "502", Z1E)["did"] == ""
    assert "Fsr4Update=true" in open(os.path.join(d, "OptiScaler.ini")).read()


# ---- what the folder tells ----------------------------------------------------------------------------------------
def test_api_and_engine_from_the_folder(tmp_path):
    g = tmp_path / "g"
    _w(g / "Game" / "Binaries" / "Win64" / "Game-Win64-Shipping.exe", "MZ....d3d11.dll....D3D12.DLL...")
    assert gamedb.api(str(g)) == "dx12" and gamedb.engine(str(g)) == "unreal"
    u = tmp_path / "u"
    _w(u / "Unity.exe", "MZ..d3d11.dll..")
    _w(u / "UnityPlayer.dll")
    assert gamedb.api(str(u)) == "dx11" and gamedb.engine(str(u)) == "unity"
    v = tmp_path / "v"
    _w(v / "big.exe", "MZ" + "vulkan-1.dll" + "x" * 50)
    _w(v / "small.exe", "MZ d3d9.dll")
    assert gamedb.api(str(v)) == "vulkan" and gamedb.engine(str(v)) == "" and gamedb.api(None) == ""
    assert gamedb.has_fsr31(str(v)) is False


def test_knowledge_matches_by_appid_exe_and_title():
    doc = gamedb.load(games.BUNDLED_GAMES)
    assert doc["schema"] == 2 and len(doc["games"]) >= 98 and len(doc["compat"]) >= 700
    k = gamedb.knowledge(doc, None, "292030")                       # The Witcher 3 by Steam app id
    assert k["known"] and k["wine_check"] and k["in_list"]
    k = gamedb.knowledge(doc, None, None, "Enshrouded")             # by title: the file name OptiScaler loads as there
    assert k["known"] and k["proxies"][0] == "winmm.dll" and k["status"] == "works"
    assert gamedb.knowledge(doc, None, "999999999", "No Such Game 12345")["known"] is False
    broken = [r for r in doc["compat"].values() if r["status"] == "broken"]
    assert broken and guard.refusal(None, None, False, {"status": "broken", "notes": "x"})["code"] == "broken"
    for g in doc["games"]:                                          # every setting is a valid OptiScaler.ini line
        for key, val in g["ini"].items():
            assert launchenv.INI_KEY_RE.match(key) and launchenv.INI_VAL_RE.match(str(val)), (g["id"], key, val)


# ---- the XMX build's other models stay off -----------------------------------------------------------------------
def test_only_the_fsr4_models_of_the_xmx_build_are_ever_selected():
    """The XMX build can also run other vendors' networks; GameCove never switches those on and never names them."""
    root = os.path.join(HERE, "..", "..", "..")
    # every way a launch is composed picks model 6 (FSR 4.1.2) or 9 (Lite), nothing else
    seen = set()
    for opti in launchenv.FSR4_XMX:
        for fg in (0, 2, 3, 4):
            env = launchenv.compose({"opti": opti, "fg": fg, "opti_fg": "dlssg" if fg else "off", "opti_dll": "dxgi"}, True, "intel")
            seen.add(env["FSR_UpscalerIndex"])
            assert not [k for k in env if k.startswith("FSR4_XMX_") and k not in ("FSR4_XMX_NO_DIALOG", "FSR4_XMX_LITE")], env
    assert seen == {"6", "9"}
    # and no source, text or doc of ours mentions the switches for the other models
    names = ("FSR4_XMX_DLSS", "FSR4_XMX_PROVIDER_INDEX", "DLSS on XMX", "DLSS on Intel XMX")
    for base, exts in (("packaging", (".py", ".sh", "")), ("app/scripts", (".gd",)), ("docs", (".md",))):
        for r, _d, files in os.walk(os.path.join(root, base)):
            if "tests" in r.split(os.sep) or "__pycache__" in r:
                continue
            for f in files:
                if os.path.splitext(f)[1] in exts and not f.endswith(".json"):
                    text = open(os.path.join(r, f), encoding="utf-8", errors="replace").read()
                    for n in names:
                        assert n not in text, (os.path.join(r, f), n)
    for f in ("README.md", "CREDITS.md"):
        text = open(os.path.join(root, f), encoding="utf-8").read()
        assert "DLSS on XMX" not in text and "FSR4_XMX_DLSS" not in text


# ---- FSR 4 on AMD and the Proton the game really ran on ------------------------------------------------------------
@pytest.mark.parametrize("name,want", [
    ("GE-Proton10-25", True), ("GE-Proton11-12", True), ("GE-Proton9-27", False), ("proton-cachyos-11.0-20261107-slr", True),
    ("Proton 11.0", False), ("Proton 9.0 (Beta)", False), ("Proton - Experimental", None), ("Proton Hotfix", None), ("", None),
    ("SteamTinkerLaunch", None),
])
def test_which_protons_run_fsr4_on_amd(name, want):
    assert active.fsr4_proton(name) is want


def test_the_readout_says_when_the_proton_cant_do_fsr4(tmp_path):
    home = str(tmp_path)
    _pkg(home)
    _steam_game(home, "401", "FsrGame", ["FsrGame.exe", "amd_fidelityfx_dx12.dll"])
    assert best.prepare(home, "401", Z1E)["did"] == "set up"
    log = os.path.join(home, ".local/share/gamecove/launch/401.log")
    assert best.status(home, "401", Z1E)["active"]["state"] == "waiting"          # not started yet: no verdict
    _start(home, "401")
    open(log, "w").write("gamecove: launch 2026-11-10 20:00:00, appid 401\ngamecove: proton /home/deck/.steam/steam/steamapps/common/Proton 11.0\n")
    a = best.status(home, "401", Z1E)["active"]
    assert a["state"] == "env_off" and a["line"].startswith("Not active: the last start ran on Proton 11.0") and "GE-Proton or Proton-CachyOS" in a["line"]
    open(log, "w").write("gamecove: proton /home/deck/.steam/root/compatibilitytools.d/GE-Proton11-12\n")
    a = best.status(home, "401", Z1E)["active"]
    assert a["state"] == "env" and a["line"].startswith("Set for the last start: FSR 4")
    open(log, "w").write("gamecove: proton /x/common/Proton - Experimental\n")
    assert best.status(home, "401", Z1E)["active"]["state"] == "env"               # can't tell: nothing is claimed either way
    os.remove(log)
    assert best.status(home, "401", Z1E)["active"]["state"] == "env"
    assert active.proton_of(log) == "" and active.proton_of(None) == ""
