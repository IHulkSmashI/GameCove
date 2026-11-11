"""ClawDeck's tests for the modules GameCove ported (ClawDeck tests/test_modules.py, same author), adapted to the
renamed paths (~/.local/share/gamecove, .gamecove-optiscaler, GAMECOVE_*). GameCove's own additions (other GPUs,
the CLI) are in test_games.py."""
import json
import os
import re
import sys
import zipfile

import pytest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from gamecove_upscale import (downloads, framegen, gamedb, launchenv, livedb,  # noqa: E402
                              optiscaler, reframework, xess, xmxscope)

ROOT = os.path.join(os.path.dirname(__file__), "..", "gamecove_upscale")

SUPPORTED_LIST_PAGE = """## Newly Supported Games
| Korean Title | English Title | Intel | AMD | NVIDIA |
|---|---|---|---|---|
| 컨트롤：레조넌트 | CONTROL Resonant | Intel Arc Series | Radeon iGPU*, RX 6/7/9000 Series | RTX 20/30/40/50 Series |
| 타이탄 퀘스트 2 | Titan Quest II | Not Supported | Not Supported | RTX 20/30/40/50 Series |
<!-- opticlick-supported-games-meta
{"schema_version": 1, "games": [
 {"game_name_en": "CONTROL Resonant", "game_id": "controlR", "cover_steam_app_id": "3669870", "cover_steam_app_ids": ["3669870"]},
 {"game_name_en": "Titan Quest II", "game_id": "tq2", "cover_steam_app_ids": ["1154030"]}]}
-->
"""

COMPAT_PAGE = """| GAME NAME | ✅/❌/➖ | DLSS/FSR3.1/XeSS | ✨ | Notes go here | [#](url) |
| Game | Compatibility | Upscaler <br>Inputs | OptiPatcher <br>Support | Notes | Images |
| ---- | :---: | :---: | :---: | ----- | :----: |
| [Enshrouded](Enshrouded) | ✅ | DLSS |  | Shimmering grass | [1](https://x) |
| [Onimusha: Way of the Sword](Onimusha-Way-of-the-Sword) | ✅ | DLSS, FSR3.1 |  | Requires [REFramework](https://github.com/praydog/REFramework-nightly) to work | |
| EA Sports WRC | ❌ | FSR2 |  | Crashes at start | |
| [CONTROL Ultimate Edition](Control-Ultimate-Edition) | ✅ | DLSS |  |  | |
"""

ENSHROUDED_PAGE = """[cols="1,1"]
|===
|**Last Tested Version**
|0.9

|**Filename**
|`winmm.dll`, `dbghelp.dll`

|**OS**
|Windows, Linux

|**Known Issues**
a|
* FSR3 inputs don't work.
* +++<s>old problem</s>+++
* On Linux you may need https://github.com/aron-w/proxy[nvlowlatencyvk-proxy] to load *OptiScaler.dll*

|**Notes**
a|
* Game runs on Vulkan.

|**Reported By**
|-
|===
"""


_REAL_DOWNLOAD = downloads.download


def _w(path, value):
    os.makedirs(os.path.dirname(str(path)), exist_ok=True)
    with open(path, "w") as f:
        f.write(f"{value}\n")


def test_launch_env_compose_and_write(tmp_path):
    # per game (the default): the XMX driver only where it helps; Per-game's switch forces it on or off
    assert launchenv.compose({}) == {}            # a game nobody touched: automatic (XeSS / OptiScaler games only)
    assert launchenv.compose({"xmx": False}) == {"GAMECOVE_XMX": "0"}
    assert launchenv.compose({"xmx": True, "low_latency": True, "fg": 0, "fsr": "off", "opti": "off"}) == {"GAMECOVE_XMX": "1"}
    # the package still session-wide (before GameCove moved its file): off = the stock drivers for this game
    off = launchenv.compose({"xmx": False}, per_game=False)
    assert off["VKD3D_DISABLE_EXTENSIONS"] == "" and "VK_DRIVER_FILES" in off
    assert launchenv.compose({"xmx": True}, per_game=False) == {}
    assert launchenv.compose({"xell": True}) == {}  # a 0.1 setting (XeLL driver mode) no longer does anything
    # the package's own launch options (xess-xmx-linux docs/launch-options.md)
    assert launchenv.compose({"fg": 4, "xess_latest": True, "low_latency": False}) == {"GAMECOVE_XMX": "1", "XESS_FG": "4", "XESS": "latest"}   # XeLL always on
    assert launchenv.compose({"fsr": "xess"}) == {"GAMECOVE_XMX": "1", "FSR": "xess"}
    assert launchenv.compose({"fsr": "fg"}) == {"GAMECOVE_XMX": "1", "FSR_FG": "xess"}
    assert launchenv.compose({"fsr": "inject"}) == {"GAMECOVE_XMX": "1", "FSR": "xess", "FSR_FG": "inject"}
    # Decky Framegen's fgmod writes these into the game's OptiScaler.ini
    assert launchenv.compose({"opti": "xess", "opti_xefg": True}) == {"GAMECOVE_XMX": "1", "Dx12Upscaler": "xess", "FrameGen_Enabled": "true", "FrameGen_FGOutput": "xefg",
                                                                      "DXVK_CONFIG": "dxgi.customVendorId = 8086"}
    assert launchenv.compose({"opti": "fsr4"}) == launchenv.compose({"opti": "fsr4_xmx"})   # INT8 retired: on XMX
    for bad in ({"fg": 1}, {"fg": 9}, {"fg": True}, {"fg": "4"}, {"fsr": "amd"}, {"opti": "dlss"}):
        with pytest.raises(ValueError):
            launchenv.compose(bad)
    r = launchenv.write(str(tmp_path), "1234", {"fg": 3})
    assert open(r["path"]).read().splitlines()[1:] == ["GAMECOVE_XMX=1", "XESS_FG=3"]
    assert launchenv.write(str(tmp_path), "1234", {"fg": 0})["path"] is None
    assert not os.path.exists(os.path.join(tmp_path, "launch", "1234.env"))
    with pytest.raises(ValueError):
        launchenv.write(str(tmp_path), "../x", {"fg": 2})


def test_xess_state_from_package_layout(tmp_path):
    home = tmp_path
    pkg = home / ".local/share/gamecove/xess-xmx-linux-1.4"
    _w(pkg / "lib/mesa-26.1.2/libvulkan_intel.so", "x")
    _w(pkg / "lib/mesa-26.3.0-rc1/libvulkan_intel.so", "x")
    _w(pkg / "lib/active", "26.3.0-rc1")
    _w(home / ".config/environment.d/50-xess-xmx.conf",
       f"VK_DRIVER_FILES={pkg}/run/intel_icd.json:/usr/share/vulkan/icd.d/intel_hasvk_icd.i686.json\n")
    _w(home / ".cache/xess-xmx/driver-status", "ok 2026-10-21 12:00:00 /x Mesa 26.3.0")
    st = xess.state(str(home))
    assert st["installed"] and st["version"] == "1.4" and st["default_driver"] == "26.3.0-rc1"
    assert st["drivers"] == ["26.1.2", "26.3.0-rc1"] and st["status"]["state"] == "ok"
    assert xess.parse_status("FAILED 2026 x: no device")["state"] == "failed"
    assert not xess.state(str(tmp_path / "nobody"))["installed"]


# ---- downloads -------------------------------------------------------------------------------------------------------
def test_downloads_refuses_unpinned_and_unsafe(tmp_path):
    with pytest.raises(PermissionError):
        downloads.fetch({"repo": "a/b", "tag": "pending-verification"}, str(tmp_path))
    bad = tmp_path / "bad.zip"
    with zipfile.ZipFile(bad, "w") as z:
        z.writestr("../evil.sh", "x")
    with pytest.raises(ValueError):
        downloads.extract(str(bad), str(tmp_path / "out"))
    good = tmp_path / "good.zip"
    with zipfile.ZipFile(good, "w") as z:
        z.writestr("pkg/install.sh", "echo")
    assert os.path.exists(os.path.join(downloads.extract(str(good), str(tmp_path / "o2")), "pkg/install.sh"))
    assert downloads.pick_asset({"assets": [{"name": "x.txt"}, {"name": "xess-xmx-linux-20261018.zip"}]},
                                "xess-xmx-linux-*.zip")["name"] == "xess-xmx-linux-20261018.zip"
    # the real asset name seen 2026-10-21 matches the glob in versions.json
    v = downloads.load_versions(os.path.join(ROOT, "data", "versions.json"))
    assert downloads.pick_asset({"assets": [{"name": "v1.zip"}, {"name": "xess-xmx-linux-20261018.zip"}]}, v["xess_xmx_linux"]["asset_glob"])["name"] == "xess-xmx-linux-20261018.zip"


def _xess_release(monkeypatch, tags, asked=None):
    """downloads.release answering {repo: tag}; a repo without one answers 404 (no release published)."""
    import urllib.error

    def rel(repo, tag):
        if asked is not None:
            asked.append(repo)
        if repo not in tags:
            raise urllib.error.HTTPError("https://api.github.com/x", 404, "Not Found", {}, None)
        return {"tag_name": tags[repo], "assets": []}
    monkeypatch.setattr(downloads, "release", rel)


def _xess_runs(monkeypatch, home, install_rc=0, check_line="ok 2026-10-22 12:00 /x/libvulkan_intel.so Mesa 26.1.2"):
    """userexec.run for install.sh and session-check.sh: the check writes driver-status as the real one does."""
    ran = []

    def run(cmd, h, timeout=600, cwd=None, env=None):
        ran.append(os.path.basename(cmd[1]) + (" " + " ".join(cmd[2:]) if cmd[2:] else ""))
        if cmd[0] == "systemctl":                 # clearing the session's variables (xmxscope.isolate_session)
            return {"rc": 0, "out": ""}
        if cmd[1].endswith("session-check.sh"):
            _w(os.path.join(home, xess.STATUS), check_line)
            return {"rc": 0 if check_line.startswith("ok") else 1, "out": check_line}
        if install_rc == 0:      # install.sh points the session at the package (environment.d)
            _w(os.path.join(home, xess.ENV_CONF), f"VK_DRIVER_FILES={cwd}/run/intel_icd.json")
        return {"rc": install_rc, "out": "== fetching\nmissing igdext64.dll - run this from the unpacked package\n" if install_rc else "done"}
    monkeypatch.setattr(xess.userexec, "run", run)
    return ran


def _xess_fetch(monkeypatch, home, fetched=None):
    def fetch(entry, workdir, allow_unpinned=False, rel=None):
        if not downloads.is_pinned(entry) and not allow_unpinned:     # as the real one: ask before an untested version
            raise PermissionError(f"{entry['repo']} has no tested version pinned yet; allow 'latest (untested)' to continue")
        if fetched is not None:
            fetched.append(entry["repo"])
        tag = rel["tag_name"]
        pkg = home / f".local/share/gamecove/xess-xmx-linux-{tag}"
        _w(pkg / "install.sh", "echo hi"); _w(pkg / "uninstall.sh", ""); _w(pkg / "tools/session-check.sh", "")
        return {"tag": tag, "archive": str(home / "a.zip"), "dir": str(pkg), "repo": entry["repo"]}
    monkeypatch.setattr(downloads, "fetch", fetch)


