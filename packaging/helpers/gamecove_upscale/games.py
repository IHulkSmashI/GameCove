"""Per-game upscaling for GameCove: ClawDeck's main.py per-game flow (same author), as plain functions.

Ported from ClawDeck main.py (_rec, _supported_list_verdict, _optiscaler_entry, _prefer_fsr4, game_recommend,
_opti_into, game_apply_recommended, game_choose, game_undo_recommended): what the game ships decides the route
(gamedb.recommend), OptiScaler goes into the folder of the game's exe with the game's fixes from games.json, Capcom
RE Engine games get REFramework and OptiScaler v10, and OptiScaler from Decky Framegen or anyone else is never
touched. The choices are saved per game in ~/.local/share/gamecove/upscale.json and the launch environment is
written where the launch wrapper reads it (launchenv.write: ~/.local/share/gamecove/launch/<appid>.env).

Generalized for every handheld (GameCove), by the GPU the app passes in (gpu: {"vendor": intel|amd|other,
"family", "arch", "xmx": bool, "xmx_ready": bool, "chip"}):
  Intel with XMX (Arc Xe2 / Xe3: Claw 8 / A2VM, Lunar Lake, Panther Lake): exactly ClawDeck's choices (XeSS on XMX,
      FSR 4.1.2 on XMX, XeSS-FG 2x-4x).
  Intel without XMX (Meteor Lake Xe-LPG): XeSS through OptiScaler (DP4a path), XeSS-FG off (needs XMX).
  AMD: the game's own FSR 3.1+ stays (Proton's FSR 4 upgrade covers RDNA3 where the Proton has it, Launcher does
      that); DLSS / FSR 2 / XeSS-only games get OptiScaler's FSR 3.1; FSR 4 (AMD's FSR SDK 2.4 upscaler, 4.1.2) is
      offered on RDNA3 / RDNA3.5 for DirectX 12 games as an opt-in, not on RDNA2 (AMD's lightweight model takes
      5.6 ms at 1080p on Van Gogh); frame generation is OptiScaler's FSR-FG at 2x. The Capcom setup runs with FSR
      3.1 and FSR-FG (untested on AMD: said so).
  Anything else: the game's own settings only.
"""
from __future__ import annotations

import json
import logging
import os
import shutil

from . import active, chips, framegen, gamedb, guard, launchenv, livedb, mirror, optiscaler, reframework, xess, xmxscope

log = logging.getLogger("gamecove.games")

HERE = os.path.dirname(os.path.realpath(__file__))
BUNDLED_GAMES = os.path.join(HERE, "data", "games.json")
VERSIONS = os.path.join(HERE, "data", "versions.json")
DATA = ".local/share/gamecove"
STATE = os.path.join(DATA, "upscale.json")
LISTS = os.path.join(DATA, "lists")
REC_KEYS = ("opti", "opti_xefg", "opti_fg", "opti_ini", "reframework", "fsr", "opti_dll", "opti_overlay", "fg_out",
            "fsr4_int8", "proton_fsr4")
INTEL_UPSCALERS = ("own", "xess", "fsr4_xmx", "fsr4_xmx_lite")
AMD_UPSCALERS = ("own", "fsr31", "fsr4_amd")
FSR4_AMD_ARCHS = ("RDNA3", "RDNA3.5")


def pins() -> dict:
    """data/versions.json: the tested versions, the fallback when no verified index is at hand."""
    with open(VERSIONS, "r", encoding="utf-8") as f:
        return json.load(f)


def versions(home: str | None = None) -> dict:
    """What to install: the pins with the newest entries of the verified upscalers index (mirror.py) in their place.
    Without home, or without a verified index, the pins."""
    return mirror.versions(home, pins())


def games_path(home: str) -> str:
    return livedb.games_path(os.path.join(home, LISTS), BUNDLED_GAMES)


# ---- saved state ------------------------------------------------------------------------------------------------
def load_state(home: str) -> dict:
    try:
        with open(os.path.join(home, STATE), "r", encoding="utf-8") as f:
            s = json.load(f)
        if isinstance(s, dict):
            s.setdefault("launch", {})
            s.setdefault("opti_games", {})
            return s
    except (OSError, ValueError):
        pass
    return {"launch": {}, "opti_games": {}}


def save_state(home: str, s: dict) -> None:
    p = os.path.join(home, STATE)
    os.makedirs(os.path.dirname(p), exist_ok=True)
    with open(p + ".tmp", "w", encoding="utf-8") as f:
        json.dump(s, f, indent=1, sort_keys=True)
    os.replace(p + ".tmp", p)


def get_launch(home: str, key: str) -> dict:
    return dict(load_state(home)["launch"].get(str(key)) or {})


