"""GameCove against ClawDeck, step by step, on the Intel XMX path (XeSS on XMX, XeLL, XeSS frame generation,
FSR 4.1.2 on XMX): the same fixture goes through both projects' generators and what comes out must be the same.

  CLAWDECK_SRC=/path/to/clawdeck python3 -m pytest -q packaging/helpers/tests/test_clawdeck_parity.py

CLAWDECK_SRC is a ClawDeck checkout (its py_modules/ and tools/clawdeck-launch.sh; the reference is cf349a6).
Without it every test here is skipped. Compared: the launch environment (compose / the .env file), OptiScaler.ini
and every file put into the game (patch), undo, the XMX scope files, and both launch wrappers run on the same
fake Steam library (the environment the game gets, what happens to the Proton and the prefix, the launch log).
Names are mapped (clawdeck -> gamecove) and nothing else: any other difference fails. The differences GameCove
keeps on purpose are listed in KNOWN below and in docs/CONTROLS.md, each with its reason."""
import importlib
import json
import os
import shutil
import subprocess
import sys

import pytest

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(os.path.dirname(HERE)))
SRC = os.environ.get("CLAWDECK_SRC", "")
pytestmark = pytest.mark.skipif(not os.path.isfile(os.path.join(SRC, "py_modules", "clawdeck", "launchenv.py")),
                                reason="CLAWDECK_SRC is not a ClawDeck checkout")

sys.path.insert(0, os.path.join(HERE, ".."))
GC_RUN = os.path.join(REPO, "packaging", "libexec", "gamecove-run")
CD_RUN = os.path.join(SRC, "tools", "clawdeck-launch.sh")

# What GameCove does differently on purpose. Each is a safety addition that leaves the game's run as ClawDeck's.
KNOWN = {
    "manifest sha256": "GameCove's manifest also records each file's sha256, so undo never deletes a file that changed",
    "IGDEXT_XELL_LOG without a driver": "ClawDeck sets it in every wrapped launch; GameCove only once the XeSS XMX "
                                        "driver is installed (nothing reads it before, and AMD handhelds never get it)",
    "env key check": "GameCove's wrapper skips lines of the .env file whose name isn't a plain variable name",
}


def cd(name):
    if os.path.join(SRC, "py_modules") not in sys.path:
        sys.path.insert(0, os.path.join(SRC, "py_modules"))
    return importlib.import_module("clawdeck." + name)


def gc(name):
    return importlib.import_module("gamecove_upscale." + name)


def norm(text: str) -> str:
    """ClawDeck's names as GameCove's; nothing else."""
    return (text.replace("homebrew/data/ClawDeck", ".local/share/gamecove").replace("clawdeck-launch.sh", "gamecove-run")
            .replace("tools/gamecove-run", "gamecove-run")
            .replace("CLAWDECK", "GAMECOVE").replace("ClawDeck", "GameCove").replace("clawdeck", "gamecove"))


def norm_env(env: dict) -> dict:
    return {norm(k): norm(str(v)) for k, v in env.items()}


def _w(path, text="x"):
    os.makedirs(os.path.dirname(str(path)), exist_ok=True)
    with open(path, "w") as f:
        f.write(text)


# ---- 1. the launch environment ---------------------------------------------------------------------------------
def _launches():
    """Every upscaler x frame generation x source the UI can save, the switches, and each game's own fixes."""
    out = [{}, {"xmx": True}, {"xmx": False}, {"low_latency": False}, {"fsr": "xess"}, {"xess_latest": True},
           {"fg": 2}, {"fg": 3}, {"fg": 4}, {"fg": 3, "low_latency": False}]
    for opti in ("xess", "fsr4", "fsr4_xmx", "fsr4_xmx_lite", "off"):
        for ofg in (None, "off", "upscaler", "dlssg", "fsrfg"):
            for fg in (0, 2, 3, 4):
                for extra in ({}, {"opti_dll": "dxgi"}, {"opti_dll": "winmm", "reframework": True},
                              {"opti_xefg": True}, {"opti_overlay": 1}, {"xmx": False}):
                    l = {"opti": opti, **extra}
                    if ofg is not None:
                        l["opti_fg"] = ofg
                    if fg:
                        l["fg"] = fg
                    out.append(l)
    with open(os.path.join(HERE, "..", "gamecove_upscale", "data", "games.json"), encoding="utf-8") as f:
        doc = json.load(f)
    for g in doc.get("games", []):
        ini = {**g.get("ini", {}), **(g.get("when") or {}).get("xefg", {})}
        out.append({"opti": "xess", "opti_fg": "upscaler", "fg": 2, "opti_ini": ini})
        out.append({"opti": "fsr4_xmx", "opti_fg": "dlssg", "fg": 3, "opti_ini": ini, "reframework": True, "opti_dll": "dinput8"})
    return out