def test_xess_state_and_game_low_latency(tmp_path):
    home = tmp_path
    pkg = home / ".local/share/gamecove/xess-xmx-linux-20261104"
    _w(pkg / "lib/mesa-26.3.0-rc3/libvulkan_intel.so", "x"); _w(pkg / "lib/active", "26.3.0-rc3")
    _w(pkg / "docs/launch-options.md", "| `IGDEXT_XELL_CAP=off %command%` | turns the low latency off |")
    _w(pkg / xess.SOURCE_FILE, '{"repo": "HHHHanasak1/xess-xmx-linux", "tag": "20261104"}')
    _w(home / ".config/environment.d/50-xess-xmx.conf", f"VK_DRIVER_FILES={pkg}/run/intel_icd.json\n")
    st = xess.state(str(home))
    assert st["low_latency"] and st["version"] == "20261104" and st["drivers"] == ["26.3.0-rc3"]
    old = home / "old/xess-xmx-linux-20261018"
    _w(old / "docs/launch-options.md", "| `XESS_FG=3` |")
    assert not xess.has_low_latency(str(old), old.name)
    assert xess.has_low_latency(str(home / "none"), "xess-xmx-linux-20261110")   # no docs: by the date in the name
    pfx = home / xess.COMPATDATA / "42/pfx/drive_c"
    assert xess.game_latency(str(home), "42", False)["mode"] == "off"
    assert xess.game_latency(str(home), "42", True)["mode"] == "none"
    _w(pfx / "igdext_xell.log", "low latency: on\nauto: frame generation off (none), not pacing\n")
    assert xess.game_latency(str(home), "42", True)["mode"] == "no-fg"
    _w(pfx / "igdext_xell.log", "low latency: on\nauto: frame generation on (xefg), pacing\n"
       "auto: waited in 0 of 100 frames, 0.0 ms each (0.00 ms spun); last: 0.0 ms left, 2 in flight, frame 16.00 ms (uncapped 16.00), cpu 9.0 ms\n")
    assert xess.game_latency(str(home), "42", True)["mode"] == "idle"
    _w(pfx / "igdext_xell.log", "low latency: on\nauto: frame generation on (xefg), pacing\n"
       "auto: waited in 87 of 100 frames, 6.4 ms each (0.12 ms spun); last: 5.0 ms left, 3 in flight, frame 27.00 ms (uncapped 27.00), cpu 4.0 ms\n")
    lat = xess.game_latency(str(home), "42", True)
    assert lat["mode"] == "pacing" and "87 of the last 100" in lat["detail"] and "6.4 ms" in lat["detail"]
    _w(pfx / "igdext_xell.log", "low latency: off\n")
    assert xess.game_latency(str(home), "42", True)["mode"] == "off"


def test_optiscaler_from_decky_framegen_is_seen_read_only(tmp_path):
    home = tmp_path
    steam = home / xess.STEAM
    _w(steam / "steamapps/libraryfolders.vdf", f'"libraryfolders"\n{{\n "1"\n {{\n  "path"  "{tmp_path}/sd"\n }}\n}}')
    _w(home / "sd/steamapps/appmanifest_2054970.acf", '"AppState"\n{\n\t"appid"\t\t"2054970"\n\t"installdir"\t\t"Dragons Dogma 2"\n}')
    game = home / "sd/steamapps/common/Dragons Dogma 2"
    game.mkdir(parents=True)
    assert xess.optiscaler_in(str(home), "2054970") == {"present": False, "dir": str(game)}
    _w(game / "OptiScaler.ini", "[FrameGen]\nFGOutput=xefg\n")
    _w(game / "OptiScaler.log", "OptiScaler v0.9.4-final loaded")
    r = xess.optiscaler_in(str(home), "2054970")
    assert r["present"] and r["version"] == "v0.9.4-final" and r["xess_fg"]
    assert xess.optiscaler_in(str(home), "1")["present"] is False and xess.steam_install_dir(str(home), "../x") is None


def _scope_home(tmp_path):
    from gamecove_upscale import xmxscope
    _w(tmp_path / xmxscope.SESSION_CONF, "VK_DRIVER_FILES=/p/run/intel_icd.json:/usr/share/vulkan/icd.d/intel_icd.x86_64.json\n"
       "VKD3D_DISABLE_EXTENSIONS=VK_EXT_descriptor_buffer,VK_KHR_present_wait2\nINTC_ALT_DRIVER_EXTENSIONS_PATH='C:\\\\x\\\\igd_faux.inf_1'\n")
    proton = tmp_path / ".local/share/Steam/steamapps/common/Proton 11.0"
    _w(proton / "proton", "")
    _w(proton / "user_settings.py", "# xess-xmx proton hook - written by install.sh\n")
    return xmxscope, proton


def _run_scope(script, env, monkeypatch):
    for k, v in env.items():
        monkeypatch.setenv(k, v)
    g = {"__file__": str(script)}
    exec(compile(script.read_text(), str(script), "exec"), g)
    return g["user_settings"]


def test_xmx_scope_moves_the_session_file_and_keeps_its_variables(tmp_path):
    xmxscope, proton = _scope_home(tmp_path)
    r = xmxscope.isolate_session(str(tmp_path))
    assert r["moved"] and not (tmp_path / xmxscope.SESSION_CONF).exists()
    assert (tmp_path / (xmxscope.SESSION_CONF + xmxscope.PARKED_SUFFIX)).exists()          # put back by restore_session
    env = xmxscope.xmx_env(str(tmp_path))
    assert env["VK_DRIVER_FILES"].startswith("/p/run/") and env["INTC_ALT_DRIVER_EXTENSIONS_PATH"] == "C:\\\\x\\\\igd_faux.inf_1"
    assert xess.package_dir(str(tmp_path)) == "/p"                                           # still found after the move
    assert xmxscope.restore_session(str(tmp_path))["restored"] and xmxscope.session_active(str(tmp_path))


def test_xmx_scope_loads_the_driver_only_for_xess_games_or_when_forced(tmp_path, monkeypatch):
    xmxscope, proton = _scope_home(tmp_path)
    _w(proton / "user_settings.user.py", "user_settings = {'PROTON_LOG': '1'}\n")    # the user's own Proton settings
    xmxscope.isolate_session(str(tmp_path))
    r = xmxscope.install_scope(str(tmp_path))
    assert r["ok"] and r["protons"] == [str(proton)]
    assert (proton / xmxscope.PREV_PY).exists() and xmxscope.state(str(tmp_path))["per_game"]
    script = proton / xmxscope.USER_PY
    xess_game, plain_game = tmp_path / "games/Cp", tmp_path / "games/Oni"
    _w(xess_game / "bin/x64/libxess.dll", "")
    _w(plain_game / "amd_fidelityfx_dx12.dll", "")
    base = {"HOME": str(tmp_path), "GAMECOVE_RUNTIME": str(tmp_path / "rt")}
    s = _run_scope(script, {**base, "SteamAppId": "1091500", "STEAM_COMPAT_INSTALL_PATH": str(xess_game)}, monkeypatch)
    assert s["VK_DRIVER_FILES"].startswith("/p/run/") and s["PROTON_LOG"] == "1"            # XeSS game: XMX; own settings kept
    s = _run_scope(script, {**base, "SteamAppId": "2638890", "STEAM_COMPAT_INSTALL_PATH": str(plain_game)}, monkeypatch)
    assert "VK_DRIVER_FILES" not in s                                                       # no XeSS: Bazzite's own driver
    _w(tmp_path / "rt/launch/2638890.env", "GAMECOVE_XMX=1\n")                              # Per-game: on
    s = _run_scope(script, {**base, "SteamAppId": "2638890", "STEAM_COMPAT_INSTALL_PATH": str(plain_game)}, monkeypatch)
    assert "VK_DRIVER_FILES" in s
    _w(tmp_path / "rt/launch/1091500.env", "GAMECOVE_XMX=0\n")                              # Per-game: off
    s = _run_scope(script, {**base, "SteamAppId": "1091500", "STEAM_COMPAT_INSTALL_PATH": str(xess_game)}, monkeypatch)
    assert "VK_DRIVER_FILES" not in s
    monkeypatch.setattr(xmxscope.userexec, "chown_tree", lambda p, h: None)
    assert xmxscope.set_every_game(str(tmp_path), True)["every_game"]                    # Setup: every game on XMX
    other = tmp_path / "games/Plain"
    other.mkdir(parents=True)
    s = _run_scope(script, {**base, "SteamAppId": "999", "STEAM_COMPAT_INSTALL_PATH": str(other)}, monkeypatch)
    assert "VK_DRIVER_FILES" in s                                                       # a game with nothing: XMX too
    s = _run_scope(script, {**base, "SteamAppId": "1091500", "STEAM_COMPAT_INSTALL_PATH": str(xess_game)}, monkeypatch)
    assert "VK_DRIVER_FILES" not in s                                                   # switched off per game: stays off
    assert not xmxscope.set_every_game(str(tmp_path), False)["every_game"]
    assert xmxscope.remove_scope(str(tmp_path))["protons"] == [str(proton)]
    assert (proton / "user_settings.user.py").read_text().startswith("user_settings = {'PROTON_LOG'")   # theirs is back


def test_automatic_xmx_is_forced_for_hook_features():
    from gamecove_upscale import launchenv
    assert "GAMECOVE_XMX" not in launchenv.compose({})                         # automatic: the scope decides
    assert launchenv.compose({"fsr": "xess"})["GAMECOVE_XMX"] == "1"           # an FSR-only game on XeSS (CONTROL)
    assert launchenv.compose({"fg": 3})["GAMECOVE_XMX"] == "1"
    assert launchenv.compose({"xmx": False, "fsr": "xess"})["GAMECOVE_XMX"] == "0"   # an explicit off wins


def test_ships_xess_matches_the_scope_script_depth(tmp_path):
    from gamecove_upscale import xmxscope
    g = tmp_path / "game"
    _w(g / "a" / "b" / "c" / "libxess.dll", "x")
    assert xmxscope.ships_xess(str(g))
    # Unreal plugins sit 7-8 folders down (ClawDeck 4cf5cf9, DEPTH 9)
    ue = tmp_path / "ue"
    _w(ue / "Engine" / "Plugins" / "Runtime" / "Intel" / "XeSS" / "Binaries" / "ThirdParty" / "Win64" / "libxess.dll", "x")
    assert xmxscope.ships_xess(str(ue))
    deep = tmp_path / "deep"
    _w(deep.joinpath(*[str(i) for i in range(1, 11)]) / "libxess.dll", "x")   # deeper than the launch-time check looks
    assert not xmxscope.ships_xess(str(deep))
    assert not xmxscope.ships_xess(None)


def _game(tmp_path, name, files):
    d = tmp_path / name
    for f in files:
        _w(d / f, "x")
    return str(d)


def test_gamedb_recommends_by_engine_and_list(tmp_path):
    from gamecove_upscale import gamedb
    doc = gamedb.load(os.path.join(ROOT, "data", "games.json"))
    assert len(doc["games"]) > 50 and "onimushawots.exe" in doc["re_engine_exes"]
    oni = gamedb.recommend(doc, _game(tmp_path, "oni", ["OnimushaWotS.exe", "amd_fidelityfx_dx12.dll"]))
    assert oni["route"] == "re_engine" and oni["launch"]["reframework"] is True
    # OptiScaler's list says Spoofing_Dxgi=false for Onimusha, but the Capcom setup's DLSS-G needs the spoofing
    assert oni["ini"] == {"Hotfix_RestoreComputeSignature": "true"}
    assert oni["launch"]["opti_fg"] == "dlssg" and oni["fg_source"] == "dlssg" and oni["capcom"]
    assert oni["capcom_tested"] and "tested on a Claw" in " ".join(oni["reasons"])
    control = gamedb.recommend(doc, _game(tmp_path, "control", ["CONTROLResonant.exe", "amd_fidelityfx_upscaler_dx12.dll"]))
    assert control["route"] == "optiscaler" and control["optiscaler"] and "Pick FSR" in control["reasons"][0]
    own = gamedb.recommend(doc, _game(tmp_path, "x", ["game.exe", "bin/libxess.dll"]))
    assert own["route"] == "own_xess" and own["launch"] == {}
    ue = gamedb.recommend(doc, _game(tmp_path, "shf", ["SHf/Binaries/Win64/SHf-Win64-Shipping.exe"]))
    assert ue["known"] and ue["route"] == "optiscaler" and ue["launch"]["opti"] == "xess"
    from gamecove_upscale import launchenv
    env = launchenv.compose(oni["launch"])
    assert env["Hotfix_RestoreComputeSignature"] == "true" and env["WINEDLLOVERRIDES"] == "dinput8=n,b;"
    with pytest.raises(ValueError):
        launchenv.compose({"opti_ini": {"PATH": "/tmp"}})              # only Section_Key=simple value
    with pytest.raises(ValueError):
        launchenv.compose({"opti_ini": {"Spoofing_Dxgi": "false; rm -rf"}})


def test_reframework_never_overwrites_a_foreign_dinput8(tmp_path, monkeypatch):
    from gamecove_upscale import reframework, downloads
    folder = tmp_path / "g"
    _w(folder / "dinput8.dll", "reshade")
    r = reframework.install(str(tmp_path), str(folder), {"repo": "praydog/REFramework-nightly", "tag": "t1"})
    assert not r["ok"] and "isn't GameCove's" in r["error"]
    os.remove(folder / "dinput8.dll")
    src = tmp_path / "unpacked"
    _w(src / "dinput8.dll", "refw")
    monkeypatch.setattr(downloads, "fetch", lambda e, w, a=False: {"tag": "t1", "repo": e["repo"], "archive": "REFramework.zip", "dir": str(src)})
    monkeypatch.setattr(reframework.userexec, "chown_tree", lambda p, h: None)
    r = reframework.install(str(tmp_path), str(folder), {"repo": "praydog/REFramework-nightly", "tag": "t1"})
    assert r["ok"] and r["ours"] and (folder / "dinput8.dll").read_text().strip() == "refw"
    assert reframework.remove(str(folder))["removed"] and not (folder / "dinput8.dll").exists()