# ---- which folder of a game has our files -------------------------------------------------------------------------
# Games are keyed by a stable id (the Steam app id, else GameCove's own key), never by their path. Next to the folder
# OptiScaler went into ("opti_games") the state keeps where that is inside the game ("opti_rel"), so a game moved to
# another library (Steam's "Move install folder", another drive) is found again with our files and manifest in it
# (review M: a moved game was orphaned).
def _remember(home: str, key: str, folder: str, game_dir: str | None) -> None:
    s = load_state(home)
    s["opti_games"][str(key)] = folder
    rel = os.path.relpath(folder, game_dir) if game_dir and os.path.realpath(folder).startswith(os.path.realpath(game_dir) + os.sep) \
        else ("." if game_dir and os.path.realpath(folder) == os.path.realpath(game_dir) else None)
    if rel is not None and not rel.startswith(".."):
        s.setdefault("opti_rel", {})[str(key)] = rel
    save_state(home, s)


def _forget(home: str, key: str) -> None:
    s = load_state(home)
    s["opti_games"].pop(str(key), None)
    (s.get("opti_rel") or {}).pop(str(key), None)
    save_state(home, s)


def _find_ours(game_dir: str) -> str | None:
    """The folder below game_dir with GameCove's manifest in it (as deep as OptiScaler goes), or None."""
    base = game_dir.rstrip(os.sep).count(os.sep)
    for r, d, _f in os.walk(game_dir):
        d.sort()
        if optiscaler.STATE in d and optiscaler._manifest(r):
            return r
        if r.count(os.sep) - base >= optiscaler.EXE_DEPTH:
            d[:] = []
    return None


def tracked_folder(home: str, key: str, game_dir: str | None = None) -> str | None:
    """The folder with our files for this game, following a move: the one saved when it still has our manifest,
    else the same place inside the game's folder now, else wherever below it our manifest is. A folder found
    elsewhere is saved for next time. The saved one (even if gone) when nothing is found."""
    s = load_state(home)
    stored = s["opti_games"].get(str(key))
    if stored and optiscaler._manifest(stored):
        return stored
    d = _game_dir(home, key, game_dir)
    if d:
        rel = (s.get("opti_rel") or {}).get(str(key))
        cand = os.path.normpath(os.path.join(d, rel)) if rel else None
        found = cand if cand and optiscaler._manifest(cand) else (_find_ours(d) if stored or rel else None)
        if found:
            if found != stored:
                log.info("game %s moved: our files are now in %s", key, found)
                _remember(home, key, found, d)
            return found
    return stored


# ---- the GPU ----------------------------------------------------------------------------------------------------
def vendor(gpu: dict) -> str:
    v = str(gpu.get("vendor") or "")
    if v in ("intel", "amd"):
        return v
    fam = str(gpu.get("family") or "")
    return "intel" if fam.startswith("intel") else "amd" if fam.startswith("amd") else "other"


def upscalers_for(gpu: dict) -> list[str]:
    """The upscaler choices this GPU gets (the first is always the game's own): chips.py's table."""
    return chips.upscalers(gpu)


# which upscaler choices need which withdrawable component (mirror.withdrawn: the signed index's kill switch)
NEEDS = {"fsr4_xmx": "fsr4_xmx", "fsr4_xmx_lite": "fsr4_xmx", "fsr4_amd": "fsr4_amd"}


def offered(home: str | None, gpu: dict) -> list[str]:
    """upscalers_for() without the choices whose files were withdrawn."""
    gone = mirror.withdrawn(home)
    return [u for u in upscalers_for(gpu) if NEEDS.get(u) not in gone]


def fg_for(gpu: dict) -> list[int]:
    """Frame generation multipliers: XeSS-FG 2x-4x on XMX, 2x on everything else that has a generator, none elsewhere."""
    return chips.frame_gens(gpu)


# ---- the recommendation -----------------------------------------------------------------------------------------
def _game_dir(home: str, key: str, game_dir: str | None) -> str | None:
    if game_dir:
        return game_dir if os.path.isdir(game_dir) else None
    return xess.steam_install_dir(home, key) if str(key).isdigit() else None


def _supported_list_verdict(home: str, rec: dict, key: str, gpu: dict) -> None:
    """ClawDeck's _supported_list_verdict: the public list's Intel Arc column (only meaningful on Intel)."""
    if vendor(gpu) != "intel" or not str(key).isdigit():
        return
    oc = livedb.supported_list_says(livedb.supported_list(os.path.join(home, LISTS)), key)
    rec["supported_list"] = oc
    if not oc["known"] or rec["route"] == "own_xess":
        return
    if oc["listed"] and oc["intel_ok"] is False:
        rec["recommended"] = False
        rec["reasons"].insert(0, "The public supported-games list marks this game as not working on Intel Arc: GameCove "
                                 "doesn't recommend OptiScaler here. You can still pick an upscaler by hand.")
    elif oc["listed"]:
        rec["reasons"].append(f"On the public supported-games list for Intel Arc ({oc['name']})")
    else:
        rec["reasons"].append("Not on the public supported-games list yet: set up from what the game ships")