def _both(fa, fb):
    """(result or the error text) of each side."""
    res = []
    for f in (fa, fb):
        try:
            res.append(("ok", f()))
        except ValueError as e:
            res.append(("error", norm(str(e))))
    return res


def test_games_json_is_clawdecks():
    a = json.load(open(os.path.join(SRC, "assets", "games.json"), encoding="utf-8"))
    b = json.load(open(os.path.join(HERE, "..", "gamecove_upscale", "data", "games.json"), encoding="utf-8"))
    assert a == b


def test_pins_are_clawdecks():
    """The same XeSS XMX driver, OptiScaler builds, REFramework, fakenvapi and FSR 4.1.2 files, by version and
    sha256 (GameCove adds mirrors and AMD's own FSR 4 on top)."""
    a = json.load(open(os.path.join(SRC, "assets", "versions.json"), encoding="utf-8"))
    b = json.load(open(os.path.join(HERE, "..", "gamecove_upscale", "data", "versions.json"), encoding="utf-8"))
    for key in ("xess_xmx_linux", "optiscaler", "optiscaler_v10", "reframework", "fsr4_xmx"):
        if key not in a:
            continue
        for field in ("version", "tag", "sha256", "url", "asset", "layout", "files", "dll_sha256", "base", "repo"):
            if field in a[key]:
                assert b[key].get(field) == a[key][field], (key, field)
        ax = {x["name"]: x for x in a[key].get("extras", [])}
        bx = {x["name"]: x for x in b[key].get("extras", [])}
        assert set(ax) == set(bx), key
        for n, x in ax.items():
            for field in ("url", "sha256", "dest", "files", "file_sha256", "ini"):
                if field in x:
                    assert bx[n].get(field) == x[field], (key, n, field)


def test_launch_environment_is_the_same():
    le_c, le_g = cd("launchenv"), gc("launchenv")
    n = 0
    for launch in _launches():
        for per_game in (True, False):
            a, b = _both(lambda: norm_env(le_c.compose(dict(launch), per_game)), lambda: le_g.compose(dict(launch), per_game))
            assert a == b, (launch, per_game)
            n += 1
        a, b = _both(lambda: norm_env(le_c.opti_ini(dict(launch))), lambda: le_g.opti_ini(dict(launch)))
        assert a == b, launch
    assert n > 1000
    assert norm(str(le_c.KEYS)) == str(le_g.KEYS) and le_c.FSR4_XMX == le_g.FSR4_XMX
    assert le_c.OPTI_FG == le_g.OPTI_FG
    for k, v in le_c.OPTI_PRESETS.items():
        assert le_g.OPTI_PRESETS[k] == norm_env(v)


def test_launch_file_is_the_same(tmp_path):
    le_c, le_g = cd("launchenv"), gc("launchenv")
    for i, launch in enumerate(_launches()[::7]):
        try:
            a = le_c.write(str(tmp_path / "c"), str(1000 + i), dict(launch))
        except ValueError:
            with pytest.raises(ValueError):
                le_g.write(str(tmp_path / "g"), str(1000 + i), dict(launch))
            continue
        b = le_g.write(str(tmp_path / "g"), str(1000 + i), dict(launch))
        ta = norm(open(a["path"]).read()) if a.get("path") and os.path.exists(a["path"]) else None
        tb = open(b["path"]).read() if b.get("path") and os.path.exists(b["path"]) else None
        # the same lines; their order follows the names (CLAWDECK_* sorts before Dx12Upscaler, GAMECOVE_* after),
        # and the wrapper exports them one by one, so the order changes nothing
        assert (ta is None) == (tb is None), launch
        assert ta is None or sorted(ta.splitlines()) == sorted(tb.splitlines()), launch
        assert os.path.basename(a.get("path") or "") == os.path.basename(b.get("path") or "")


# ---- 2. OptiScaler into the game ---------------------------------------------------------------------------------
PKG_INI = ("[Upscalers]\nDx12Upscaler=auto\nDx11Upscaler=auto\nVulkanUpscaler=auto\n\n[FrameGen]\nEnabled=auto\nFGInput=auto\n"
           "FGOutput=auto\n\n[XeFG]\nInterpolationCount=auto\n\n[Menu]\nUseHQFont=auto\nOverlayMenu=auto\n\n[Plugins]\n"
           "LoadAsiPlugins=auto\n\n[Spoofing]\nDxgi=auto\n\n[Hotfix]\nRestoreComputeSignature=auto\n\n[FSR]\nFsr4Update=auto\n"
           "\n[Nvngx]\nDxgi=auto\n\n[DLSSG]\nOverrideInterpolationCount=auto\n")