def test_every_listed_setting_is_a_valid_launch_variable():
    from gamecove_upscale import gamedb, launchenv
    doc = gamedb.load(os.path.join(ROOT, "data", "games.json"))
    for g in doc["games"]:
        launchenv.compose({"opti": "xess", "opti_xefg": True, "opti_ini": {**g["ini"], **g["when"].get("xefg", {})}})


def _own_cabinet(tmp_path, monkeypatch, present=True):
    """GameCove's cabinet.dll (bin/cabinet.dll in the plugin zip, built from tools/cabinet-lzms) as a stand-in."""
    from gamecove_upscale import optiscaler
    p = tmp_path / "plugin" / "bin" / "cabinet.dll"
    if present:
        _w(p, "gamecove-lzms")
    monkeypatch.setenv("GAMECOVE_CABINET", str(p))   # GameCove: own_cabinet() looks here first
    monkeypatch.setattr(optiscaler, "CABINET_PLACES", ())
    for k in ("SYSTEM_CABINET", "PACKAGE_CABINET", "CHECKOUT_CABINET"):
        monkeypatch.setattr(optiscaler, k, str(p))
    return p


def test_cabinet_comes_from_the_package_on_a_clean_install(tmp_path, monkeypatch):
    """FSR 4.1.2 on XMX with nothing but GameCove installed: no GAMECOVE_CABINET, no ClawDeck, nothing in the data
    folder. The DLL is the one the package ships (bin/ two folders above the helper, /usr/lib/gamecove/bin)."""
    from gamecove_upscale import optiscaler
    monkeypatch.setattr(optiscaler.userexec, "chown_tree", lambda p, h: None)
    monkeypatch.delenv("GAMECOVE_CABINET", raising=False)
    home = str(tmp_path / "home")
    # the rule itself: <prefix>/lib/gamecove/helpers/gamecove_upscale/optiscaler.py -> <prefix>/lib/gamecove/bin
    here = os.path.dirname(os.path.realpath(optiscaler.__file__))
    assert optiscaler.PACKAGE_CABINET == os.path.join(os.path.dirname(os.path.dirname(here)), "bin", "cabinet.dll")
    assert optiscaler.SYSTEM_CABINET == "/usr/lib/gamecove/bin/cabinet.dll"
    pkg = tmp_path / "usr" / "lib" / "gamecove" / "bin" / "cabinet.dll"
    for k in ("SYSTEM_CABINET", "CHECKOUT_CABINET"):
        monkeypatch.setattr(optiscaler, k, str(tmp_path / "absent" / k))
    monkeypatch.setattr(optiscaler, "PACKAGE_CABINET", str(pkg))
    x = tmp_path / "home" / "fsr4-xmx"
    _w(x / "amd_fidelityfx_upscaler_dx12.dll", "nitec")
    _w(x / "fsr-original.dll", "o")
    assert any("cabinet.dll" in m for m in optiscaler.fsr4_xmx_missing(home))      # not shipped: refused
    _w(pkg, "packaged-lzms")
    assert optiscaler.own_cabinet(home) == str(pkg) and optiscaler.fsr4_xmx_missing(home) == []
    # a stale copy in the data folder or ClawDeck's never wins over the packaged one
    _w(tmp_path / "home" / ".local/share/gamecove/cabinet.dll", "stale")
    _w(tmp_path / "home" / "homebrew/plugins/ClawDeck/bin/cabinet.dll", "clawdeck")
    assert optiscaler.own_cabinet(home) == str(pkg)
    _opti_pkg(home)
    g = tmp_path / "game"
    _w(g / "Game.exe", "x")
    assert optiscaler.patch(home, str(g), "0.9.4", {}, "fsr4_xmx", fsr4_xmx=True)["ok"]
    assert (g / "cabinet.dll").read_text().strip() == "packaged-lzms"
    # without the package's copy an installed ClawDeck's still works (the same bytes)
    os.remove(pkg)
    assert optiscaler.own_cabinet(home).endswith(".local/share/gamecove/cabinet.dll")


def test_fsr4_xmx_never_asks_the_user_for_cabinet_dll(tmp_path, monkeypatch):
    """nitec's two files are all the user provides; the cabinet.dll is GameCove's own. A Windows cabinet.dll left
    in ~/fsr4-xmx is not used."""
    from gamecove_upscale import optiscaler
    monkeypatch.setattr(optiscaler.userexec, "chown_tree", lambda p, h: None)
    home = str(tmp_path)
    _own_cabinet(tmp_path, monkeypatch)
    assert optiscaler.FSR4_XMX_FILES == ("amd_fidelityfx_upscaler_dx12.dll", "fsr-original.dll")
    assert optiscaler.fsr4_xmx_missing(home) == ["amd_fidelityfx_upscaler_dx12.dll", "fsr-original.dll"]
    x = tmp_path / "fsr4-xmx"
    _w(x / "amd_fidelityfx_upscaler_dx12.dll", "nitec")
    _w(x / "fsr-original.dll", "o")
    _w(x / "cabinet.dll", "windows-cab")
    assert optiscaler.fsr4_xmx_missing(home) == []
    _opti_pkg(home)
    g = tmp_path / "game"
    _w(g / "Game.exe", "x")
    assert optiscaler.patch(home, str(g), "0.9.4", {}, "fsr4_xmx", fsr4_xmx=True)["ok"]
    assert (g / "cabinet.dll").read_text().strip() == "gamecove-lzms"
    assert optiscaler.unpatch(str(g))["removed"] and not (g / "cabinet.dll").exists()
    # a source checkout without the build: it says so, and FSR 4 isn't put in
    _own_cabinet(tmp_path / "none", monkeypatch, present=False)
    miss = optiscaler.fsr4_xmx_missing(home)
    assert len(miss) == 1 and "LZMS cabinet.dll" in miss[0] and "tools/cabinet-lzms" in miss[0]
    r = optiscaler.patch(home, str(g), "0.9.4", {}, "fsr4_xmx", fsr4_xmx=True)
    assert not r["ok"] and "LZMS cabinet.dll" in r["error"]
    assert sorted(q.name for q in g.iterdir()) == ["Game.exe"]           # nothing half put in


def _opti_pkg(home, ver="0.9.4"):
    from gamecove_upscale import optiscaler
    d = os.path.join(home, optiscaler.ROOT, ver)
    for f, t in (("OptiScaler.dll", "opti"), ("OptiScaler.ini", "[Upscalers]\nDx12Upscaler=auto\n\n[Menu]\nUseHQFont=auto\n\n[Plugins]\nLoadAsiPlugins=auto\n"),
                 ("libxess.dll", "xess-opti"), ("amd_fidelityfx_upscaler_dx12.dll", "amd-fsr4"), ("D3D12_Optiscaler/D3D12Core.dll", "core"),
                 ("plugins/OptiPatcher.asi", "op"), ("setup_linux.sh", "x"), ("Licenses/x.txt", "l")):
        _w(os.path.join(d, f), t)
    return d


def test_optiscaler_patch_and_unpatch_leave_the_game_as_it_was(tmp_path, monkeypatch):
    from gamecove_upscale import optiscaler
    monkeypatch.setattr(optiscaler.userexec, "chown_tree", lambda p, h: None)
    home = str(tmp_path)
    _opti_pkg(home)
    g = tmp_path / "game" / "bin"
    _w(g / "Game.exe", "x" * 100)
    _w(g / "libxess.dll", "game-own-xess")          # the game's own file: backed up, put back
    _w(g / "dxgi.dll", "reshade")                    # a proxy name already taken: next one is used
    r = optiscaler.patch(home, str(g), "0.9.4", {"Upscalers_Dx12Upscaler": "xess", "Hotfix_RestoreComputeSignature": "true"})
    assert r["ok"] and r["dll"] == "winmm.dll" and r["dll_override"] == "winmm"
    assert (g / "winmm.dll").read_text().strip() == "opti" and (g / "dxgi.dll").read_text().strip() == "reshade"
    ini = (g / "OptiScaler.ini").read_text()
    assert "Dx12Upscaler=xess" in ini and "LoadAsiPlugins=true" in ini and "UseHQFont=false" in ini
    assert "[Hotfix]\nRestoreComputeSignature=true" in ini                     # a missing section is added
    assert (g / "plugins" / "OptiPatcher.asi").exists() and not (g / "setup_linux.sh").exists()
    assert optiscaler.owner(str(g))["owner"] == "gamecove"
    # FSR 4 on XMX: nitec's files instead of AMD's upscaler, GameCove's cabinet.dll next to the exe; then back
    x = tmp_path / "fsr4-xmx"
    for f in ("amd_fidelityfx_upscaler_dx12.dll", "fsr-original.dll", "cabinet_wine.dll"):
        _w(x / f, "nitec-" + f)
    _own_cabinet(tmp_path, monkeypatch)
    assert optiscaler.patch(home, str(g), "0.9.4", {}, "fsr4_xmx", fsr4_xmx=True)["ok"]
    assert (g / "amd_fidelityfx_upscaler_dx12.dll").read_text().strip() == "nitec-amd_fidelityfx_upscaler_dx12.dll"
    assert (g / "cabinet.dll").read_text().strip() == "gamecove-lzms" and (g / "cabinet_wine.dll").exists()
    assert "cabinet.dll" in json.loads((g / ".gamecove-optiscaler" / "manifest.json").read_text())["added"]
    assert optiscaler.patch(home, str(g), "0.9.4", {}, "xess")["ok"]
    assert not (g / "cabinet.dll").exists() and (g / "amd_fidelityfx_upscaler_dx12.dll").read_text().strip() == "amd-fsr4"
    for f in ("OptiScaler.log", "fakenvapi.log", "D3D12_Optiscaler/cache.bin"):   # written by them while the game ran
        _w(g / f, "runtime")
    assert optiscaler.unpatch(str(g))["removed"]
    assert sorted(p.name for p in g.iterdir()) == ["Game.exe", "dxgi.dll", "libxess.dll"]
    assert (g / "libxess.dll").read_text().strip() == "game-own-xess"


def _game_with_own_files(tmp_path):
    g = tmp_path / "game" / "bin"
    _w(g / "Game.exe", "x" * 100)
    _w(g / "libxess.dll", "game-own-xess")                       # replaced by OptiScaler's: backed up first
    _w(g / "amd_fidelityfx_upscaler_dx12.dll", "game-own-fsr")
    return g


def _snapshot(d):
    out = {}
    for r, _dirs, files in os.walk(d):
        for x in files:
            out[os.path.relpath(os.path.join(r, x), d)] = open(os.path.join(r, x), "rb").read()
    return out


class _Killed(BaseException):
    """The helper process stopped mid-way (SIGKILL, power loss): no except clause of the helper runs."""


@pytest.mark.parametrize("stop_at", range(1, 9))
def test_a_patch_stopped_mid_way_never_loses_a_game_file(tmp_path, monkeypatch, stop_at):
    """Review H6: the manifest was written only at the end, so a stopped patch, then a patch and Native, deleted
    the backup of the game's own file. The helper is stopped at every step of the patch in turn."""
    from gamecove_upscale import optiscaler
    monkeypatch.setattr(optiscaler.userexec, "chown_tree", lambda p, h: None)
    home = str(tmp_path)
    _opti_pkg(home)
    g = _game_with_own_files(tmp_path)
    before = _snapshot(g)
    real, calls = os.replace, {"n": 0}

    def replace(a, b):
        calls["n"] += 1
        if calls["n"] == stop_at:
            raise _Killed()
        return real(a, b)
    monkeypatch.setattr(optiscaler.os, "replace", replace)
    with pytest.raises(_Killed):
        optiscaler.patch(home, str(g), "0.9.4", {"Upscalers_Dx12Upscaler": "xess"})
    monkeypatch.setattr(optiscaler.os, "replace", real)
    # the next start sets it up again, then the player picks Native
    assert optiscaler.patch(home, str(g), "0.9.4", {"Upscalers_Dx12Upscaler": "xess"})["ok"]
    r = optiscaler.unpatch(str(g), home)
    assert r["ok"] and r["kept"] == [], r
    assert _snapshot(g) == before
    # Native straight after the stop is just as safe
    monkeypatch.setattr(optiscaler.os, "replace", replace)
    calls["n"] = 0
    with pytest.raises(_Killed):
        optiscaler.patch(home, str(g), "0.9.4", {})
    monkeypatch.setattr(optiscaler.os, "replace", real)
    assert optiscaler.unpatch(str(g), home)["ok"] and _snapshot(g) == before