def _optiscaler_entry(home: str, rec: dict, name: str | None, online: bool) -> None:
    """ClawDeck's _optiscaler_entry: OptiScaler's own Compatibility List (broken -> not recommended; "Requires
    REFramework" -> the Capcom setup; the entry's proxy names; its known issues)."""
    row = livedb.find_compat(livedb.compat(os.path.join(home, LISTS)), name)
    page = None
    if row and online:
        page = livedb.game_page(os.path.join(home, LISTS), row.get("slug"))
    rec["optiscaler_wiki"] = {"row": row, "page": page}
    if not row or rec["route"] in ("own_xess", "own_fsr"):
        return
    if row["status"] == "broken" and rec.get("optiscaler"):
        rec["recommended"] = False
        rec["reasons"].insert(0, f"OptiScaler's compatibility list marks {row['name']} as not working"
                                 + (f" ({row['notes']})" if row["notes"] else "") + ".")
    if row["reframework"] and not rec.get("re_engine") and rec.get("optiscaler"):
        ini = dict(rec["launch"].get("opti_ini") or {})
        ini.pop("Spoofing_Dxgi", None)
        rec["launch"] = {"opti": rec["launch"].get("opti", "xess"), "opti_fg": "dlssg", "opti_ini": ini, "reframework": True}
        rec.update(route="re_engine", re_engine=True, capcom=True, frame_gen="dlssg", fg_source="dlssg")
        rec["reasons"][0] = "OptiScaler's compatibility list: this game needs REFramework. OptiScaler with REFramework."
    if page and page["proxies"]:
        rec["proxies"] = page["proxies"]
        rec["reasons"].append(f"Loads as {' or '.join(page['proxies'])} (OptiScaler's entry for this game)")
    for issue in (page or {}).get("issues", [])[:2]:
        rec["reasons"].append(f"Known: {issue}")


def _prefer_fsr4(home: str, rec: dict, d: str | None, gpu: dict, xmx_off: bool) -> None:
    """ClawDeck's _prefer_fsr4 (Intel XMX only): FSR 4.1.2 on XMX when the game is DirectX 12 and nitec's files are
    there. Not for Capcom games or games with their own XeSS."""
    launch = rec.get("launch") or {}
    if vendor(gpu) != "intel" or not gpu.get("xmx") or not rec.get("optiscaler") or rec.get("re_engine") \
            or launch.get("opti") != "xess" or xmx_off:
        return
    if not d or not gamedb.is_dx12(d, rec.get("main_exes")):
        return
    if not optiscaler.fsr4_xmx_missing(home):
        launch["opti"] = "fsr4_xmx"
        rec["upscaler"] = "fsr4_xmx"
        rec["reasons"][0] = rec["reasons"][0].replace("into XeSS on the XMX cores", "into FSR 4.1.2 on the XMX cores (the newest; XeSS 2 is one tap away)")
    else:
        rec["reasons"].append("FSR 4.1.2 (newer than XeSS) would be picked here once its files are in ~/fsr4-xmx (they come with GameCove; pick it once and they are fetched)")