def _package(home, mod, ver, layout):
    d = os.path.join(home, mod.ROOT, ver)
    sub = "OptiScaler/" if layout == "subfolder" else ""
    files = {"OptiScaler.dll": "opti", "OptiScaler.ini": PKG_INI, sub + "libxess.dll": "xess-opti",
             sub + "libxess_fg.dll": "xefg", sub + "libxell.dll": "xell", sub + "amd_fidelityfx_upscaler_dx12.dll": "amd-fsr4",
             sub + "amd_fidelityfx_dx12.dll": "ffx", sub + "D3D12_Optiscaler/D3D12Core.dll": "core",
             sub + "plugins/OptiPatcher.asi": "op", sub + "fakenvapi.ini": "[fakenvapi]\nforce_reflex=0\n",
             sub + "nvapi64.dll": "fakenvapi", "setup_linux.sh": "x", "setup_windows.bat": "x", "Licenses/x.txt": "l"}
    for f, t in files.items():
        _w(os.path.join(d, f), t)


def _home(tmp_path, side, mod, cab):
    home = str(tmp_path / side)
    for ver, layout in (("0.9.4", "flat"), ("v10-test", "subfolder")):
        _package(home, mod, ver, layout)
    x = os.path.join(home, mod.FSR4_XMX_DIR)
    _w(os.path.join(x, "amd_fidelityfx_upscaler_dx12.dll"), "nitec-412")
    _w(os.path.join(x, "fsr-original.dll"), "fsr-orig")
    _w(os.path.join(home, ".local/share/Steam/steamapps/common/Proton 11.0/files/lib/wine/x86_64-windows/cabinet.dll"), "wine-cab")
    g = os.path.join(home, "game", "bin")
    _w(os.path.join(g, "Game.exe"), "x" * 64)
    _w(os.path.join(g, "libxess.dll"), "the game's own xess")
    _w(os.path.join(g, "save.dat"), "save")
    return home, g


def _tree(folder, state_dir):
    out = {}
    for r, _d, files in os.walk(folder):
        for f in files:
            p = os.path.join(r, f)
            rel = os.path.relpath(p, folder).replace(os.sep, "/")
            data = open(p, "rb").read()
            if rel.startswith(state_dir + "/"):
                rel = ".state/" + rel[len(state_dir) + 1:]
                if rel.endswith("manifest.json"):
                    m = json.loads(data)
                    m.pop("sha256", None)                       # KNOWN["manifest sha256"]
                    data = json.dumps(m, sort_keys=True).encode()
            out[rel] = norm(data.decode("utf-8", "replace"))
    return out


@pytest.fixture
def cabinet(tmp_path, monkeypatch):
    built = os.path.join(REPO, "tools", "cabinet-lzms", "out", "cabinet.dll")
    cab = str(tmp_path / "cabinet.dll")
    if os.path.isfile(built):
        shutil.copyfile(built, cab)
    else:
        _w(cab, "lzms-cabinet")
    monkeypatch.setattr(cd("optiscaler"), "OWN_CABINET", cab)
    monkeypatch.setenv("GAMECOVE_CABINET", cab)
    for m in (cd("optiscaler"), gc("optiscaler")):
        monkeypatch.setattr(m.userexec, "chown_tree", lambda p, h: None)
    return cab