def test_a_full_disk_mid_patch_puts_the_game_back(tmp_path, monkeypatch):
    import errno
    from gamecove_upscale import optiscaler
    monkeypatch.setattr(optiscaler.userexec, "chown_tree", lambda p, h: None)
    home = str(tmp_path)
    _opti_pkg(home)
    g = _game_with_own_files(tmp_path)
    before = _snapshot(g)
    real, calls = optiscaler.shutil.copyfile, {"n": 0}

    def copyfile(a, b, *k, **kw):
        calls["n"] += 1
        if calls["n"] == 3:
            raise OSError(errno.ENOSPC, "No space left on device")
        return real(a, b, *k, **kw)
    monkeypatch.setattr(optiscaler.shutil, "copyfile", copyfile)
    r = optiscaler.patch(home, str(g), "0.9.4", {})
    assert r["ok"] is False and "No space left" in r["error"] and "as they were" in r["error"]
    assert _snapshot(g) == before and optiscaler.owner(str(g))["owner"] is None


def test_the_manifest_lists_the_backup_before_the_game_file_moves(tmp_path, monkeypatch):
    from gamecove_upscale import optiscaler
    monkeypatch.setattr(optiscaler.userexec, "chown_tree", lambda p, h: None)
    home = str(tmp_path)
    _opti_pkg(home)
    g = _game_with_own_files(tmp_path)
    seen = []
    real = os.replace

    def replace(a, b):
        if b.endswith(os.path.join("backup", "libxess.dll")):
            seen.append(json.loads((g / ".gamecove-optiscaler" / "manifest.json").read_text()))
        return real(a, b)
    monkeypatch.setattr(optiscaler.os, "replace", replace)
    assert optiscaler.patch(home, str(g), "0.9.4", {})["ok"]
    assert seen and "libxess.dll" in seen[0]["backed"] and seen[0]["state"] == "patching"
    assert seen[0]["backup_sha256"]["libxess.dll"] == downloads.sha256_of(str(tmp_path / "game" / "bin" / ".gamecove-optiscaler" / "backup" / "libxess.dll"))


def test_undo_never_deletes_a_backup_it_could_not_put_back(tmp_path, monkeypatch):
    from gamecove_upscale import optiscaler
    monkeypatch.setattr(optiscaler.userexec, "chown_tree", lambda p, h: None)
    home = str(tmp_path)
    _opti_pkg(home)
    g = _game_with_own_files(tmp_path)
    assert optiscaler.patch(home, str(g), "0.9.4", {})["ok"]
    _w(g / "libxess.dll", "game-update-xess")                    # a game update put its own newer file there
    r = optiscaler.unpatch(str(g), home)
    assert r["ok"] and "libxess.dll" in r["kept"] and (g / "libxess.dll").read_text().strip() == "game-update-xess"
    assert (g / ".gamecove-optiscaler" / "backup" / "libxess.dll").read_text().strip() == "game-own-xess"   # kept, not deleted
    assert optiscaler.owner(str(g))["owner"] is None                                              # nothing of ours left


def test_native_after_saving_optiscalers_own_menu_leaves_nothing_behind(tmp_path, monkeypatch):
    """Review M: saving in OptiScaler's own menu rewrites OptiScaler.ini; undo kept it as "changed", and the folder
    then read as another tool's OptiScaler, so the game was locked out of ours after Native."""
    from gamecove_upscale import optiscaler
    monkeypatch.setattr(optiscaler.userexec, "chown_tree", lambda p, h: None)
    home = str(tmp_path)
    _opti_pkg(home)
    g = _game_with_own_files(tmp_path)
    before = _snapshot(g)
    assert optiscaler.patch(home, str(g), "0.9.4", {"Upscalers_Dx12Upscaler": "xess"})["ok"]
    with open(g / "OptiScaler.ini", "a") as f:                  # the menu's Save, in the game
        f.write("\n[Menu]\nScale=1.5\n")
    r = optiscaler.unpatch(str(g), home)
    assert r["ok"] and r["kept"] == [] and _snapshot(g) == before
    assert optiscaler.owner(str(g))["owner"] is None
    assert optiscaler.patch(home, str(g), "0.9.4", {})["ok"]    # and ours goes in again


def test_game_files_are_matched_without_case(tmp_path, monkeypatch):
    """Review low: names were compared with case, so a game's DXGI.DLL or LIBXESS.DLL wasn't seen: ours went in
    next to it as dxgi.dll / libxess.dll (two files Wine can't tell apart) and the game's was never backed up."""
    from gamecove_upscale import optiscaler
    monkeypatch.setattr(optiscaler.userexec, "chown_tree", lambda p, h: None)
    home = str(tmp_path)
    _opti_pkg(home)
    g = tmp_path / "game"
    _w(g / "Game.exe", "x" * 100)
    _w(g / "DXGI.DLL", "game-dxgi")
    _w(g / "LIBXESS.DLL", "game-own-xess")
    _w(g / "Plugins" / "game.asi", "game-plugin")
    before = _snapshot(g)
    r = optiscaler.patch(home, str(g), "0.9.4", {})
    assert r["ok"] and r["dll"] == "winmm.dll", r                  # DXGI.DLL is taken, whatever its case
    names = sorted(os.listdir(g))
    assert "libxess.dll" not in names and "plugins" not in names and "dxgi.dll" not in names, names
    assert (g / "LIBXESS.DLL").read_text().strip() == "xess-opti"   # ours, under the game's own spelling
    assert (g / "Plugins" / "OptiPatcher.asi").exists()
    _w(g / "optiscaler.LOG", "runtime")
    assert optiscaler.unpatch(str(g), home)["ok"] and _snapshot(g) == before


def test_downloads_and_lists_have_size_caps(tmp_path, monkeypatch):
    import io
    from gamecove_upscale import tls

    class Answer(io.BytesIO):
        def __enter__(self):
            return self

        def __exit__(self, *a):
            return False
    monkeypatch.setattr(tls, "urlopen", lambda req, timeout: Answer(b"x" * 5000))
    monkeypatch.setattr(downloads, "MAX_DOWNLOAD", 4096)
    dest = str(tmp_path / "big.bin")
    with pytest.raises(ValueError):
        _REAL_DOWNLOAD("https://example.com/big.bin", dest)        # the real one (conftest fakes it per test)
    assert not os.path.exists(dest) and not os.path.exists(dest + ".part")
    monkeypatch.setattr(downloads, "MAX_API", 4096)
    with pytest.raises(ValueError):
        downloads._get("https://api.github.com/x")
    monkeypatch.setattr(livedb, "MAX_LIST", 4096)
    with pytest.raises(OSError):
        livedb._get("https://raw.githubusercontent.com/wiki/x")


def test_optiscaler_never_touches_another_tools_install(tmp_path, monkeypatch):
    from gamecove_upscale import optiscaler
    home = str(tmp_path)
    _opti_pkg(home)
    g = tmp_path / "g"
    _w(g / "Game.exe", "x")
    _w(g / "OptiScaler.ini", "theirs")
    r = optiscaler.patch(home, str(g), "0.9.4", {})
    assert not r["ok"] and r["owner"] == "other" and (g / "OptiScaler.ini").read_text().strip() == "theirs"
    _w(g / "dxgi.dll.b", "backup by fgmod")
    assert optiscaler.owner(str(g))["owner"] == "decky-framegen"


def test_main_exe_dir_finds_the_real_exe(tmp_path):
    from gamecove_upscale import optiscaler
    _w(tmp_path / "Launcher.exe", "x" * 500)
    _w(tmp_path / "Game" / "Binaries" / "Win64" / "Game-Win64-Shipping.exe", "x")
    assert optiscaler.main_exe_dir(str(tmp_path)).endswith("Binaries/Win64")
    t2 = tmp_path / "two"
    _w(t2 / "unins000.exe", "x" * 900)
    _w(t2 / "bin" / "big.exe", "x" * 300)
    assert optiscaler.main_exe_dir(str(t2)).endswith("bin")


def test_main_exe_dir_skips_unreal_launcher_stubs_and_picks_dx12(tmp_path):
    """ClawDeck 4cf5cf9: Gothic 1 Remake ships a small launcher stub with the -Shipping name in its top folder (#162);
    The Witcher 3 has witcher3.exe in bin/x64 and bin/x64_dx12, and only the DX12 one has DLSS, FSR and XeSS (#141)."""
    from gamecove_upscale import optiscaler
    g = tmp_path / "gothic"
    _w(g / "Gothic-Win64-Shipping.exe", "x" * 10)
    _w(g / "Gothic" / "Binaries" / "Win64" / "Gothic-Win64-Shipping.exe", "x" * 900)
    assert optiscaler.main_exe_dir(str(g)) == str(g / "Gothic" / "Binaries" / "Win64")
    w = tmp_path / "witcher"
    _w(w / "bin" / "x64" / "witcher3.exe", "x")
    _w(w / "bin" / "x64_dx12" / "witcher3.exe", "x")
    assert optiscaler.main_exe_dir(str(w), ["witcher3.exe"]) == str(w / "bin" / "x64_dx12")


def test_optiscaler_xess_shows_the_intel_gpu_to_dxvk():
    """ClawDeck #150: OptiScaler's XeSS loads before the game's DXGI factory, so DXVK hides the Intel GPU and XeSS
    takes DP4a. Any OptiScaler XeSS gets dxgi.customVendorId = 8086, at any multiplier and without frame generation."""
    from gamecove_upscale import launchenv
    assert launchenv.compose({"opti": "xess"})["DXVK_CONFIG"] == launchenv.SHOW_INTEL
    assert "DXVK_CONFIG" not in launchenv.compose({"opti": "fsr4_xmx"})
    assert launchenv.compose({"opti": "fsr4_xmx", "fg": 3, "opti_fg": "dlssg"})["DXVK_CONFIG"] == launchenv.SHOW_INTEL


def test_installed_games_from_steam_manifests(tmp_path):
    lib2 = tmp_path / "sd" / "SteamLibrary"
    _w(tmp_path / ".local/share/Steam/steamapps/libraryfolders.vdf", f'"libraryfolders"\n{{\n "1" {{ "path" "{lib2}" }}\n}}\n')
    for lib, appid, name, d in ((tmp_path / ".local/share/Steam", "3669870", "CONTROL Resonant", "CONTROL Resonant"),
                                (lib2, "2358720", "Black Myth: Wukong", "blackmythwukong"),
                                (tmp_path / ".local/share/Steam", "3658110", "Proton 11.0", "Proton 11.0")):
        _w(lib / "steamapps" / f"appmanifest_{appid}.acf", f'"AppState"\n{{\n "appid" "{appid}"\n "name" "{name}"\n "installdir" "{d}"\n}}\n')
        (lib / "steamapps" / "common" / d).mkdir(parents=True)
    gs = xess.installed_games(str(tmp_path))
    assert [g["name"] for g in gs] == ["Black Myth: Wukong", "CONTROL Resonant"]


def test_opti_ini_follows_the_frame_generation_multiplier():
    from gamecove_upscale import launchenv
    ini = launchenv.opti_ini({"opti": "xess", "opti_fg": "upscaler", "fg": 3})     # OptiScaler's own FG: 0.9.4's count
    assert ini["XeFG_InterpolationCount"] == "2" and ini["FrameGen_FGInput"] == "upscaler"
    ini = launchenv.opti_ini({"opti": "xess", "opti_fg": "dlssg", "fg": 2})
    assert ini["XeFG_InterpolationCount"] == "1" and ini["FrameGen_FGInput"] == "dlssg" and ini["Upscalers_Dx12Upscaler"] == "xess"
    assert "XeFG_InterpolationCount" not in launchenv.opti_ini({"opti": "xess", "opti_fg": "off", "fg": 3})


def test_support_needs_an_upscaler_or_a_list_entry(tmp_path):
    from gamecove_upscale import gamedb
    doc = gamedb.load(os.path.join(ROOT, "data", "games.json"))
    assert gamedb.support(doc, _game(tmp_path, "c", ["CONTROLResonant.exe", "nvngx_dlss.dll", "amd_fidelityfx_upscaler_dx12.dll"]))["via"][:2] == ["DLSS", "FSR"]
    assert gamedb.support(doc, _game(tmp_path, "u", ["G/Plugins/DLSS/Binaries/ThirdParty/Win64/nvngx_dlss.dll", "G.exe"]))["ok"]
    assert not gamedb.support(doc, _game(tmp_path, "b", ["Brotato.exe", "data.pck"]))["ok"]          # nothing to hook