def _for_gpu(rec: dict, d: str | None, gpu: dict, home: str | None = None) -> None:
    """GameCove: ClawDeck's recommendation (made for Intel XMX) turned into this GPU's."""
    v = vendor(gpu)
    if v == "intel" and gpu.get("xmx"):
        return
    launch = rec.get("launch") or {}
    if v == "intel":                                       # no XMX: XeSS on DP4a, no XeSS-FG
        if launch.get("opti_fg") not in (None, "off"):
            launch["opti_fg"] = "off"
        rec["frame_gen"] = None if not rec.get("optiscaler") else "off"
        if rec["route"] == "own_xess":
            rec["reasons"][0] = "This game ships XeSS: use it in its graphics menu (it runs on this GPU without XMX)."
        else:
            rec["reasons"][0] = rec["reasons"][0].replace(" on the XMX cores", "")
        return
    if v != "amd":
        why = ("NVIDIA: the game's own DLSS, frame generation and Reflex already are the best here. Nothing is added."
               if chips.tier(gpu) == "nvidia" else "Unknown GPU: only the game's own settings apply.")
        rec.update(route="own", optiscaler=False, launch={}, upscaler=None, frame_gen=None, reasons=[why])
        return
    t = chips.tier(gpu)
    ships = rec.get("ships") or {}
    dx12 = bool(d and gamedb.is_dx12(d, rec.get("main_exes")))
    if t == "amd_old":
        rec.update(route="own", optiscaler=False, launch={}, upscaler=None, frame_gen=None, ini={}, later=[],
                   reasons=["This GPU is too old for a newer upscaler: use the game's own FSR in its graphics menu."])
        return
    if "FSR" in ships.get("upscaler", []) and not rec.get("re_engine"):
        # the game has FSR of its own: nothing goes into its folder. Where Proton can upgrade FSR 3.1 to FSR 4 by
        # itself (GE-Proton, Proton-CachyOS) and FSR 4 is this chip's default, the launch gets PROTON_FSR4_UPGRADE.
        up = dx12 and t in chips.PROTON_FSR4 and chips.FSR4.get(t) == "default" and gamedb.has_fsr31(d)
        rec.update(route="own_fsr", optiscaler=False, launch={"proton_fsr4": True} if up else {}, upscaler="fsr" if up else None,
                   frame_gen=None, ini={}, later=[])
        rec["reasons"] = [("This game ships FSR 3.1: pick FSR in its graphics menu and Proton turns it into FSR 4 "
                           "(GE-Proton or Proton-CachyOS; nothing is added to the game's files)." if up else
                           "This game ships FSR: pick it in its graphics menu.")
                          + (" Its own FSR frame generation works too." if "FSR-FG" in ships.get("fg", []) else "")]
        return
    if rec["route"] == "own_xess":                         # XeSS only: OptiScaler turns it into FSR
        rec.update(route="optiscaler", optiscaler=True)
        launch = {"opti_fg": "off", "opti_ini": rec.get("ini") or {}}
        rec["reasons"] = ["This game ships XeSS (slow on AMD): OptiScaler turns it into FSR 3.1. "
                          "Pick XeSS in the game's graphics menu."]
    opti = chips.default_upscaler(gpu, dx12)
    launch["opti"] = opti
    if opti == "fsr4_amd" and t not in chips.FSR4_LISTED:
        launch["fsr4_int8"] = True
    if launch.get("opti_fg") not in (None, "off", "dlssg", "fsrfg", "upscaler"):
        launch["opti_fg"] = "off"
    rec["launch"] = launch
    rec["upscaler"] = opti
    name = "FSR 4.1.2" if opti == "fsr4_amd" else "FSR 3.1"
    first = rec["reasons"][0]
    first = first.replace("XeSS on the XMX cores", name).replace("into XeSS", "into " + name).replace("into FSR 3.1", "into " + name)
    first = first.replace("(XeSS on the XMX cores)", f"({name})").replace("XeSS frame generation", "FSR frame generation")
    rec["reasons"][0] = first
    if rec.get("re_engine"):
        rec["reasons"].append("The Capcom setup is tested on Intel only; on AMD it runs with FSR and FSR frame generation.")
    if opti == "fsr4_amd":
        rec["reasons"].append(f"FSR 4.1.2 ({chips.FSR4_MODEL.get(t, 'INT8')} model) is the sharpest this chip runs. "
                              "If it costs too many frames here, FSR 3.1 is one tap away.")
    elif chips.FSR4.get(t) == "optin" and dx12:
        rec["reasons"].append("FSR 4.1.2 is available for this DirectX 12 game: sharper, but it costs about a quarter "
                              "of the frame rate on this chip.")


def recommend(home: str, key: str, gpu: dict, game_dir: str | None = None, name: str | None = None,
              online: bool = False, xmx_off: bool = False) -> dict:
    """ClawDeck's _rec + game_recommend, for this GPU."""
    d = _game_dir(home, key, game_dir)
    rec = gamedb.recommend(gamedb.load(games_path(home)), d)
    folder = optiscaler.main_exe_dir(d, rec["main_exes"]) if d else None
    if name is None and str(key).isdigit():
        name = xess.steam_app_name(home, key)
    rec["entry"] = gamedb.knowledge(gamedb.load(games_path(home)), d, key, name)
    if rec["entry"]["proxies"] and not rec.get("proxies"):
        rec["proxies"] = list(rec["entry"]["proxies"])
    if rec["entry"]["wine_check"] and rec.get("optiscaler"):
        rec["reasons"].append("This game switches DLSS off under Proton by itself: pick XeSS or FSR in its graphics "
                              "menu, or use GE-Proton 11-9 or newer.")
    _supported_list_verdict(home, rec, key, gpu)
    _optiscaler_entry(home, rec, name, online)
    _prefer_fsr4(home, rec, d, gpu, xmx_off)
    _for_gpu(rec, d, gpu, home)
    gone = mirror.withdrawn(home)
    if gone and NEEDS.get((rec.get("launch") or {}).get("opti")) in gone:       # withdrawn: the next best this chip has
        step = {"fsr4_xmx": "xess", "fsr4_xmx_lite": "xess", "fsr4_amd": "fsr31"}[rec["launch"]["opti"]]
        rec["launch"]["opti"] = step
        rec["launch"].pop("fsr4_int8", None)
        rec["upscaler"] = step
        rec["reasons"].append("The sharper upscaler was taken out of GameCove for now, so this is the next best.")
    launch = get_launch(home, key)
    applied = bool(rec["launch"]) and all(launch.get(k) == v for k, v in rec["launch"].items())
    dx12 = gamedb.is_dx12(d, rec["main_exes"]) if d else False
    return {**rec, "dir": d, "folder": folder, "applied": applied, "opti_owner": optiscaler.owner(folder)["owner"],
            "dx12": dx12, "upscalers": offered(home, gpu), "frame_gens": fg_for(gpu), "vendor": vendor(gpu),
            "chip": chips.capabilities(gpu), "api": gamedb.api(d, rec["main_exes"]), "engine": gamedb.engine(d),
            "fsr4_xmx_missing": optiscaler.fsr4_xmx_missing(home) if vendor(gpu) == "intel" and gpu.get("xmx") else [],
            "fsr4_amd_missing": optiscaler.fsr4_amd_missing(home) if vendor(gpu) == "amd" else [],
            "reframework_state": reframework.status(folder) if folder and rec["re_engine"] else None,
            "decky_framegen": framegen.state(home)}