@pytest.mark.parametrize("ver,layout", [("0.9.4", "flat"), ("v10-test", "subfolder")])
def test_optiscaler_in_the_game_is_the_same(tmp_path, cabinet, ver, layout):
    """Every preset in turn in the same game folder (as the user switching between them), then undo: the files, the
    OptiScaler.ini, fakenvapi.ini (XeLL forced on), the cabinet pair and the manifest match at every step."""
    oc, og = cd("optiscaler"), gc("optiscaler")
    lc, lg = cd("launchenv"), gc("launchenv")
    hc, gcdir = _home(tmp_path, "c", oc, cabinet)
    hg, ggdir = _home(tmp_path, "g", og, cabinet)
    before = _tree(ggdir, og.STATE)
    assert _tree(gcdir, oc.STATE) == before
    steps = [{"opti": "xess"}, {"opti": "xess", "opti_fg": "upscaler", "fg": 2}, {"opti": "fsr4_xmx", "opti_fg": "upscaler", "fg": 3},
             {"opti": "fsr4_xmx_lite"}, {"opti": "xess", "opti_fg": "dlssg", "fg": 4, "reframework": True},
             {"opti": "fsr4_xmx", "opti_fg": "off"}, {"opti": "xess", "opti_overlay": 1}]
    for launch in steps:
        opti = launch["opti"]
        a = oc.patch(hc, gcdir, ver, lc.opti_ini(dict(launch)), opti, opti in lc.FSR4_XMX, layout, None)
        b = og.patch(hg, ggdir, ver, lg.opti_ini(dict(launch)), opti, opti in lg.FSR4_XMX, layout, None)
        assert a.get("ok") and b.get("ok"), (launch, a, b)
        for k in ("dll", "dll_override"):
            assert a.get(k) == b.get(k), (launch, k)
        ta, tb = _tree(gcdir, oc.STATE), _tree(ggdir, og.STATE)
        assert sorted(ta) == sorted(tb), launch
        assert ta == tb, (launch, [k for k in ta if ta[k] != tb[k]])
        if opti in lc.FSR4_XMX:
            sub = "OptiScaler/" if layout == "subfolder" else ""
            assert tb[sub + "amd_fidelityfx_upscaler_dx12.dll"] == "nitec-412" and tb["cabinet_wine.dll"] == "wine-cab"
            assert open(os.path.join(ggdir, "cabinet.dll"), "rb").read() == open(cabinet, "rb").read()
    a, b = oc.unpatch(gcdir), og.unpatch(ggdir, hg)
    assert a["ok"] and b["ok"] and a["removed"] and b["removed"] and b["kept"] == []
    assert _tree(gcdir, oc.STATE) == before and _tree(ggdir, og.STATE) == before


def test_fsr4_xmx_needs_the_same_files(tmp_path, cabinet, monkeypatch):
    oc, og = cd("optiscaler"), gc("optiscaler")
    assert oc.FSR4_XMX_FILES == og.FSR4_XMX_FILES and oc.FSR4_XMX_DIR == og.FSR4_XMX_DIR
    hc, hg = str(tmp_path / "c"), str(tmp_path / "g")
    os.makedirs(hc), os.makedirs(hg)
    assert oc.fsr4_xmx_missing(hc) == og.fsr4_xmx_missing(hg) == list(og.FSR4_XMX_FILES)


# ---- 3. the per-game XMX scope ---------------------------------------------------------------------------------
def _scope_home(home, x):
    _w(os.path.join(home, x.SESSION_CONF), "VK_DRIVER_FILES=/p/run/intel_icd.json:/usr/share/vulkan/icd.d/intel_icd.x86_64.json\n"
       "VKD3D_DISABLE_EXTENSIONS=VK_EXT_descriptor_buffer,VK_KHR_present_wait2\nANV_CM_KERNEL_DIR=/p/kernels\n"
       "INTC_ALT_DRIVER_EXTENSIONS_PATH='C:\\\\windows\\\\system32\\\\driverstore\\\\filerepository\\\\igd_faux.inf_1'\n")
    for name in ("steamapps/common/Proton 11.0", "steamapps/common/Proton - Experimental", "compatibilitytools.d/GE-Proton10-25"):
        p = os.path.join(home, ".local/share/Steam", name)
        _w(os.path.join(p, "proton"), "")
        _w(os.path.join(p, "user_settings.py"), "# xess-xmx proton hook - written by install.sh\n")
    _w(os.path.join(home, ".local/share/Steam/compatibilitytools.d/GE-Proton10-25/user_settings.user.py"), "user_settings = {'PROTON_LOG': '1'}\n")