def test_is_dx12_from_libraries_or_the_exe(tmp_path):
    from gamecove_upscale import gamedb
    assert gamedb.is_dx12(_game(tmp_path, "a", ["G.exe", "amd_fidelityfx_dx12.dll"]))
    d = tmp_path / "b"
    _w(d / "Game-Win64-Shipping.exe", "MZ....D3D12.dll....")
    assert gamedb.is_dx12(str(d))
    assert not gamedb.is_dx12(_game(tmp_path, "c", ["Old.exe", "d3d9.dll"]), ["old.exe"])


def test_recommend_ignores_gamecove_optiscaler_files(tmp_path):
    """OptiScaler's own libxess.dll must not turn a DLSS game into 'ships XeSS' once GameCove set it up."""
    import json as _j
    from gamecove_upscale import gamedb
    g = tmp_path / "Game"
    g.mkdir()
    (g / "Game.exe").write_bytes(b"MZ")
    (g / "nvngx_dlss.dll").write_bytes(b"x")
    assert gamedb.recommend({"games": []}, str(g))["route"] != "own_xess"
    (g / "libxess.dll").write_bytes(b"x")
    (g / "amd_fidelityfx_dx12.dll").write_bytes(b"x")
    st = g / ".gamecove-optiscaler"
    st.mkdir()
    (st / "manifest.json").write_text(_j.dumps({"added": ["libxess.dll", "amd_fidelityfx_dx12.dll", "OptiScaler.ini"],
                                                "backed": ["amd_fidelityfx_dx12.dll"]}))
    assert gamedb.recommend({"games": []}, str(g))["route"] != "own_xess"
    assert gamedb._has(str(g), ("amd_fidelityfx_dx12.dll",))     # the game's own, backed up: still counts
    (st / "manifest.json").write_text(_j.dumps({"added": [], "backed": []}))
    assert gamedb.recommend({"games": []}, str(g))["route"] == "own_xess"


def test_fsr4_xmx_picks_4_1_2_in_optiscaler(tmp_path, monkeypatch):
    """OptiScaler lists AMD's 4.0.2 first with the B Boost files; the pick must be 4.1.2 (index 6), written into the ini."""
    from gamecove_upscale import launchenv, optiscaler
    monkeypatch.setattr(optiscaler.userexec, "chown_tree", lambda p, h: None)
    for preset, idx in (("fsr4_xmx", "6"), ("fsr4_xmx_lite", "9")):
        ini = launchenv.opti_ini({"opti": preset})
        assert ini.get("FSR_UpscalerIndex") == idx and ini.get("Upscalers_Dx12Upscaler", ini.get("Dx12Upscaler")) == "fsr31"
    home = str(tmp_path)
    _opti_pkg(home)
    x = tmp_path / "fsr4-xmx"
    for f in ("amd_fidelityfx_upscaler_dx12.dll", "fsr-original.dll"):
        _w(x / f, "nitec-" + f)
    _own_cabinet(tmp_path, monkeypatch)
    g = tmp_path / "game"
    _w(g / "Game.exe", "x")
    assert optiscaler.patch(home, str(g), "0.9.4", launchenv.opti_ini({"opti": "fsr4_xmx", "fg": 2, "opti_fg": "dlssg"}), "fsr4_xmx", fsr4_xmx=True)["ok"]
    ini = (g / "OptiScaler.ini").read_text()
    assert "UpscalerIndex=6" in ini.replace(" ", "") and "Dx12Upscaler=fsr31" in ini.replace(" ", "")
    assert "FGOutput=xefg" in ini.replace(" ", "")


def test_opti_overlay_goes_into_optiscaler_ini():
    from gamecove_upscale import launchenv
    ini = launchenv.opti_ini({"opti": "xess", "opti_overlay": 2})
    assert ini["Menu_ShowFps"] == "true" and ini["Menu_FpsOverlayType"] == "2" and ini["Menu_FpsOverlayPos"] == "1"
    assert "Menu_ShowFps" not in launchenv.opti_ini({"opti": "xess"})
    import pytest
    with pytest.raises(ValueError):
        launchenv.compose({"opti": "xess", "opti_overlay": 9})


def test_xmx_proof_reads_the_prefix(tmp_path):
    import os, time
    from gamecove_upscale import xess
    home = str(tmp_path)
    pfx = xess.prefix_dir(home, "42")
    os.makedirs(os.path.join(pfx, "igdext_kernels"))
    assert xess.xmx_proof(home, "42")["state"] == "never"
    rt = tmp_path / "rt" / "launch"
    rt.mkdir(parents=True)
    (rt / "42.started").write_text("")
    with open(os.path.join(pfx, "igdext_kernels", "map.txt"), "w") as f:
        f.write("1 aa\n2 bb\n")
    open(os.path.join(pfx, "igdext_kernels", "anv_canary"), "w").write("")
    p = xess.xmx_proof(home, "42", str(tmp_path / "rt"))
    assert p["state"] == "ok" and p["kernels"] == 2
    old = time.time() - 7200
    os.utime(os.path.join(pfx, "igdext_kernels", "anv_canary"), (old, old))
    assert xess.xmx_proof(home, "42", str(tmp_path / "rt"))["state"] == "stale"
    open(os.path.join(pfx, "igdext_kernels", "compile_failed.txt"), "w").write("k")
    assert xess.xmx_proof(home, "42")["state"] == "failed"


def _snapshot(d):
    out = {}
    for r, ds, fs in os.walk(d):
        rel = os.path.relpath(r, d)
        out[rel + "/"] = None
        for f in fs:
            with open(os.path.join(r, f), "rb") as fh:
                out[os.path.join(rel, f)] = fh.read()
    return out


def _opti_v10_pkg(home, ver="10.0.0-pre1-20261030"):
    """The v10 nightly's layout, as unpacked from OptiScaler_v10.0.0-pre1_20261030.7z (OptiPatcher added by install)."""
    from gamecove_upscale import optiscaler
    d = os.path.join(home, optiscaler.ROOT, ver)
    ini = ("[Upscalers]\nDx11Upscaler=auto\nDx12Upscaler=auto\nVulkanUpscaler=auto\n\n[FrameGen]\nEnabled=auto\nFGInput=auto\n"
           "FGOutput=auto\nFGNvngxReplacement=auto\nDisableHudless=auto\n\n[XeFG]\nInterpolationCount=auto\n"
           "OverrideInterpolationCount=auto\n\n[DLSSG]\nInterpolationCount=auto\nOverrideInterpolationCount=auto\n\n"
           "[FSR]\nUpscalerIndex=auto\n\n[NvngxFG]\nDisableHudless = auto\n\n[Libraries]\nOptiDllPath=auto\n\n[Menu]\n"
           "UseHQFont=auto\nShowFps=auto\nFpsOverlayPos=auto\nFpsOverlayType=auto\n\n[Spoofing]\nDxgi=auto\n\n[Plugins]\n"
           "LoadAsiPlugins=auto\n\n[Hotfix]\nRestoreComputeSignature=auto\n")
    from gamecove_upscale import optiscaler as _o
    _w(os.path.join(d, "OptiScaler", "fakenvapi.ini"), _o.FAKENVAPI_INI.rstrip("\n"))
    for f, t in (("OptiScaler.dll", "opti10"), ("OptiScaler.ini", ini), ("setup_linux.sh", "x"), ("setup_windows.bat", "x"),
                 ("Licenses/XeSS_LICENSE.txt", "l"), ("OptiScaler/libxess.dll", "xess10"), ("OptiScaler/libxess_fg.dll", "xefg"),
                 ("OptiScaler/libxell.dll", "xell"), ("OptiScaler/amd_fidelityfx_upscaler_dx12.dll", "amd-fsr4"),
                 ("OptiScaler/dlssg_to_fsr3_amd_is_better.dll", "nukem"), ("OptiScaler/D3D12_OptiScaler/D3D12Core.dll", "core"),
                 ("OptiScaler/Streamlined_fetcher_windows.bat", "bat"), ("OptiScaler/plugins/OptiPatcher.asi", "op"),
                 ("OptiScaler/fakenvapi.dll", "fnv")):
        _w(os.path.join(d, f), t)
    return d


def _ini(text):
    """OptiScaler.ini as {Section_Key: value}."""
    out, sec = {}, None
    for line in text.splitlines():
        line = line.strip()
        if line.startswith("[") and line.endswith("]"):
            sec = line[1:-1]
        elif "=" in line and not line.startswith(";"):
            k, v = line.split("=", 1)
            out[f"{sec}_{k.strip()}"] = v.strip()
    return out


def test_versions_pin_the_capcom_setup():
    v = downloads.load_versions(os.path.join(ROOT, "data", "versions.json"))
    ref = v["reframework"]
    assert ref["repo"] == "onehoon/REFramework" and ref["tag"] == "fork-release-18-135e7ac98b0703ef157080cbd1ee4f39e54ba8e0"
    assert ref["dll_sha256"] == "58e65e32e2a12951a81bb342a62b65079efddf56e67301ce7288d4c85daedb9b"
    assert ref["asset_glob"] == "REFramework.zip" and len(ref["sha256"]) == 64 and downloads.is_pinned(ref)
    o10 = v["optiscaler_v10"]
    assert o10["layout"] == "subfolder" and o10["tag"] == "nightly-20261030"
    assert o10["sha256"] == "db4fe2deae7edd9f6657f5cb223edc694ebdec62b52f15a3a59913f8b656c176"
    assert o10["url"].endswith("/nightly-20261030/OptiScaler_v10.0.0-pre1_20261030.7z")
    assert o10["extras"][0]["dest"] == "OptiScaler/plugins/OptiPatcher.asi"
    fnv = o10["extras"][1]
    assert fnv["name"] == "fakenvapi" and "/FakeMichau/fakenvapi/releases/download/v1.4.1/" in fnv["url"]
    assert fnv["sha256"] == "e1239f74f458e3bafd7e86fb6c02557abb267499650580c4bfbdd60815304ddd"
    assert fnv["files"] == {"fakenvapi.dll": "OptiScaler/fakenvapi.dll"} and fnv["ini"] == "OptiScaler/fakenvapi.ini"
    assert fnv["file_sha256"]["fakenvapi.dll"] == "373e73dc06e2d66e90083fde3bc99ef5c1ed0bef98d1f7eda56c8b073269c3f1"
    assert v["optiscaler"]["version"] == "0.9.4" and "layout" not in v["optiscaler"]       # everything else unchanged


def test_capcom_ini_matches_the_capcom_setup():
    from gamecove_upscale import launchenv
    launch = {"opti": "xess", "opti_fg": "dlssg", "fg": 2, "reframework": True, "opti_overlay": 2,
              "opti_ini": {"Hotfix_RestoreComputeSignature": "true", "Spoofing_Dxgi": "false"}}     # an older saved profile
    ini = launchenv.opti_ini(launch)
    want = {"Upscalers_Dx11Upscaler": "fsr31_12", "Upscalers_Dx12Upscaler": "xess", "Upscalers_VulkanUpscaler": "xess",
            "FrameGen_Enabled": "true", "FrameGen_FGInput": "DLSSG", "FrameGen_FGOutput": "XeFG",
            "FrameGen_FGNvngxReplacement": "XeFG_NVNGX", "Libraries_OptiDllPath": ".\\OptiScaler",
            "Menu_FpsOverlayType": "2", "Plugins_LoadAsiPlugins": "true", "NvngxFG_DisableHudless": "true",
            "DLSSG_OverrideInterpolationCount": "1", "Hotfix_RestoreComputeSignature": "true", "fakenvapi_UseFakenvapi": "true"}
    assert {k: ini.get(k) for k in want} == want
    assert "Spoofing_Dxgi" not in ini and "XeFG_InterpolationCount" not in ini and "FramerateLimit" not in str(ini)
    assert "Spoofing_Dxgi" not in launchenv.compose(launch)                  # nor through the launch environment
    assert launchenv.opti_ini({**launch, "fg": 4})["DLSSG_OverrideInterpolationCount"] == "3"
    assert launchenv.opti_ini({**launch, "fg": None})["DLSSG_OverrideInterpolationCount"] == "2"   # the tested value
    off = launchenv.opti_ini({**launch, "opti_fg": "off", "fg": None})
    assert off["FrameGen_Enabled"] == "false" and "DLSSG_OverrideInterpolationCount" not in off
    lite = launchenv.opti_ini({**launch, "opti": "fsr4_xmx_lite"})
    assert lite["Upscalers_Dx12Upscaler"] == "fsr31" and lite["FSR_UpscalerIndex"] == "9" and "FSR_Fsr4Update" not in lite
    assert launchenv.opti_ini({**launch, "opti": "fsr4_xmx"})["FSR_UpscalerIndex"] == "6"
    assert launchenv.compose(launch)["WINEDLLOVERRIDES"] == "dinput8=n,b;"