# ---- putting it in ----------------------------------------------------------------------------------------------
def _opti_entry(launch: dict, home: str | None = None) -> dict:
    v = versions(home)
    key = "optiscaler_v10" if launchenv.v10(launch) and v.get("optiscaler_v10") else "optiscaler"
    if home and v[key].get("version") in (load_state(home).get("bad_versions") or []):
        return pins()[key]                        # the newest failed its check on this device: the tested pin
    return v[key]


def _ref_shas(home: str | None = None) -> tuple[str, ...]:
    """REFramework builds GameCove installs: the tested one and the index's newest."""
    shas = [(e.get("reframework") or {}).get("dll_sha256") for e in (pins(), versions(home))]
    return tuple(dict.fromkeys(x for x in shas if x))


def _opti_into(home: str, key: str, folder: str, launch: dict, gpu: dict, proxies: list[str] | None = None,
               game_dir: str | None = None) -> dict:
    """ClawDeck's _opti_into: the pinned OptiScaler (downloaded once) into the game with `launch`'s settings."""
    entry = _opti_entry(launch, home)
    if not optiscaler.installed(home, entry["version"]) or not optiscaler.extras_ready(home, entry):
        r = optiscaler.install(home, entry)
        if not r.get("ok"):
            # the newest can't be downloaded now (offline): an OptiScaler of the same kind already here still works
            layout = entry.get("layout") or "flat"
            alt = next((p for p in optiscaler.packages(home) if p["layout"] == layout and p["version"] != entry["version"]), None)
            if not alt:
                return r
            entry = {"version": alt["version"], "layout": layout}
    v = vendor(gpu)
    opti = launch.get("opti") or ("xess" if v == "intel" else "fsr31")
    opti = "fsr4_xmx" if opti == "fsr4" else opti
    if opti in launchenv.FSR4_XMX and launch.get("xmx") is False:
        return {"ok": False, "error": "FSR 4.1.2 needs the XMX cores, and XMX is off for this game: pick XeSS 2, or switch XMX on first"}
    if opti == "fsr4_amd" and optiscaler.fsr4_amd_missing(home):
        r = optiscaler.fsr4_amd_download(home, versions(home)["fsr4_amd"])
        if not r.get("ok"):
            return r
    r = optiscaler.patch(home, folder, entry["version"], {**launchenv.opti_ini({**launch, "opti": opti}, v), **active.LOG_INI}, opti,
                         opti in launchenv.FSR4_XMX, entry.get("layout") or "flat", proxies,
                         fsr4_amd=opti == "fsr4_amd", force_reflex="2" if v == "intel" else None)
    if r.get("ok"):
        _remember(home, key, folder, game_dir or _game_dir(home, key, None))
    return r


def _refused(d: str | None, folder: str | None, anticheat: bool, rec: dict) -> dict | None:
    """guard.refusal as a helper answer: anti-cheat, another injector in the folder."""
    no = guard.refusal(d, folder, anticheat, rec.get("entry"))
    return {"ok": False, "refused": no["code"], "error": no["error"]} if no and no["code"] != "broken" else None


def per_game(home: str, gpu: dict) -> bool:
    """ClawDeck's `not xmxscope.session_active(HOME)`: the XeSS XMX driver is scoped per game unless the package's
    session-wide driver file is still in place (an install.sh run by hand outside GameCove's folder). Then the launch
    file must not switch the driver per game. Other GPUs have no such driver: always per game."""
    return vendor(gpu) != "intel" or not xmxscope.session_active(home)