def test_xmx_scope_files_are_the_same(tmp_path, monkeypatch):
    xc, xg = cd("xmxscope"), gc("xmxscope")
    for m in (xc, xg):
        monkeypatch.setattr(m.userexec, "chown_tree", lambda p, h: None, raising=False)
    hc, hg = str(tmp_path / "c"), str(tmp_path / "g")
    _scope_home(hc, xc), _scope_home(hg, xg)
    for step in ("isolate_session", "install_scope"):
        a, b = getattr(xc, step)(hc), getattr(xg, step)(hg)
        assert norm(json.dumps(a, sort_keys=True, default=str)).replace(hc, "H") == json.dumps(b, sort_keys=True, default=str).replace(hg, "H"), step
    assert norm(open(os.path.join(hc, xc.XMX_ENV)).read()) == open(os.path.join(hg, xg.XMX_ENV)).read()
    assert xc.xmx_env(hc) == xg.xmx_env(hg)
    for name in ("steamapps/common/Proton 11.0", "steamapps/common/Proton - Experimental", "compatibilitytools.d/GE-Proton10-25"):
        pc, pg = os.path.join(hc, ".local/share/Steam", name), os.path.join(hg, ".local/share/Steam", name)
        assert sorted(norm(f) for f in os.listdir(pc)) == sorted(os.listdir(pg))
        assert norm(open(os.path.join(pc, xc.USER_PY)).read()) == open(os.path.join(pg, xg.USER_PY)).read()
        assert os.path.exists(os.path.join(pc, xc.PREV_PY)) == os.path.exists(os.path.join(pg, xg.PREV_PY))
        if os.path.exists(os.path.join(pg, xg.PREV_PY)):
            assert open(os.path.join(pc, xc.PREV_PY)).read() == open(os.path.join(pg, xg.PREV_PY)).read()
    sa, sb = xc.state(hc), xg.state(hg)
    assert json.dumps(sa, sort_keys=True).replace(hc, "H") == json.dumps(sb, sort_keys=True).replace(hg, "H")
    for on in (True, False):
        assert xc.set_every_game(hc, on).get("ok") == xg.set_every_game(hg, on).get("ok")
        assert xc.every_game(hc) == xg.every_game(hg) == on
    # the prefix shim at set-up time (Valve's Proton 11.0 has no driver store)
    for home, x in ((hc, xc), (hg, xg)):
        _w(os.path.join(home, "pkg/igdext64.dll"), "shim IGDEXT_")
        _w(os.path.join(home, "pkg/ControlLib.dll"), "ctl")
        os.makedirs(os.path.join(home, ".local/share/Steam/steamapps/compatdata/42/pfx/drive_c/windows/system32"))
    a, b = xc.prefix_shim(hc, "42", os.path.join(hc, "pkg")), xg.prefix_shim(hg, "42", os.path.join(hg, "pkg"))
    assert json.dumps(a, sort_keys=True).replace(hc, "H") == json.dumps(b, sort_keys=True).replace(hg, "H")

    def pfx(h):
        root = os.path.join(h, ".local/share/Steam/steamapps/compatdata/42/pfx")
        return sorted(os.path.relpath(os.path.join(r, f), root) for r, _d, fs in os.walk(root) for f in fs)
    assert pfx(hc) == pfx(hg) and pfx(hg)
    for step in ("remove_scope", "restore_session"):
        a, b = getattr(xc, step)(hc), getattr(xg, step)(hg)
        assert norm(json.dumps(a, sort_keys=True, default=str)).replace(hc, "H") == json.dumps(b, sort_keys=True, default=str).replace(hg, "H"), step
    assert xc.session_active(hc) and xg.session_active(hg)


def test_games_layer_follows_clawdecks_main(tmp_path, monkeypatch):
    """What ClawDeck's main.py does around the generators, in games.py: the launch file is per game only while no
    session-wide driver file is active, a game set up through choose() gets the shim in its prefix, and Protons
    added since the driver install get the scope before the helper's commands."""
    games, xg = gc("games"), gc("xmxscope")
    monkeypatch.setattr(xg.userexec, "chown_tree", lambda p, h: None, raising=False)
    home = str(tmp_path)
    intel = {"vendor": "intel", "family": "intel-xe3", "xmx": True}
    assert games.per_game(home, intel) is True
    _scope_home(home, xg)
    assert games.per_game(home, intel) is False and games.per_game(home, {"vendor": "amd", "family": "amd-rdna3"}) is True
    le_c = cd("launchenv")
    r = games.set_launch(home, "42", {"xmx": True, "fg": 2}, intel)
    assert r["env"] == norm_env(le_c.compose({"xmx": True, "fg": 2}, False))
    xg.isolate_session(home)
    r = games.set_launch(home, "42", {"xmx": True, "fg": 2}, intel)
    assert r["env"] == norm_env(le_c.compose({"xmx": True, "fg": 2}, True))
    assert norm(open(r["path"]).read()) == open(r["path"]).read()
    # a Proton added after the driver install (with the installer's hook): scoped by the upkeep step
    assert games.xmx_upkeep(home, intel)["scope"]["ok"]
    assert all(os.path.isfile(os.path.join(p, xg.USER_PY)) for p in xg.protons(home)) and len(xg.protons(home)) == 3
    assert games.xmx_upkeep(home, {"vendor": "amd", "family": "amd-rdna3"}) is None


