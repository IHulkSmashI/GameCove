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

from . import framegen, gamedb, launchenv, livedb, mirror, optiscaler, reframework, xess, xmxscope

log = logging.getLogger("gamecove.games")

HERE = os.path.dirname(os.path.realpath(__file__))
BUNDLED_GAMES = os.path.join(HERE, "data", "games.json")
VERSIONS = os.path.join(HERE, "data", "versions.json")
DATA = ".local/share/gamecove"
STATE = os.path.join(DATA, "upscale.json")
LISTS = os.path.join(DATA, "lists")
REC_KEYS = ("opti", "opti_xefg", "opti_fg", "opti_ini", "reframework", "fsr", "opti_dll", "opti_overlay")
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


# ---- the GPU ----------------------------------------------------------------------------------------------------
def vendor(gpu: dict) -> str:
    v = str(gpu.get("vendor") or "")
    if v in ("intel", "amd"):
        return v
    fam = str(gpu.get("family") or "")
    return "intel" if fam.startswith("intel") else "amd" if fam.startswith("amd") else "other"


def upscalers_for(gpu: dict) -> list[str]:
    """The upscaler choices this GPU gets (the first is always the game's own)."""
    v = vendor(gpu)
    if v == "intel":
        return list(INTEL_UPSCALERS) if gpu.get("xmx") else ["own", "xess"]
    if v == "amd":
        return list(AMD_UPSCALERS) if str(gpu.get("arch")) in FSR4_AMD_ARCHS else ["own", "fsr31"]
    return ["own"]


def fg_for(gpu: dict) -> list[int]:
    """Frame generation multipliers: XeSS-FG 2x-4x on XMX, FSR-FG 2x on AMD, none elsewhere."""
    v = vendor(gpu)
    if v == "intel" and gpu.get("xmx"):
        return [0, 2, 3, 4]
    if v == "amd":
        return [0, 2]
    return [0]


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


def _for_gpu(rec: dict, d: str | None, gpu: dict) -> None:
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
        rec.update(route="own", optiscaler=False, launch={}, upscaler=None, frame_gen=None,
                   reasons=["Unknown GPU: only the game's own settings apply."])
        return
    ships = rec.get("ships") or {}
    if "FSR" in ships.get("upscaler", []) and not rec.get("re_engine"):
        rec.update(route="own_fsr", optiscaler=False, launch={}, upscaler=None, frame_gen=None, ini={}, later=[])
        rec["reasons"] = ["This game ships FSR: pick it in its graphics menu. Proton-CachyOS or GE-Proton upgrade "
                          "FSR 3.1 to FSR 4 on RDNA3 by themselves (Launcher sets it)."
                          + (" Its own FSR frame generation works too." if "FSR-FG" in ships.get("fg", []) else "")]
        return
    if rec["route"] == "own_xess":                         # XeSS only: OptiScaler can turn it into FSR 3.1
        rec.update(route="optiscaler", optiscaler=True)
        launch = {"opti_fg": "off", "opti_ini": rec.get("ini") or {}}
        rec["reasons"] = ["This game ships XeSS (slow on AMD without XMX): OptiScaler turns it into FSR 3.1. "
                          "Pick XeSS in the game's graphics menu."]
    launch["opti"] = "fsr31"
    if launch.get("opti_fg") not in (None, "off", "dlssg", "fsrfg", "upscaler"):
        launch["opti_fg"] = "off"
    rec["launch"] = launch
    rec["upscaler"] = "fsr31"
    first = rec["reasons"][0]
    first = first.replace("XeSS on the XMX cores", "FSR 3.1").replace("into XeSS", "into FSR 3.1")
    first = first.replace("(XeSS on the XMX cores)", "(FSR 3.1)").replace("XeSS frame generation", "FSR frame generation")
    rec["reasons"][0] = first
    if rec.get("re_engine"):
        rec["reasons"].append("The Capcom setup is tested on Intel only; on AMD it runs with FSR 3.1 and FSR frame generation.")
    if str(gpu.get("arch")) in FSR4_AMD_ARCHS and d and gamedb.is_dx12(d, rec.get("main_exes")):
        rec["reasons"].append("FSR 4 (AMD's 4.1.2 upscaler) is available for this DirectX 12 game: sharper, costs a few fps.")


def recommend(home: str, key: str, gpu: dict, game_dir: str | None = None, name: str | None = None,
              online: bool = False, xmx_off: bool = False) -> dict:
    """ClawDeck's _rec + game_recommend, for this GPU."""
    d = _game_dir(home, key, game_dir)
    rec = gamedb.recommend(gamedb.load(games_path(home)), d)
    folder = optiscaler.main_exe_dir(d, rec["main_exes"]) if d else None
    if name is None and str(key).isdigit():
        name = xess.steam_app_name(home, key)
    _supported_list_verdict(home, rec, key, gpu)
    _optiscaler_entry(home, rec, name, online)
    _prefer_fsr4(home, rec, d, gpu, xmx_off)
    _for_gpu(rec, d, gpu)
    launch = get_launch(home, key)
    applied = bool(rec["launch"]) and all(launch.get(k) == v for k, v in rec["launch"].items())
    dx12 = gamedb.is_dx12(d, rec["main_exes"]) if d else False
    return {**rec, "dir": d, "folder": folder, "applied": applied, "opti_owner": optiscaler.owner(folder)["owner"],
            "dx12": dx12, "upscalers": upscalers_for(gpu), "frame_gens": fg_for(gpu), "vendor": vendor(gpu),
            "fsr4_xmx_missing": optiscaler.fsr4_xmx_missing(home) if vendor(gpu) == "intel" and gpu.get("xmx") else [],
            "fsr4_amd_missing": optiscaler.fsr4_amd_missing(home) if vendor(gpu) == "amd" else [],
            "reframework_state": reframework.status(folder) if folder and rec["re_engine"] else None,
            "decky_framegen": framegen.state(home)}