def xmx_upkeep(home: str, gpu: dict) -> dict | None:
    """What ClawDeck does at every plugin start, here before the helper's commands on an Intel XMX handheld: a
    session-wide driver file from an install into GameCove's folder moves aside, and Protons added since the driver
    was installed get the per-game scope script. None when there is nothing to do (no driver)."""
    if vendor(gpu) != "intel" or not gpu.get("xmx"):
        return None
    out: dict = {}
    try:
        if xmxscope.session_active(home) and (xess.package_dir(home) or "").startswith(os.path.join(home, xess.INSTALL_ROOT)):
            out["isolated"] = xmxscope.isolate_session(home)
        if xmxscope.xmx_env(home):
            out["scope"] = xmxscope.install_scope(home)
    except OSError as e:
        out["error"] = str(e)
    try:
        # ClawDeck's _fsr4_fetch: nitec's FSR 4.1.2 files from the package into ~/fsr4-xmx when they aren't there
        # (nothing to set up, nothing downloaded); files already there, also the user's own, are never replaced
        r = fsr4_ready(home)
        if r.get("how") not in ("there", "missing"):
            out["fsr4_xmx"] = r
    except OSError as e:
        out["error"] = str(e)
    return out or None


def fsr4_ready(home: str, download: bool = False) -> dict:
    return optiscaler.fsr4_xmx_ready(home, [versions(home).get("fsr4_xmx"), pins().get("fsr4_xmx")], download)


def set_launch(home: str, key: str, values: dict, gpu: dict) -> dict:
    """ClawDeck's set_launch: merge (None removes a key), check by composing, save, write the launch file."""
    s = load_state(home)
    cur = dict(s["launch"].get(str(key)) or {})
    for k, v in values.items():
        if v is None:
            cur.pop(k, None)
        else:
            cur[k] = v
    env = launchenv.compose(cur, per_game(home, gpu), vendor(gpu))       # raises on a bad combination: nothing saved then
    if cur:
        s["launch"][str(key)] = cur
    else:
        s["launch"].pop(str(key), None)
    save_state(home, s)
    path = None
    if str(key).isdigit():
        path = launchenv.write(os.path.join(home, DATA), str(key), cur, per_game(home, gpu), vendor(gpu))["path"]
    return {"ok": True, "launch": cur, "env": env, "path": path}


def _folder(home: str, key: str, d: str | None, rec: dict) -> str | None:
    t = tracked_folder(home, key, d)
    return (t if t and os.path.isdir(t) else None) or rec.get("folder") or (optiscaler.main_exe_dir(d) if d else None)


def _foreign(who: str | None) -> dict | None:
    if who == "decky-framegen":
        return {"ok": False, "owner": who, "error": "Decky Framegen has put OptiScaler in this game: remove it there "
                "(Decky Framegen > Unpatch), then pick again"}
    if who == "clawdeck":
        return {"ok": False, "owner": who, "error": "ClawDeck has put OptiScaler in this game: remove it in ClawDeck first"}
    if who == "other":
        return {"ok": False, "owner": who, "error": "this game already has OptiScaler from somewhere else (files from a "
                "Windows install, or put there by hand): remove OptiScaler.ini and its DLL, then pick again"}
    return None