# ---- 4. the launch wrappers ----------------------------------------------------------------------------------------
KEEP = ("VK_DRIVER_FILES", "VKD3D_DISABLE_EXTENSIONS", "ANV_CM_KERNEL_DIR", "INTC_ALT_DRIVER_EXTENSIONS_PATH", "IGDEXT_XELL_LOG",
        "WINEDLLOVERRIDES", "DXVK_CONFIG", "XESS_FG", "FSR", "GAMECOVE_XMX", "GAMECOVE_FSR4_XMX", "Dx12Upscaler",
        "FrameGen_FGInput", "FrameGen_FGOutput", "MANGOHUD", "MANGOHUD_CONFIG", "GAMECOVE_STAGE")


class Side:
    """One project's wrapper on its own copy of the same fake Steam library."""

    def __init__(self, root, name):
        self.name, self.home = name, os.path.join(str(root), name)
        self.cd = name == "c"
        self.data = os.path.join(self.home, ".local/share", "clawdeck" if self.cd else "gamecove")
        self.runtime = os.path.join(self.home, "homebrew/data/ClawDeck") if self.cd else self.data
        self.pkg = os.path.join(self.data, "xess-xmx-linux-20261104", "xess-xmx-linux-20261104")
        self.steam = os.path.join(self.home, ".local/share/Steam")
        self.game = os.path.join(self.steam, "steamapps/common/Game")
        self.pfx = os.path.join(self.steam, "steamapps/compatdata/42")
        self.store = os.path.join(self.pfx, "pfx/drive_c/windows/system32/DriverStore/FileRepository/igd_faux.inf_1")
        self.fsr = os.path.join(self.home, "fsr4-xmx")
        self.cab = os.path.join(self.home, "cab", "cabinet.dll")
        _w(os.path.join(self.pkg, "igdext64.dll"), "shim IGDEXT_XELL\n")
        _w(os.path.join(self.pkg, "run/shim-stamp"), "")
        os.utime(os.path.join(self.pkg, "run/shim-stamp"), (1767323045, 1767323045))
        os.makedirs(os.path.join(self.pkg, "kernels"))
        _w(os.path.join(self.data, "xmx.env"), f"# vars\nVK_DRIVER_FILES={self.pkg}/run/intel_icd.json\nANV_CM_KERNEL_DIR={self.pkg}/kernels\n"
           "VKD3D_DISABLE_EXTENSIONS=VK_EXT_descriptor_buffer\nINTC_ALT_DRIVER_EXTENSIONS_PATH=C:\\windows\\system32\\driverstore\\filerepository\\igd_faux.inf_1\n")
        _w(os.path.join(self.game, "Game.exe"), "exe")
        _w(os.path.join(self.fsr, "amd_fidelityfx_upscaler_dx12.dll"), "nitec")
        _w(os.path.join(self.fsr, "fsr-original.dll"), "orig")
        _w(self.cab, "lzms")
        fg = os.path.join(self.home, "fgmod", "fgmod")
        _w(fg, "#!/bin/sh\nfor a in \"$@\"; do case \"$a\" in *.exe) printf 'fgmod fsr4' >\"$(dirname \"$a\")/amd_fidelityfx_upscaler_dx12.dll\" ;; esac; done\nexec \"$@\"\n")
        os.chmod(fg, 0o755)
        self.fgmod = fg

    def proton(self, kind):
        p = os.path.join(self.steam, "compatibilitytools.d" if kind.startswith("GE") else "steamapps/common", kind)
        _w(os.path.join(p, "files/lib/wine/x86_64-windows/cabinet.dll"), "wine cab")
        if kind != "Proton 11.0":
            b = os.path.join(p, "files/lib/wine/igdext/x86_64-windows/igdext64.dll")
            if not os.path.exists(b):
                _w(b, "intel stock " + kind + "\n")
        return p

    def env_file(self, launch, le):
        os.makedirs(os.path.join(self.runtime, "launch"), exist_ok=True)
        le.write(self.runtime, "42", launch)

    def run(self, proton, extra=None, fgmod=False, prefix=True):
        if prefix:
            os.makedirs(os.path.join(self.pfx, "pfx/drive_c/windows/system32"), exist_ok=True)
        pre = "CLAWDECK" if self.cd else "GAMECOVE"
        env = {"HOME": self.home, "PATH": "/usr/bin:/bin", "SteamAppId": "42", "STEAM_COMPAT_DATA_PATH": self.pfx,
               "STEAM_COMPAT_TOOL_PATHS": self.proton(proton) + ":/x", "STEAM_COMPAT_INSTALL_PATH": self.game,
               pre + "_RUNTIME": self.runtime, pre + "_CABINET": self.cab}
        env.update({k.replace("GAMECOVE", pre): v for k, v in (extra or {}).items()})
        out = os.path.join(self.home, "env.out")
        cmd = ["bash", CD_RUN if self.cd else GC_RUN] + ([self.fgmod] if fgmod else []) + \
              ["sh", "-c", 'env >"$0"', out, os.path.join(self.game, "Game.exe")]
        if os.path.exists(out):
            os.remove(out)
        r = subprocess.run(cmd, env=env, capture_output=True, text=True, timeout=60)
        got = {}
        for line in open(out).read().splitlines() if os.path.exists(out) else []:
            k, _, v = line.partition("=")
            got[k] = v
        return r.returncode, got

    def view(self, env):
        """What can be compared: the game's environment, the Proton's and the prefix's igdext files, the game
        folder, the launch log (without its date line)."""
        def n(t):
            return norm(t.replace(self.home, "HOME").replace(self.home.replace("/", "\\"), "HOME"))
        e = {n(k): n(v) for k, v in env.items()}
        e = {k: v for k, v in e.items() if k in KEEP}
        files = {}
        for root in (self.steam, self.game):
            for r, _d, fs in os.walk(root):
                for f in fs:
                    if "igdext64" in f or root == self.game:
                        p = os.path.join(r, f)
                        files[n(p)] = (n(open(p, errors="replace").read()), int(os.path.getmtime(p)) if "igdext/x86_64-windows/igdext64.dll" in p and not p.endswith(".stock") and "shim" in open(p).read() else 0)
        log = n(open(os.path.join(self.runtime, "launch", "42.log")).read()).splitlines()
        log = [x for x in log if not x.startswith("gamecove: launch ") and not x.startswith("gamecove: per-game settings")
               and not x.startswith("gamecove: settings ")]
        return {"env": e, "files": files, "log": log}