def test_non_capcom_game_is_unchanged():
    """A DLSS game without REFramework at 2x: OptiScaler 0.9.4 lines as before, flat layout, Spoofing kept from the list."""
    from gamecove_upscale import launchenv
    launch = {"opti": "xess", "opti_fg": "dlssg", "fg": 2, "opti_ini": {"Spoofing_Dxgi": "false"}}
    assert not launchenv.capcom(launch)
    ini = launchenv.opti_ini(launch)
    assert ini == {"Upscalers_Dx12Upscaler": "xess", "FrameGen_Enabled": "true", "FrameGen_FGInput": "dlssg",
                   "FrameGen_FGOutput": "xefg", "Spoofing_Dxgi": "false", "XeFG_InterpolationCount": "1"}
    assert launchenv.opti_ini({"opti": "fsr4_xmx"})["FSR_Fsr4Update"] == "true"


def test_capcom_layout_round_trip_leaves_the_folder_exactly_as_it_was(tmp_path, monkeypatch):
    from gamecove_upscale import launchenv, optiscaler, reframework
    monkeypatch.setattr(optiscaler.userexec, "chown_tree", lambda p, h: None)
    monkeypatch.setattr(reframework.userexec, "chown_tree", lambda p, h: None)
    home = str(tmp_path)
    ver = "10.0.0-pre1-20261030"
    _opti_v10_pkg(home, ver)
    g = tmp_path / "common" / "Onimusha"
    _w(g / "OnimushaWotS.exe", "x" * 100)
    _w(g / "amd_fidelityfx_dx12.dll", "capcom-fsr")             # the game's own
    _w(g / "natives" / "x.pak", "data")
    before = _snapshot(str(g))
    launch = {"opti": "xess", "opti_fg": "dlssg", "fg": 2, "reframework": True, "opti_ini": {"Hotfix_RestoreComputeSignature": "true"}}
    r = optiscaler.patch(home, str(g), ver, launchenv.opti_ini(launch), "xess", layout="subfolder")
    assert r["ok"] and r["dll"] == "dxgi.dll" and r["layout"] == "subfolder"
    top = sorted(p.name for p in g.iterdir())
    assert top == [".gamecove-optiscaler", "OnimushaWotS.exe", "OptiScaler", "OptiScaler.ini", "amd_fidelityfx_dx12.dll", "dxgi.dll", "natives"]
    assert (g / "dxgi.dll").read_text().strip() == "opti10" and (g / "OptiScaler" / "libxess.dll").read_text().strip() == "xess10"
    assert (g / "OptiScaler" / "plugins" / "OptiPatcher.asi").exists() and (g / "OptiScaler" / "D3D12_OptiScaler" / "D3D12Core.dll").exists()
    assert not (g / "OptiScaler" / "Streamlined_fetcher_windows.bat").exists() and not (g / "Licenses").exists()
    fnv = (g / "OptiScaler" / "fakenvapi.ini").read_text()
    assert (g / "OptiScaler" / "fakenvapi.dll").exists() and not (g / "fakenvapi.dll").exists()
    assert [l for l in fnv.splitlines() if l] == ["[fakenvapi]", "enable_logs=1", "enable_trace_logs=0", "force_latencyflex=0", "force_reflex=0"]
    ini = _ini((g / "OptiScaler.ini").read_text())
    assert ini["Libraries_OptiDllPath"] == ".\\OptiScaler" and ini["FrameGen_FGOutput"] == "XeFG" and ini["NvngxFG_DisableHudless"] == "true"
    assert ini["Spoofing_Dxgi"] == "auto" and ini["DLSSG_OverrideInterpolationCount"] == "1" and ini["Plugins_LoadAsiPlugins"] == "true"
    m = json.loads((g / ".gamecove-optiscaler" / "manifest.json").read_text())
    assert m["layout"] == "subfolder" and "OptiScaler" in m["dirs"]
    assert {"OptiScaler/fakenvapi.dll", "OptiScaler/fakenvapi.ini"} <= set(m["added"])
    # FSR 4.1.2 on XMX: nitec's two files into OptiScaler/, cabinet next to the exe; then back to XeSS
    x = tmp_path / "fsr4-xmx"
    for f in ("amd_fidelityfx_upscaler_dx12.dll", "fsr-original.dll", "cabinet_wine.dll"):
        _w(x / f, "nitec-" + f)
    _own_cabinet(tmp_path, monkeypatch)
    assert optiscaler.patch(home, str(g), ver, launchenv.opti_ini({**launch, "opti": "fsr4_xmx"}), "fsr4_xmx", True, "subfolder")["ok"]
    assert (g / "OptiScaler" / "amd_fidelityfx_upscaler_dx12.dll").read_text().strip() == "nitec-amd_fidelityfx_upscaler_dx12.dll"
    assert (g / "OptiScaler" / "fsr-original.dll").exists() and not (g / "fsr-original.dll").exists()
    assert (g / "cabinet.dll").read_text().strip() == "gamecove-lzms" and (g / "cabinet_wine.dll").exists()
    assert not (g / "OptiScaler" / "cabinet.dll").exists()           # cabinet loads from the exe's folder
    assert not (g / "amd_fidelityfx_upscaler_dx12.dll").exists()
    assert optiscaler.patch(home, str(g), ver, launchenv.opti_ini(launch), "xess", layout="subfolder")["ok"]
    assert (g / "OptiScaler" / "amd_fidelityfx_upscaler_dx12.dll").read_text().strip() == "amd-fsr4"
    assert not (g / "OptiScaler" / "fsr-original.dll").exists() and not (g / "cabinet.dll").exists()
    # REFramework next to it, its menu key moved off Insert
    src = tmp_path / "unpacked"
    _w(src / "dinput8.dll", "onehoon-ref")
    monkeypatch.setattr(downloads, "fetch", lambda e, w, a=False: {"tag": e["tag"], "repo": e["repo"], "archive": "REFramework.zip", "dir": str(src)})
    entry = {"repo": "onehoon/REFramework", "tag": "fork-release-15-854e42d58b97be792c8ce441e4bdc691684e5866"}
    assert reframework.install(home, str(g), entry)["ok"]
    assert (g / "re2_fw_config.txt").read_text() == "REFrameworkConfig_MenuKey_V2=46\n"
    # what they write while the game runs
    for f in ("OptiScaler.log", "OptiScaler/D3D12_OptiScaler/cache.bin", "OptiScaler/plugins/OptiPatcher.log", "reframework_log.txt"):
        _w(g / f, "runtime")
    (g / "reframework" / "autorun").mkdir(parents=True)
    _w(g / "re2_fw_config.txt", "REFrameworkConfig_MenuKey_V2=46\nREFrameworkConfig_FontSize=16\n")   # REF saved its config
    assert reframework.remove(str(g))["removed"]
    assert optiscaler.unpatch(str(g))["removed"]
    assert _snapshot(str(g)) == before


def test_capcom_switch_from_the_old_flat_setup_takes_it_out_first(tmp_path, monkeypatch):
    """An Onimusha set up by GameCove 0.2 (0.9.4, flat) moves to v10 in OptiScaler/ with nothing of 0.9.4 left."""
    from gamecove_upscale import optiscaler
    monkeypatch.setattr(optiscaler.userexec, "chown_tree", lambda p, h: None)
    home = str(tmp_path)
    _opti_pkg(home)
    _opti_v10_pkg(home)
    g = tmp_path / "oni"
    _w(g / "OnimushaWotS.exe", "x")
    before = _snapshot(str(g))
    assert optiscaler.patch(home, str(g), "0.9.4", {})["ok"] and (g / "libxess.dll").exists()
    assert optiscaler.patch(home, str(g), "10.0.0-pre1-20261030", {}, layout="subfolder")["ok"]
    assert not (g / "libxess.dll").exists() and not (g / "plugins").exists() and (g / "OptiScaler" / "libxess.dll").exists()
    assert optiscaler.owner(str(g))["version"] == "10.0.0-pre1-20261030"
    assert optiscaler.unpatch(str(g))["removed"] and _snapshot(str(g)) == before


def test_reframework_menu_key_touches_only_its_line(tmp_path, monkeypatch):
    from gamecove_upscale import reframework
    monkeypatch.setattr(reframework.userexec, "chown_tree", lambda p, h: None)
    g = tmp_path / "g"
    _w(g / "re9.exe", "x")
    user = "FontSize=20\r\nREFrameworkConfig_MenuKey_V2=45\r\nREFrameworkConfig_Theme=dark\r\n"
    (g / "re2_fw_config.txt").write_bytes(user.encode())
    (g / "reframework" / "autorun").mkdir(parents=True)
    _w(g / "reframework" / "autorun" / "mine.lua", "-- the user's script")
    before = _snapshot(str(g))
    src = tmp_path / "unpacked"
    _w(src / "dinput8.dll", "ref")
    monkeypatch.setattr(downloads, "fetch", lambda e, w, a=False: {"tag": e["tag"], "repo": e["repo"], "archive": "REFramework.zip", "dir": str(src)})
    assert reframework.install(str(tmp_path), str(g), {"repo": "onehoon/REFramework", "tag": "t15"})["ok"]
    assert (g / "re2_fw_config.txt").read_bytes() == user.replace("_V2=45", "_V2=46").encode()
    assert reframework.remove(str(g))["removed"]
    assert _snapshot(str(g)) == before                                   # the user's config and scripts as they were
    # a config without the line: added, then taken out again
    (g / "re2_fw_config.txt").write_text("FontSize=20\n")
    assert reframework.install(str(tmp_path), str(g), {"repo": "onehoon/REFramework", "tag": "t15"})["ok"]
    assert (g / "re2_fw_config.txt").read_text() == "FontSize=20\nREFrameworkConfig_MenuKey_V2=46\n"
    assert reframework.remove(str(g))["removed"] and (g / "re2_fw_config.txt").read_text() == "FontSize=20\n"


def test_reframework_comes_from_the_fork_and_replaces_gamecoves_older_copy(tmp_path, monkeypatch):
    from gamecove_upscale import reframework
    monkeypatch.setattr(reframework.userexec, "chown_tree", lambda p, h: None)
    v = downloads.load_versions(os.path.join(ROOT, "data", "versions.json"))
    seen = []
    g = tmp_path / "g"
    _w(g / "OnimushaWotS.exe", "x")
    for tag, body in (("nightly-01433", "praydog"), (v["reframework"]["tag"], "onehoon")):
        _w(tmp_path / tag / "dinput8.dll", body)
    def fetch(e, w, a=False):
        seen.append(e["repo"])
        return {"tag": e["tag"], "repo": e["repo"], "archive": "REFramework.zip", "dir": str(tmp_path / e["tag"])}
    monkeypatch.setattr(downloads, "fetch", fetch)
    assert reframework.install(str(tmp_path), str(g), {"repo": "praydog/REFramework-nightly", "tag": "nightly-01433"}, menu_key=None)["ok"]
    r = reframework.install(str(tmp_path), str(g), {k: v["reframework"][k] for k in ("repo", "tag", "asset_glob")})
    assert r["ok"] and r["tag"] == v["reframework"]["tag"] and (g / "dinput8.dll").read_text().strip() == "onehoon"
    assert seen[-1] == "onehoon/REFramework"
    assert reframework.install(str(tmp_path), str(g), {"repo": "onehoon/REFramework", "tag": v["reframework"]["tag"]})["already"]
    # the pinned dll's own sha256 is checked too: a wrong one installs nothing
    assert reframework.remove(str(g))["removed"]
    r = reframework.install(str(tmp_path), str(g), {"repo": "onehoon/REFramework", "tag": v["reframework"]["tag"], "dll_sha256": "0" * 64})
    assert not r["ok"] and "sha256" in r["error"] and not (g / "dinput8.dll").exists()


def test_fsr4_is_never_offered_without_xmx():
    from gamecove_upscale import launchenv
    for preset in ("fsr4_xmx", "fsr4_xmx_lite", "fsr4"):
        with pytest.raises(ValueError, match="XMX"):
            launchenv.compose({"opti": preset, "xmx": False})
        launchenv.compose({"opti": preset})                                 # automatic: fine
    launchenv.compose({"opti": "xess", "xmx": False})                        # XeSS without XMX: DP4a, allowed