# ---- putting it in ----------------------------------------------------------------------------------------------
def _opti_entry(launch: dict, home: str | None = None) -> dict:
    v = versions(home)
    return v["optiscaler_v10"] if launchenv.v10(launch) and v.get("optiscaler_v10") else v["optiscaler"]


def _ref_shas(home: str | None = None) -> tuple[str, ...]:
    """REFramework builds GameCove installs: the tested one and the index's newest."""
    shas = [(e.get("reframework") or {}).get("dll_sha256") for e in (pins(), versions(home))]
    return tuple(dict.fromkeys(x for x in shas if x))


def _opti_into(home: str, key: str, folder: str, launch: dict, gpu: dict, proxies: list[str] | None = None) -> dict:
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
    r = optiscaler.patch(home, folder, entry["version"], launchenv.opti_ini({**launch, "opti": opti}, v), opti,
                         opti in launchenv.FSR4_XMX, entry.get("layout") or "flat", proxies,
                         fsr4_amd=opti == "fsr4_amd", force_reflex="2" if v == "intel" else None)
    if r.get("ok"):
        s = load_state(home)
        s["opti_games"][str(key)] = folder
        save_state(home, s)
    return r


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
    return load_state(home)["opti_games"].get(str(key)) or rec.get("folder") or (optiscaler.main_exe_dir(d) if d else None)


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
           overlay: int | None = None, allow_unpinned: bool = False, online: bool = False) -> dict:
    """ClawDeck's game_choose, for this GPU: the upscaler (the game's own, or one through GameCove's OptiScaler)
    and frame generation (0 off, else the multiplier). Everything they need is put in or taken out here."""
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
        s = load_state(home)
        s["opti_games"].pop(str(key), None)
        save_state(home, s)
        r = set_launch(home, key, {**{k: None for k in REC_KEYS}, "fg": fg or None}, gpu)
        return {**r, "optiscaler": out, "reframework_left": bool(ref.get("present") and not ref.get("removed"))}
    bad = _foreign(optiscaler.owner(folder)["owner"])
    if bad:
        return bad
    launch = {"opti": upscaler, "opti_fg": rec["fg_source"] if fg else "off", "opti_ini": rec["ini"] if rec["optiscaler"] else {},
              "fg": fg or None, "reframework": True if rec["re_engine"] else None, "fsr": None, "opti_xefg": None,
              "opti_overlay": overlay if isinstance(overlay, int) and overlay in launchenv.OVERLAYS else None}
    r = _opti_into(home, key, folder, {**{k: v for k, v in launch.items() if v is not None},
                                       "xmx": get_launch(home, key).get("xmx")}, gpu, rec.get("proxies"))
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
                      online: bool = False) -> dict:
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
        bad = _foreign(optiscaler.owner(folder)["owner"])
        if bad:
            return bad
        r = _opti_into(home, key, folder, launch, gpu, rec.get("proxies"))
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
    folder = load_state(home)["opti_games"].get(str(key)) or (optiscaler.main_exe_dir(d) if d else None)
    removed = reframework.remove(folder, _ref_shas(home)) if folder else {"ok": True}
    opti = optiscaler.unpatch(folder, home) if folder else {"ok": True}
    s = load_state(home)
    s["opti_games"].pop(str(key), None)
    save_state(home, s)
    r = set_launch(home, key, {k: None for k in REC_KEYS}, gpu)
    return {**r, "reframework": removed, "optiscaler": opti, "ok": r.get("ok", True) and opti.get("ok", True)}


def status(home: str, key: str, gpu: dict, game_dir: str | None = None) -> dict:
    """What is set and what is in the folder now, read-only (the control reads this)."""
    d = _game_dir(home, key, game_dir)
    launch = get_launch(home, key)
    folder = load_state(home)["opti_games"].get(str(key)) or (optiscaler.main_exe_dir(d) if d else None)
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
    folder = load_state(home)["opti_games"].get(str(key)) or (optiscaler.main_exe_dir(d) if d else None)
    who = optiscaler.owner(folder)
    if who["owner"] != "gamecove":
        return {"ok": False, "error": "GameCove's OptiScaler isn't in this game"}
    launch = get_launch(home, key)
    entry = _opti_entry(launch, home)
    if not game_outdated(folder, entry):
        return {"ok": True, "up_to_date": True, "version": who.get("version"), "folder": folder}
    r = _opti_into(home, key, folder, launch, gpu, [who["dll"]] if who.get("dll") else None)
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
    for folder in load_state(home)["opti_games"].values():
        m = optiscaler._manifest(folder) if folder else None
        if m:
            keep.add(m.get("version"))
    gone = []
    for p in optiscaler.packages(home):
        if p["version"] not in keep:
            shutil.rmtree(p["dir"], ignore_errors=True)
            gone.append(p["version"])
    return gone