def _pair(tmp_path):
    return Side(tmp_path, "c"), Side(tmp_path, "g")


def _same(c, g, rc_env_c, rc_env_g, what, drop_env=()):
    assert rc_env_c[0] == rc_env_g[0] == 0, what
    a, b = c.view(rc_env_c[1]), g.view(rc_env_g[1])
    for k in drop_env:
        a["env"].pop(k, None), b["env"].pop(k, None)
    assert a["env"] == b["env"], what
    assert a["files"] == b["files"], what
    assert a["log"] == b["log"], what


@pytest.mark.skipif(not os.path.isfile(CD_RUN), reason="no ClawDeck launch wrapper")
@pytest.mark.parametrize("proton", ["GE-Proton10-25", "Proton - Experimental", "proton-cachyos", "Proton 11.0"])
def test_wrappers_do_the_same_for_every_proton(tmp_path, proton):
    """The XMX driver and its shim, launch by launch, on a Proton that bundles Intel's stock igdext64.dll (GE-Proton,
    Experimental, proton-cachyos: also when it was added after the driver install) and on one that doesn't (11.0)."""
    c, g = _pair(tmp_path)
    le_c, le_g = cd("launchenv"), gc("launchenv")
    launch = {"opti": "fsr4_xmx", "opti_fg": "upscaler", "fg": 3, "opti_dll": "dxgi", "xmx": True}
    c.env_file(launch, le_c), g.env_file(launch, le_g)
    # first launch, no prefix yet
    _same(c, g, c.run(proton, prefix=False), g.run(proton, prefix=False), "first launch")
    if proton != "Proton 11.0":
        bundled = os.path.join(g.proton(proton), "files/lib/wine/igdext/x86_64-windows/igdext64.dll")
        assert "IGDEXT_" in open(bundled).read() and open(bundled + ".stock").read().startswith("intel stock")
    # the Proton has made its prefix, with its own stock copy in the driver store
    for s in (c, g):
        _w(os.path.join(s.store, "igdext64.dll"), "intel stock prefix\n")
    rc, rg = c.run(proton), g.run(proton)
    _same(c, g, rc, rg, "second launch")
    assert rg[1]["INTC_ALT_DRIVER_EXTENSIONS_PATH"].startswith("Z:") and rg[1]["VK_DRIVER_FILES"].endswith("intel_icd.json")
    assert rg[1]["WINEDLLOVERRIDES"] == "dxgi=n,b;cabinet=n,b;" and rg[1]["IGDEXT_XELL_LOG"] == "1"
    # a Proton update put its stock file back
    if proton != "Proton 11.0":
        for s in (c, g):
            _w(os.path.join(s.proton(proton), "files/lib/wine/igdext/x86_64-windows/igdext64.dll"), "intel stock updated\n")
        _same(c, g, c.run(proton), g.run(proton), "after a Proton update")
    # the prefix holds the shim (the scope script or the set-up step put it there)
    for s in (c, g):
        shutil.copyfile(os.path.join(s.pkg, "igdext64.dll"), os.path.join(s.store, "igdext64.dll"))
    rc, rg = c.run(proton), g.run(proton)
    _same(c, g, rc, rg, "prefix has the shim")
    assert rg[1]["INTC_ALT_DRIVER_EXTENSIONS_PATH"].startswith("C:")
    # the user's own overrides are kept
    extra = {"WINEDLLOVERRIDES": "d3dcompiler_47=n", "DXVK_CONFIG": "dxgi.maxFrameRate=60"}
    _same(c, g, c.run(proton, extra), g.run(proton, extra), "the user's own overrides")
    # XMX off for this game
    c.env_file({"xmx": False}, le_c), g.env_file({"xmx": False}, le_g)
    rc, rg = c.run(proton), g.run(proton)
    _same(c, g, rc, rg, "XMX off")
    assert "VK_DRIVER_FILES" not in rg[1]