def test_capcom_route_for_every_re_engine_game_dd2_untested(tmp_path):
    from gamecove_upscale import gamedb
    doc = gamedb.load(os.path.join(ROOT, "data", "games.json"))
    assert "dd2.exe" in doc["capcom"]["untested"] and "onimushawots.exe" in doc["capcom"]["tested"]
    dd2 = gamedb.recommend(doc, _game(tmp_path, "dd2", ["DD2.exe", "nvngx_dlss.dll"]))
    assert dd2["route"] == "re_engine" and dd2["launch"]["reframework"] and dd2["capcom_tested"] is None
    assert "not tested on a Claw" in " ".join(dd2["reasons"]) and "Spoofing_Dxgi" not in dd2["ini"]
    wukong = gamedb.recommend(doc, _game(tmp_path, "w", ["b1/Binaries/Win64/b1-Win64-Shipping.exe", "nvngx_dlss.dll"]))
    assert not wukong["re_engine"] and "reframework" not in wukong["launch"]


def test_capcom_subfolder_files_dont_count_as_the_games(tmp_path, monkeypatch):
    """v10's libraries in OptiScaler/ must not make Onimusha 'ships XeSS' or 'ships FSR 3.1' once set up."""
    from gamecove_upscale import gamedb, optiscaler
    monkeypatch.setattr(optiscaler.userexec, "chown_tree", lambda p, h: None)
    home = str(tmp_path)
    _opti_v10_pkg(home)
    g = tmp_path / "oni"
    _w(g / "OnimushaWotS.exe", "x")
    assert optiscaler.patch(home, str(g), "10.0.0-pre1-20261030", {}, layout="subfolder")["ok"]
    assert not gamedb._has(str(g), ("libxess*",)) and not gamedb._has(str(g), ("amd_fidelityfx_upscaler_dx12.dll",))


def test_v10_install_takes_fakenvapi_out_of_its_release_archive(tmp_path, monkeypatch):
    """optiscaler.install with the v10 entry: OptiPatcher as a file, fakenvapi.dll out of fakenvapi's .7z (its own
    sha256 checked) and the tested fakenvapi.ini, all in OptiScaler/ of the package."""
    import hashlib, shutil, subprocess
    from gamecove_upscale import optiscaler
    if not (shutil.which("7z") or shutil.which("7za")):
        pytest.skip("needs 7z")
    monkeypatch.setattr(optiscaler.userexec, "chown_tree", lambda p, h: None)
    src = tmp_path / "src"
    _w(src / "opti" / "OptiScaler.dll", "o")
    _w(src / "opti" / "OptiScaler.ini", "[Upscalers]")
    _w(src / "fnv" / "fakenvapi.dll", "fnv-1.4.1")
    _w(src / "fnv" / "fakenvapi.ini", "theirs")
    seven = shutil.which("7z") or shutil.which("7za")
    files = {}
    for name, d in (("opti.7z", "opti"), ("fakenvapi-v1.4.1.7z", "fnv")):
        subprocess.run([seven, "a", "-y", str(tmp_path / name), "."], cwd=src / d, check=True, capture_output=True)
        files[name] = str(tmp_path / name)
    _w(tmp_path / "OptiPatcher.asi", "op")
    files["OptiPatcher.asi"] = str(tmp_path / "OptiPatcher.asi")
    sha = lambda p: hashlib.sha256(open(p, "rb").read()).hexdigest()
    monkeypatch.setattr(downloads, "download", lambda url, dest, timeout=60.0: shutil.copyfile(files[os.path.basename(url)], dest) and dest)
    entry = {"version": "10", "url": "https://x/opti.7z", "sha256": sha(files["opti.7z"]), "layout": "subfolder", "extras": [
        {"name": "OptiPatcher", "url": "https://x/OptiPatcher.asi", "sha256": sha(files["OptiPatcher.asi"]), "dest": "OptiScaler/plugins/OptiPatcher.asi"},
        {"name": "fakenvapi", "url": "https://x/fakenvapi-v1.4.1.7z", "sha256": sha(files["fakenvapi-v1.4.1.7z"]),
         "files": {"fakenvapi.dll": "OptiScaler/fakenvapi.dll"}, "file_sha256": {"fakenvapi.dll": sha(src / "fnv" / "fakenvapi.dll")},
         "ini": "OptiScaler/fakenvapi.ini"}]}
    home = str(tmp_path / "home")
    r = optiscaler.install(home, entry)
    assert r["ok"], r
    pkg = optiscaler.package_dir(home, "10")
    assert open(os.path.join(pkg, "OptiScaler", "fakenvapi.dll")).read().strip() == "fnv-1.4.1"
    assert open(os.path.join(pkg, "OptiScaler", "fakenvapi.ini")).read() == optiscaler.FAKENVAPI_INI
    assert optiscaler.extras_ready(home, entry) and optiscaler.install(home, entry)["already"]
    # a fakenvapi.dll that doesn't match its pin installs nothing
    entry["version"] = "10b"
    entry["extras"][1]["file_sha256"] = {"fakenvapi.dll": "0" * 64}
    r = optiscaler.install(home, entry)
    assert not r["ok"] and "sha256" in r["error"] and not optiscaler.installed(home, "10b")


def test_supported_list_gives_the_intel_column_by_steam_app_id():
    from gamecove_upscale import livedb
    e = livedb.parse_supported_list(SUPPORTED_LIST_PAGE)
    assert e["3669870"]["intel"] == "Intel Arc Series" and e["1154030"]["intel"] == "Not Supported"
    assert livedb.supported_list_says(e, "3669870")["intel_ok"] is True
    assert livedb.supported_list_says(e, "1154030")["intel_ok"] is False
    assert livedb.supported_list_says(e, "42") == {"known": True, "listed": False, "intel_ok": None}
    assert livedb.supported_list_says({}, "42")["known"] is False


def test_live_lists_refresh_and_newer_games_json_wins(tmp_path):
    from gamecove_upscale import livedb
    bundled = tmp_path / "games.json"
    bundled.write_text(json.dumps({"schema": 1, "generated": "2026-11-05T00:00:00Z", "games": []}))
    newer = json.dumps({"schema": 1, "generated": "2026-11-06T00:00:00Z", "games": [{"id": "x"}]}).encode()
    # GameCove: games.json only through the signed index (signed=), never from an unsigned URL
    pages = {livedb.SUPPORTED_LIST_URL: SUPPORTED_LIST_PAGE.encode(), livedb.OPTISCALER_COMPAT_URL: COMPAT_PAGE.encode()}
    assert not hasattr(livedb, "GAMES_URL")
    out = livedb.refresh(str(tmp_path / "lists"), str(bundled), get=lambda u: pages[u], signed=lambda: newer)
    assert out == {"games": "updated", "supported_list": "updated", "optiscaler": "updated"}
    assert livedb.games_path(str(tmp_path / "lists"), str(bundled)).startswith(str(tmp_path / "lists"))
    assert "1154030" in livedb.supported_list(str(tmp_path / "lists"))
    # fresh: no second download
    assert livedb.refresh(str(tmp_path / "lists"), str(bundled), get=lambda u: 1 / 0) == {}
    # another schema or an older list is never used; a failed download keeps the copy
    other = json.dumps({"schema": 2, "generated": "2027", "games": []}).encode()
    out = livedb.refresh(str(tmp_path / "lists"), str(bundled), force=True, get=lambda u: b"nothing", signed=lambda: other)
    assert out["games"] == "other schema, kept" and "kept" in out["supported_list"] and "kept" in out["optiscaler"]
    assert "1154030" in livedb.supported_list(str(tmp_path / "lists"))
    bundled.write_text(json.dumps({"schema": 1, "generated": "2026-12-01T00:00:00Z", "games": []}))
    assert livedb.games_path(str(tmp_path / "lists"), str(bundled)) == str(bundled)
    # no signed list (no index yet, or it names none): the bundled one, nothing fetched
    assert livedb.refresh(str(tmp_path / "l2"), str(bundled), get=lambda u: pages[u])["games"] == "bundled"
    assert livedb.refresh(str(tmp_path / "l3"), str(bundled), get=lambda u: pages[u], signed=lambda: None)["games"] == "bundled"


def test_shipped_lists_upscaler_fg_and_latency(tmp_path):
    from gamecove_upscale import gamedb
    g = tmp_path / "game"
    (g / "bin").mkdir(parents=True)
    for f in ("libxess.dll", "libxess_fg.dll", "libxell.dll", "nvngx_dlss.dll", "sl.reflex.dll"):
        (g / "bin" / f).write_bytes(b"x")
    s = gamedb.shipped(str(g))
    assert s == {"upscaler": ["DLSS", "XeSS"], "fg": ["XeSS-FG"], "latency": ["Reflex", "XeLL"]}
    rec = gamedb.recommend({"games": [], "re_engine_exes": []}, str(g))
    assert rec["route"] == "own_xess" and "XeSS frame generation and XeLL" in rec["reasons"][0]


def test_optiscaler_compat_list_rows_and_a_games_entry(tmp_path):
    from gamecove_upscale import livedb
    c = livedb.parse_compat(COMPAT_PAGE)
    assert set(c) == {"enshrouded", "onimushawayofthesword", "easportswrc", "controlultimateedition"}
    assert c["easportswrc"]["status"] == "broken" and c["easportswrc"]["slug"] is None
    assert c["onimushawayofthesword"]["reframework"] and not c["enshrouded"]["reframework"]
    assert livedb.find_compat(c, "Onimusha: Way of the Sword")["slug"] == "Onimusha-Way-of-the-Sword"
    assert livedb.find_compat(c, "CONTROL Ultimate Edition")["name"] == "CONTROL Ultimate Edition"
    assert livedb.find_compat(c, "Some Other Game") is None
    p = livedb.parse_page(ENSHROUDED_PAGE)
    assert p["proxies"] == ["winmm.dll", "dbghelp.dll"] and p["tested_on_linux"]
    assert p["issues"] == ["FSR3 inputs don't work.", "On Linux you may need nvlowlatencyvk-proxy to load OptiScaler.dll"]
    got = livedb.game_page(str(tmp_path), "Enshrouded", get=lambda u: ENSHROUDED_PAGE.encode())
    assert got["proxies"] == ["winmm.dll", "dbghelp.dll"]
    assert livedb.game_page(str(tmp_path), "Enshrouded", get=lambda u: 1 / 0)["proxies"]   # cached: no fetch
    assert livedb.game_page(str(tmp_path), "../etc", get=lambda u: b"") is None


def test_patch_takes_the_games_own_proxy_name_first(tmp_path, monkeypatch):
    from gamecove_upscale import optiscaler
    monkeypatch.setattr(optiscaler.userexec, "chown_tree", lambda p, h: None)
    home = str(tmp_path)
    _opti_pkg(home)
    g = tmp_path / "game"
    _w(g / "Game.exe", "x")
    _w(g / "winmm.dll", "games-own")                 # the entry's first name is taken: its second one
    r = optiscaler.patch(home, str(g), "0.9.4", {}, proxies=["winmm.dll", "dbghelp.dll", "d3d12.dll"])
    assert r["ok"] and r["dll"] == "dbghelp.dll" and (g / "winmm.dll").read_text().strip() == "games-own"
    g2 = tmp_path / "game2"
    _w(g2 / "Game.exe", "x")
    assert optiscaler.patch(home, str(g2), "0.9.4", {}, proxies=["d3d12.dll"])["dll"] == "dxgi.dll"   # not ours: default


def test_reframework_remove_takes_a_pinned_build_without_the_mark_and_leaves_others(tmp_path):
    from gamecove_upscale import downloads, reframework
    g = tmp_path / "game"
    g.mkdir()
    (g / "dinput8.dll").write_bytes(b"the pinned REFramework")
    sha = downloads.sha256_of(str(g / "dinput8.dll"))
    assert reframework.remove(str(g))["removed"] is False and (g / "dinput8.dll").exists()   # no known builds given
    r = reframework.remove(str(g), (sha,))
    assert r["removed"] and r["unmarked"] and not (g / "dinput8.dll").exists()
    (g / "dinput8.dll").write_bytes(b"some other dinput8")
    r = reframework.remove(str(g), (sha,))
    assert r["removed"] is False and r["present"] and (g / "dinput8.dll").exists()