def choose(home: str, key: str, upscaler: str, fg: int, gpu: dict, game_dir: str | None = None,
           overlay: int | None = None, allow_unpinned: bool = False, online: bool = False,
           generator: str | None = None, anticheat: bool = False) -> dict:
    """ClawDeck's game_choose, for this GPU: the upscaler (the game's own, or one through GameCove's OptiScaler)
    and frame generation (0 off, else the multiplier). Everything they need is put in or taken out here."""
    if upscaler in upscalers_for(gpu) and upscaler not in offered(home, gpu):
        return {"ok": False, "withdrawn": NEEDS[upscaler], "error": "This upscaler was taken out of GameCove for now: "
                + mirror.withdrawn(home)[NEEDS[upscaler]]}
    if upscaler not in upscalers_for(gpu):
        return {"ok": False, "error": f"{upscaler!r} isn't offered on this GPU ({', '.join(upscalers_for(gpu))})"}
    fg = int(fg or 0)
    if fg not in fg_for(gpu):
        return {"ok": False, "error": f"frame generation {fg}x isn't offered on this GPU"}
    rec = recommend(home, key, gpu, game_dir, online=online, xmx_off=get_launch(home, key).get("xmx") is False)
    d = rec["dir"]
    folder = _folder(home, key, d, rec)
    if not d or not folder:
        return {"ok": False, "error": "can't find this game's install folder or its exe"}
    if upscaler.startswith("fsr4_xmx"):
        if get_launch(home, key).get("xmx") is False:
            return {"ok": False, "error": "FSR 4.1.2 needs the XMX cores, and XMX is off for this game: pick XeSS 2, or switch XMX on first"}
        if str(key).isdigit():
            proof = xess.xmx_proof(home, key, os.path.join(home, DATA))
            if proof["state"] in ("stale", "failed"):
                return {"ok": False, "error": "FSR 4.1.2 needs the XMX cores, and this game's last launch ran without them "
                        "(a black screen with FSR 4.1.2): start it once with XeSS 2, then FSR 4.1.2 is offered again"}
        if optiscaler.fsr4_xmx_missing(home):
            try:                               # from the package, a pair in Downloads, or the download as before
                fsr4_ready(home, download=True)
            except OSError:
                pass
        missing = optiscaler.fsr4_xmx_missing(home)
        if missing:
            return {"ok": False, "error": f"FSR 4.1.2 on XMX needs nitec's files in {os.path.join(home, optiscaler.FSR4_XMX_DIR)} (missing: {', '.join(missing)})"}
    if upscaler == "own":
        out = optiscaler.unpatch(folder, home)
        ref = reframework.remove(folder, _ref_shas(home))
        _forget(home, key)
        r = set_launch(home, key, {**{k: None for k in REC_KEYS}, "fg": fg or None}, gpu)
        return {**r, "optiscaler": out, "reframework_left": bool(ref.get("present") and not ref.get("removed"))}
    bad = _foreign(optiscaler.owner(folder)["owner"]) or _refused(d, folder, anticheat, rec)
    if bad:
        return bad
    gens = chips.generators(gpu)
    if generator not in (None, "") and generator not in gens:
        return {"ok": False, "error": f"{generator!r} frame generation isn't offered on this GPU"}
    amd = vendor(gpu) != "intel"
    launch = {"opti": upscaler, "opti_fg": rec["fg_source"] if fg else "off", "opti_ini": rec["ini"] if rec["optiscaler"] else {},
              "fg": fg or None, "reframework": True if rec["re_engine"] else None, "fsr": None, "opti_xefg": None,
              "proton_fsr4": None, "fg_out": (generator or get_launch(home, key).get("fg_out") or gens[0]) if amd and fg and gens else None,
              "fsr4_int8": True if upscaler == "fsr4_amd" and chips.tier(gpu) not in chips.FSR4_LISTED else None,
              "opti_overlay": overlay if isinstance(overlay, int) and overlay in launchenv.OVERLAYS else None}
    r = _opti_into(home, key, folder, {**{k: v for k, v in launch.items() if v is not None},
                                       "xmx": get_launch(home, key).get("xmx")}, gpu, rec.get("proxies"), d)
    if not r.get("ok"):
        return r
    launch["opti_dll"] = r["dll_override"]
    if vendor(gpu) == "intel" and str(key).isdigit():
        # ClawDeck's game_choose: XeSS and FSR 4.1.2 reach the XMX cores only through the shim in the prefix's driver
        # store, which Valve's Proton 11.0 doesn't make (the scope script does the same at every launch)
        shim = xmxscope.prefix_shim(home, str(key), xess.package_dir(home))
        log.info("game %s: XMX shim in the prefix: %s", key, "put there" if shim.get("placed") else shim.get("why") or "already there")
    if rec["re_engine"]:
        rf = reframework.install(home, folder, versions(home)["reframework"], bool(allow_unpinned))
        if not rf.get("ok"):
            return rf
    out = set_launch(home, key, launch, gpu)
    return {**out, "next": rec["reasons"][0]}


def apply_recommended(home: str, key: str, gpu: dict, game_dir: str | None = None, allow_unpinned: bool = False,
                      online: bool = False, anticheat: bool = False) -> dict:
    """ClawDeck's game_apply_recommended, for this GPU."""
    rec = recommend(home, key, gpu, game_dir, online=online, xmx_off=get_launch(home, key).get("xmx") is False)
    d = rec["dir"]
    folder = _folder(home, key, d, rec)
    if not d or not folder:
        return {"ok": False, "error": "can't find this game's install folder or its exe"}
    if rec.get("recommended") is False:
        return {"ok": False, "error": rec["reasons"][0]}
    launch = dict(rec["launch"])
    if rec["optiscaler"]:
        bad = _foreign(optiscaler.owner(folder)["owner"]) or _refused(d, folder, anticheat, rec)
        if bad:
            return bad
        r = _opti_into(home, key, folder, launch, gpu, rec.get("proxies"), d)
        if not r.get("ok"):
            return r
        launch["opti_dll"] = r["dll_override"]
    if rec["re_engine"]:
        r = reframework.install(home, folder, versions(home)["reframework"], bool(allow_unpinned))
        if not r.get("ok"):
            return r
    clean = {k: None for k in REC_KEYS}
    clean.update(launch)
    r = set_launch(home, key, clean, gpu)
    return {**r, "recommended": rec, "next": rec["reasons"][0]}


def undo(home: str, key: str, gpu: dict, game_dir: str | None = None) -> dict:
    """ClawDeck's game_undo_recommended: REFramework and OptiScaler out, the launch settings cleared."""
    d = _game_dir(home, key, game_dir)
    t = tracked_folder(home, key, d)
    folder = (t if t and os.path.isdir(t) else None) or (optiscaler.main_exe_dir(d) if d else None)
    removed = reframework.remove(folder, _ref_shas(home)) if folder else {"ok": True}
    opti = optiscaler.unpatch(folder, home) if folder else {"ok": True}
    _forget(home, key)
    r = set_launch(home, key, {k: None for k in REC_KEYS}, gpu)
    return {**r, "reframework": removed, "optiscaler": opti, "ok": r.get("ok", True) and opti.get("ok", True)}