@pytest.mark.skipif(not os.path.isfile(CD_RUN), reason="no ClawDeck launch wrapper")
def test_wrappers_pick_the_driver_for_the_same_games(tmp_path):
    """No per-game setting: the driver only for a game that ships XeSS / XeLL / OptiScaler, or with the every-game
    switch; and without the driver installed nothing is set."""
    c, g = _pair(tmp_path)
    p = "GE-Proton10-25"
    rc, rg = c.run(p), g.run(p)
    _same(c, g, rc, rg, "nothing asks for XMX")
    assert "VK_DRIVER_FILES" not in rg[1]
    for s in (c, g):
        _w(os.path.join(s.game, "bin/x64/libxess.dll"), "xess")
    rc, rg = c.run(p), g.run(p)
    _same(c, g, rc, rg, "the game ships XeSS")
    assert "VK_DRIVER_FILES" in rg[1]
    for s in (c, g):
        os.remove(os.path.join(s.game, "bin/x64/libxess.dll"))
        _w(os.path.join(s.data, "xmx-every-game"), "")
    _same(c, g, c.run(p), g.run(p), "every game")
    _same(c, g, c.run(p, {"GAMECOVE_XMX": "0"}), g.run(p, {"GAMECOVE_XMX": "0"}), "off in the environment")
    for s in (c, g):
        os.remove(os.path.join(s.data, "xmx.env"))
    rc, rg = c.run(p), g.run(p)
    # KNOWN["IGDEXT_XELL_LOG without a driver"]; the log's wording for "not installed" is GameCove's own
    assert rc[1].get("IGDEXT_XELL_LOG") == "1" and "IGDEXT_XELL_LOG" not in rg[1]
    a, b = c.view(rc[1]), g.view(rg[1])
    a["env"].pop("IGDEXT_XELL_LOG")
    assert a["env"] == b["env"] and a["files"] == b["files"]
    assert [x for x in a["log"] if "XMX driver not used" not in x] == [x for x in b["log"] if "XMX driver not used" not in x]


@pytest.mark.skipif(not os.path.isfile(CD_RUN), reason="no ClawDeck launch wrapper")
def test_wrappers_second_stage_after_fgmod_is_the_same(tmp_path):
    """A game Decky Framegen set up: FSR 4.1.2 on XMX goes over fgmod's FSR 4 with the cabinet pair, and comes out
    again when it is switched off."""
    c, g = _pair(tmp_path)
    le_c, le_g = cd("launchenv"), gc("launchenv")
    p = "GE-Proton10-25"
    launch = {"opti": "fsr4_xmx", "xmx": True}
    c.env_file(launch, le_c), g.env_file(launch, le_g)
    rc, rg = c.run(p, fgmod=True), g.run(p, fgmod=True)
    assert "GAMECOVE_FSR4_XMX" in rg[1]
    _same(c, g, rc, rg, "FSR 4 XMX over fgmod's")
    assert open(os.path.join(g.game, "amd_fidelityfx_upscaler_dx12.dll")).read() == "nitec"
    assert open(os.path.join(g.game, "cabinet.dll")).read() == "lzms" and open(os.path.join(g.game, "cabinet_wine.dll")).read() == "wine cab"
    c.env_file({"opti": "xess", "xmx": True}, le_c), g.env_file({"opti": "xess", "xmx": True}, le_g)
    rc, rg = c.run(p, fgmod=True), g.run(p, fgmod=True)
    _same(c, g, rc, rg, "FSR 4 XMX off again")
    assert sorted(os.listdir(g.game)) == ["Game.exe", "amd_fidelityfx_upscaler_dx12.dll"]
    assert open(os.path.join(g.game, "amd_fidelityfx_upscaler_dx12.dll")).read() == "fgmod fsr4"