@pytest.mark.parametrize("dll", ["ffx_fsr2_api_x64.dll", "ffx_fsr3upscaler_x64.dll", "amd_fidelityfx_upscaler_vk.dll"])
def test_fsr2_and_fsr3_games_get_optiscaler_on_xmx(tmp_path, dll):
    from gamecove_upscale import gamedb
    g = tmp_path / "game"
    g.mkdir()
    (g / dll).write_bytes(b"x")
    doc = {"games": [], "re_engine_exes": []}
    assert gamedb.support(doc, str(g)) == {"ok": True, "via": ["FSR"]}
    rec = gamedb.recommend(doc, str(g))
    assert rec["route"] == "optiscaler" and rec["launch"]["opti"] == "xess" and rec["ships"]["upscaler"] == ["FSR"]
    assert "Pick FSR in the game's graphics menu" in rec["reasons"][0]


def test_3x_4x_stay_on_optiscaler_0_9_4_and_xess_fg():
    from gamecove_upscale import launchenv
    for fg in (2, 3, 4):
        launch = {"opti": "xess", "opti_fg": "dlssg", "fg": fg}
        assert not launchenv.v10(launch)
        assert launchenv.opti_ini(launch)["XeFG_InterpolationCount"] == str(fg - 1)
        assert launchenv.compose(launch)["XESS_FG"] == str(fg)


def test_3x_4x_through_optiscaler_show_the_intel_gpu_to_xess_fg():
    """Proton 11.0's DXVK hides the Intel GPU from XeSS games; XeSS-FG then caps itself at 2x (CONTROL, 2026-11-05)."""
    from gamecove_upscale import launchenv
    show = "dxgi.customVendorId = 8086"
    assert launchenv.compose({"opti": "fsr4_xmx", "opti_fg": "dlssg", "fg": 3})["DXVK_CONFIG"] == show
    assert launchenv.compose({"opti": "xess", "opti_xefg": True, "fg": 4})["DXVK_CONFIG"] == show
    # 2x needs no override; a game's own XeSS (no OptiScaler) keeps DXVK's hiding (its older XeSS-FG crashes)
    # GameCove (ClawDeck #150): OptiScaler's own XeSS always shows the Intel GPU, or XeSS takes DP4a under Proton 11
    assert launchenv.compose({"opti": "xess", "opti_fg": "dlssg", "fg": 2})["DXVK_CONFIG"] == show
    assert "DXVK_CONFIG" not in launchenv.compose({"opti": "fsr4_xmx", "opti_fg": "dlssg", "fg": 2})
    assert "DXVK_CONFIG" not in launchenv.compose({"fg": 4, "xess_latest": True})
    assert "DXVK_CONFIG" not in launchenv.compose({"opti": "fsr4_xmx", "opti_fg": "off", "fg": 3})



def test_fsr4_xmx_files_are_taken_from_downloads_as_a_pair_or_a_zip(tmp_path, monkeypatch):
    import zipfile
    from gamecove_upscale import optiscaler
    monkeypatch.setattr(optiscaler.userexec, "chown_tree", lambda p, h: None)
    home = tmp_path / "h"
    (home / "Downloads" / "game").mkdir(parents=True)
    (home / "Downloads" / "game" / "amd_fidelityfx_upscaler_dx12.dll").write_bytes(b"a game's own")   # alone: not taken
    assert optiscaler.fsr4_xmx_import(str(home))["imported"] is False
    with zipfile.ZipFile(home / "Downloads" / "FSR412_XMX.zip", "w") as z:
        z.writestr("FSR 4.1.2/amd_fidelityfx_upscaler_dx12.dll", b"nitec")
        z.writestr("FSR 4.1.2/fsr-original.dll", b"amd")
    r = optiscaler.fsr4_xmx_import(str(home))
    assert r["imported"] and (home / "fsr4-xmx" / "amd_fidelityfx_upscaler_dx12.dll").read_bytes() == b"nitec"
    assert (home / "fsr4-xmx" / "fsr-original.dll").read_bytes() == b"amd"
    assert optiscaler.fsr4_xmx_import(str(home))["imported"] is False          # already there


def test_fsr4_xmx_download_checks_each_sha256(tmp_path, monkeypatch):
    import hashlib
    from gamecove_upscale import downloads, optiscaler
    monkeypatch.setattr(optiscaler.userexec, "chown_tree", lambda p, h: None)
    body = {"amd_fidelityfx_upscaler_dx12.dll": b"nitec", "fsr-original.dll": b"amd"}
    entry = {"repo": "o/r", "tag": "t", "files": {k: hashlib.sha256(v).hexdigest() for k, v in body.items()}}
    urls = []

    def fake(url, dest, timeout=0):
        urls.append(url)
        open(dest, "wb").write(body[url.rsplit("/", 1)[1]])
        return dest
    monkeypatch.setattr(downloads, "download", fake)
    r = optiscaler.fsr4_xmx_download(str(tmp_path), entry)
    assert r["ok"] and sorted(r["downloaded"]) == sorted(body)
    assert urls[0].startswith("https://github.com/o/r/releases/download/t/")
    assert optiscaler.fsr4_xmx_download(str(tmp_path), entry)["downloaded"] == []          # already there
    entry["files"]["fsr-original.dll"] = "0" * 64
    (tmp_path / "fsr4-xmx" / "fsr-original.dll").unlink()
    r = optiscaler.fsr4_xmx_download(str(tmp_path), entry)
    assert not r["ok"] and not (tmp_path / "fsr4-xmx" / "fsr-original.dll").exists()


def test_game_latency_reports_xells_own_average(tmp_path, monkeypatch):
    from gamecove_upscale import xess
    d = tmp_path / "pfx" / "drive_c"
    d.mkdir(parents=True)
    monkeypatch.setattr(xess, "prefix_dir", lambda home, appid: str(d))
    (d / "igdext_xell.log").write_text(
        "low latency: on (auto)\nauto: frame generation on (xefg), pacing\n"
        "auto: waited in 100 of 100 frames, 10.1 ms each (0.22 ms spun)\n"
        "xell latency: simulation start -> present end avg 28.6 ms (sim -> render submit 8.9 ms) over 62 frames\n"
        "xell latency: simulation start -> present end avg 33.4 ms (sim -> render submit 12.4 ms) over 63 frames\n")
    r = xess.game_latency(str(tmp_path), "1", True)
    assert r["mode"] == "pacing" and r["latency_ms"] == 31.0 and "31 ms on average" in r["detail"]
    assert xess.game_latency(str(tmp_path), "1", False)["latency_ms"] == 31.0




def test_uninstall_restores_igdext_in_prefixes_and_protons(tmp_path):
    """review S2-2: every prefix copy back from .gamecove-stock, ours removed where the prefix had none, and the
    .stock copies older builds left in Proton installs put back only while the Proton's file is still a shim."""
    from gamecove_upscale import xess
    steam = tmp_path / ".local/share/Steam"
    a = steam / "steamapps/compatdata/10/pfx/drive_c/windows/system32/DriverStore/FileRepository/igd_faux.inf_1"
    b = steam / "steamapps/compatdata/20/pfx/drive_c/windows/system32/driverstore/filerepository/igd_faux.inf_1"
    _w(a / "igdext64.dll", "shim IGDEXT_")
    _w(a / "igdext64.dll.gamecove-stock", "stock A")
    _w(b / "igdext64.dll", "shim IGDEXT_")
    _w(b / "igdext64.dll.gamecove-added", "")
    p1 = steam / "steamapps/common/Proton - Experimental" / xess.PROTON_IGDEXT
    p2 = steam / "compatibilitytools.d/GE-Proton11-12" / xess.PROTON_IGDEXT
    p3 = steam / "steamapps/common/Proton 11.0" / xess.PROTON_IGDEXT
    for p, now in ((p1, "shim IGDEXT_"), (p2, "shim IGDEXT_"), (p3, "newer intel")):
        _w(p, now)
        _w(str(p) + ".stock", "intel stock")
    r = xess.restore_igdext(str(tmp_path))
    assert r == {"prefixes": 2, "protons": 2}
    assert (a / "igdext64.dll").read_text() == "stock A\n" and not (a / "igdext64.dll.gamecove-stock").exists()
    assert not (b / "igdext64.dll").exists() and not (b / "igdext64.dll.gamecove-added").exists()
    assert p1.read_text() == "intel stock\n" and p2.read_text() == "intel stock\n"
    assert p3.read_text() == "newer intel\n", "a Proton updated since keeps its own file"


def test_optiscaler_undo_keeps_files_changed_since(tmp_path, monkeypatch):
    """review S2-3: undo removes only what still matches what GameCove put there, and never puts a stale backup
    over a file a game update wrote; the user's own OptiScaler.ini edits are kept as a copy outside the game (a
    changed OptiScaler.ini left in the game locked it out of ours after Native)."""
    from gamecove_upscale import optiscaler
    monkeypatch.setattr(optiscaler.userexec, "chown_tree", lambda p, h: None)
    home = str(tmp_path)
    _opti_pkg(home)
    g = tmp_path / "game"
    _w(g / "Game.exe", "x" * 100)
    _w(g / "libxess.dll", "game-own-xess-1.0")
    assert optiscaler.patch(home, str(g), "0.9.4", {})["ok"]
    m = json.loads((g / ".gamecove-optiscaler" / "manifest.json").read_text())
    assert set(m["sha256"]) >= {"dxgi.dll", "libxess.dll", "OptiScaler.ini"}, "every file we put there has its sha256"
    _w(g / "libxess.dll", "game-own-xess-2.0")                  # a game update replaces it
    with open(g / "OptiScaler.ini", "a") as f:                     # the user tunes OptiScaler by hand
        f.write("\n; mine\n")
    r = optiscaler.unpatch(str(g), home)
    assert r["ok"] and r["removed"]
    assert (g / "libxess.dll").read_text().strip() == "game-own-xess-2.0", "the update's file is never deleted or overwritten"
    assert not (g / "OptiScaler.ini").exists() and "; mine" in open(r["saved"][0]).read(), "the user's edits are kept, outside the game"
    assert r["saved"][0].startswith(os.path.join(home, optiscaler.KEPT_CONFIGS))
    assert sorted(r["kept"]) == ["libxess.dll"], "the game's newer file is reported"
    assert not (g / "dxgi.dll").exists() and not (g / "D3D12_Optiscaler").exists(), "unchanged files of ours go"


def test_optiscaler_repatch_after_a_game_update_backs_up_the_new_file(tmp_path, monkeypatch):
    from gamecove_upscale import optiscaler
    monkeypatch.setattr(optiscaler.userexec, "chown_tree", lambda p, h: None)
    home = str(tmp_path)
    _opti_pkg(home)
    g = tmp_path / "game"
    _w(g / "Game.exe", "x" * 100)
    _w(g / "libxess.dll", "game-own-xess-1.0")
    assert optiscaler.patch(home, str(g), "0.9.4", {})["ok"]
    _w(g / "libxess.dll", "game-own-xess-2.0")                  # update, then the user applies OptiScaler again
    assert optiscaler.patch(home, str(g), "0.9.4", {"Upscalers_Dx12Upscaler": "xess"})["ok"]
    assert (g / ".gamecove-optiscaler/backup/libxess.dll").read_text().strip() == "game-own-xess-2.0", "the new file is the backup now"
    r = optiscaler.unpatch(str(g), home)
    assert r["ok"] and (g / "libxess.dll").read_text().strip() == "game-own-xess-2.0" and r["kept"] == []


def test_optiscaler_undo_of_an_older_manifest_checks_the_package(tmp_path, monkeypatch):
    """Manifests from before the hashes: a file counts as ours only when it matches the package file it came from."""
    from gamecove_upscale import optiscaler
    monkeypatch.setattr(optiscaler.userexec, "chown_tree", lambda p, h: None)
    home = str(tmp_path)
    _opti_pkg(home)
    g = tmp_path / "game"
    _w(g / "Game.exe", "x" * 100)
    _w(g / "libxess.dll", "game-own-xess-1.0")
    assert optiscaler.patch(home, str(g), "0.9.4", {})["ok"]
    mp = g / ".gamecove-optiscaler" / "manifest.json"
    m = json.loads(mp.read_text())
    m.pop("sha256")
    mp.write_text(json.dumps(m))
    _w(g / "libxess.dll", "game-own-xess-2.0")
    r = optiscaler.unpatch(str(g), home)
    assert not (g / "dxgi.dll").exists(), "matches the package's OptiScaler.dll: removed"
    assert (g / "libxess.dll").read_text().strip() == "game-own-xess-2.0" and "libxess.dll" in r["kept"]
    assert not (g / "OptiScaler.ini").exists() and "OptiScaler.ini" not in r["kept"], "our own config: always ours to take out"