def status(home: str, key: str, gpu: dict, game_dir: str | None = None) -> dict:
    """What is set and what is in the folder now, read-only (the control reads this)."""
    d = _game_dir(home, key, game_dir)
    launch = get_launch(home, key)
    t = tracked_folder(home, key, d)
    folder = (t if t and os.path.isdir(t) else None) or (optiscaler.main_exe_dir(d) if d else None)
    who = optiscaler.owner(folder)
    opti = launch.get("opti")
    upscaler = "own" if not opti or opti == "off" or who["owner"] != "gamecove" else ("fsr4_xmx" if opti == "fsr4" else opti)
    fg = int(launch.get("fg") or 0)
    if vendor(gpu) == "amd" and launch.get("opti_fg") not in (None, "off"):
        fg = 2
    env = {}
    try:
        env = launchenv.compose(launch, per_game(home, gpu), vendor(gpu))
    except ValueError:
        pass
    out = {"dir": d, "folder": folder, "owner": who["owner"], "upscaler": upscaler, "fg": fg, "launch": launch,
           "env": env, "upscalers": upscalers_for(gpu), "frame_gens": fg_for(gpu)}
    if who["owner"] == "gamecove":
        entry = _opti_entry(launch, home)
        out.update({"opti_version": who.get("version"), "opti_latest": entry["version"],
                    "game_update": game_outdated(folder, entry)})
    return out


# ---- keeping a game's copy current ------------------------------------------------------------------------------
def game_outdated(folder: str | None, entry: dict) -> bool:
    """GameCove's OptiScaler in this game folder is older than `entry`: another OptiScaler version, or an extra
    (OptiPatcher, fakenvapi) whose bytes in the game aren't the entry's."""
    m = optiscaler._manifest(folder) if folder else None
    if not m:
        return False
    if m.get("version") != entry.get("version"):
        return True
    hashes = m.get("sha256") or {}
    for x in entry.get("extras", []):
        for rel, sha in optiscaler.extra_hashes(x).items():
            if sha and rel in hashes and hashes[rel] != sha:
                return True
    return False


def game_update(home: str, key: str, gpu: dict, game_dir: str | None = None) -> dict:
    """Bring GameCove's OptiScaler in this game up to the newest (and its REFramework, if GameCove put one there),
    with the game's own settings kept. patch() takes the older version out first exactly as undo does (only files
    whose sha256 is still what GameCove put there; backups never over newer game files), or, for the same
    OptiScaler, replaces only GameCove's own files."""
    d = _game_dir(home, key, game_dir)
    t = tracked_folder(home, key, d)
    folder = (t if t and os.path.isdir(t) else None) or (optiscaler.main_exe_dir(d) if d else None)
    who = optiscaler.owner(folder)
    if who["owner"] != "gamecove":
        return {"ok": False, "error": "GameCove's OptiScaler isn't in this game"}
    launch = get_launch(home, key)
    entry = _opti_entry(launch, home)
    if not game_outdated(folder, entry):
        return {"ok": True, "up_to_date": True, "version": who.get("version"), "folder": folder}
    r = _opti_into(home, key, folder, launch, gpu, [who["dll"]] if who.get("dll") else None, d)
    if not r.get("ok"):
        return r
    out = {"ok": True, "version": r.get("version"), "was": who.get("version"), "folder": folder}
    if r.get("dll_override") and r["dll_override"] != launch.get("opti_dll"):
        out["launch"] = set_launch(home, key, {"opti_dll": r["dll_override"]}, gpu)
    if launch.get("reframework") and reframework.status(folder).get("ours"):
        rf = reframework.install(home, folder, versions(home)["reframework"])
        out["reframework"] = rf
        if not rf.get("ok"):
            out.update(ok=False, error=f"OptiScaler is updated; REFramework: {rf.get('error')}")
    prune(home)
    return out


def prune(home: str) -> list[str]:
    """Delete downloaded OptiScaler packages nothing needs any more: not the newest of either kind, and not the
    version any game GameCove patched still runs (its undo compares against the package files)."""
    if mirror.load(home) is None:        # only with the verified newest known: never prune on the pins alone
        return []
    v = versions(home)
    keep = {(v.get(k) or {}).get("version") for k in ("optiscaler", "optiscaler_v10")}
    for key in list(load_state(home)["opti_games"]):
        folder = tracked_folder(home, key)
        m = optiscaler._manifest(folder) if folder else None
        if m:
            keep.add(m.get("version"))
    gone = []
    for p in optiscaler.packages(home):
        if p["version"] not in keep:
            shutil.rmtree(p["dir"], ignore_errors=True)
            gone.append(p["version"])
    return gone
