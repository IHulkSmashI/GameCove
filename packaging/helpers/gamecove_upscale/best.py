"""Best for your handheld: the plan for one game in plain words, setting it up ahead of the first start, and the
read-out afterwards. On top of games.py (ClawDeck's per-game flow, same author); nothing here places a file itself.

Per game there is one saved mode (upscale.json "mode"):
  best    (default) GameCove picks from chips.py's table and what the game ships, and keeps it set up
  custom  the user picked an upscaler / frame generation themselves (games.choose); GameCove leaves it alone
  native  the game's own settings: everything GameCove put into the game is taken out and nothing is added

prepare() is what runs when a game is installed, updated, opened or about to start: in "best" mode it puts the plan in
when that is safe and it isn't there yet, repairs files a game update removed, and falls back (FSR 4 -> FSR 3.1,
FSR 4.1.2 on XMX -> XeSS 2) when the last start shows the pick didn't come up. Safe means: no anti-cheat, no other
injector, not marked broken, and for a game no list knows, only when what it ships makes the route certain (DirectX
12 with DLSS or FSR 3.1 DLLs) and then without frame generation. Anything else is offered, not done.
"""
from __future__ import annotations

import os
import time

from . import active, chips, games, guard, launchenv, optiscaler, xess

MODES = ("best", "custom", "native")
FALLBACK = {"fsr4_amd": "fsr31", "fsr4_xmx": "xess", "fsr4_xmx_lite": "xess"}
# how many starts in a row may show "didn't come up" before the fallback is taken
STRIKES = 2


def get_mode(home: str, key: str) -> str:
    m = (games.load_state(home).get("mode") or {}).get(str(key))
    return m if m in MODES else "best"


def set_mode(home: str, key: str, mode: str) -> None:
    if mode not in MODES:
        raise ValueError(f"mode must be one of {', '.join(MODES)}")
    s = games.load_state(home)
    s.setdefault("mode", {})
    if mode == "best":
        s["mode"].pop(str(key), None)
    else:
        s["mode"][str(key)] = mode
    for k in ("strikes", "fell_back"):
        (s.get(k) or {}).pop(str(key), None)
    games.save_state(home, s)


def _stamp(home: str, key: str) -> float:
    try:
        return os.path.getmtime(os.path.join(home, games.DATA, "launch", f"{key}.started"))
    except OSError:
        return 0.0


def _installed_at(folder: str | None) -> float:
    try:
        return os.path.getmtime(os.path.join(folder, optiscaler.STATE, "manifest.json")) if folder else 0.0
    except OSError:
        return 0.0


def plan(home: str, key: str, gpu: dict, game_dir: str | None = None, name: str | None = None,
         anticheat: bool = False) -> dict:
    """What "Best for your handheld" would do for this game and whether it may do it by itself. Read-only."""
    rec = games.recommend(home, key, gpu, game_dir, name, xmx_off=games.get_launch(home, key).get("xmx") is False)
    d, folder = rec["dir"], rec.get("folder")
    caps = rec["chip"]
    entry = rec.get("entry") or {}
    out = {"ok": True, "mode": get_mode(home, key), "chip": caps, "route": rec["route"], "upscaler": rec.get("upscaler") or "own",
           "launch": rec["launch"], "reasons": rec["reasons"], "known": bool(entry.get("known")), "api": rec.get("api", ""),
           "engine": rec.get("engine", ""), "ships": rec.get("ships"), "applied": rec["applied"], "folder": folder, "dir": d,
           "files": bool(rec.get("optiscaler")), "refused": None, "auto": False, "why_not": ""}
    if not d:
        out.update(why_not="We can't find this game's folder yet.")
        return out
    no = guard.refusal(d, folder, anticheat, entry)
    foreign = rec.get("opti_owner") not in (None, "gamecove", "none", "")
    if no:
        out.update(refused=no["code"], why_not=no["error"])
    elif foreign and rec.get("optiscaler"):
        out.update(refused="foreign", why_not=(games._foreign(rec["opti_owner"]) or {}).get("error", "Another tool's OptiScaler is in this game."))
    elif rec.get("recommended") is False:
        out.update(refused="listed", why_not=rec["reasons"][0])
    elif not rec["launch"]:
        out.update(why_not="")                      # nothing to add: the game's own is the best here
    elif not rec.get("optiscaler"):
        out["auto"] = True                          # environment only (Proton's FSR 4 upgrade): nothing in the folder
    elif entry.get("known") or rec.get("re_engine"):
        out["auto"] = True
    elif rec.get("dx12") and (set(rec["ships"]["upscaler"]) & {"DLSS", "FSR"}) and folder:
        out["auto"] = True
        out["unknown_safe"] = True
    else:
        out.update(why_not="We don't know this game yet and can't tell how it renders, so nothing is added by itself. "
                           "You can still pick an upscaler below.")
    out["line"] = headline(out, rec)
    return out


def headline(p: dict, rec: dict) -> str:
    if p["refused"]:
        return p["why_not"]
    if not rec["launch"]:
        return rec["reasons"][0]
    up = active.LABELS.get(p["upscaler"], p["upscaler"])
    return f"Best here: {up}. {rec['reasons'][0]}"


def prepare(home: str, key: str, gpu: dict, game_dir: str | None = None, name: str | None = None,
            anticheat: bool = False, allow_unpinned: bool = False) -> dict:
    """Set the game up ahead of its start (see the module text). Returns {"ok", "did": what changed or "",
    "plan": plan()}; never raises for a game it must leave alone."""
    mode = get_mode(home, key)
    if mode == "native":
        return {"ok": True, "did": "", "mode": mode}
    p = plan(home, key, gpu, game_dir, name, anticheat)
    if p["refused"] == "anticheat" and (games.load_state(home)["opti_games"].get(str(key)) or games.get_launch(home, key)):
        # the game gained anti-cheat (an update, or our data learnt it): everything of ours comes out
        r = games.undo(home, key, gpu, game_dir)
        return {"ok": bool(r.get("ok", True)), "did": "removed: this game has anti-cheat", "mode": mode, "plan": p}
    if mode == "custom":
        return {"ok": True, "did": _repair(home, key, gpu, game_dir) or "", "mode": mode, "plan": p}
    fb = _fallback(home, key, gpu, game_dir, p)
    if fb:
        return {"ok": True, "did": fb, "mode": mode, "plan": p}
    cur = games.get_launch(home, key)
    if p["files"]:
        done = cur.get("opti") == p["launch"].get("opti") and optiscaler.owner(p["folder"])["owner"] == "gamecove"
    else:
        done = p["applied"]
    if not p["auto"] or done:
        return {"ok": True, "did": "", "mode": mode, "plan": p}
    if (games.load_state(home).get("fell_back") or {}).get(str(key)):
        return {"ok": True, "did": "", "mode": mode, "plan": p}      # the fallback stays until the user picks again
    launch = dict(p["launch"])
    if p.get("unknown_safe") and not launch.get("reframework"):
        launch["opti_fg"] = "off"                       # a game no list knows: the upscaler only
    if launch != p["launch"]:
        r = games.choose(home, key, launch.get("opti", "own"), 0, gpu, game_dir, anticheat=anticheat)
        if r.get("ok"):
            set_mode(home, key, "best")
    else:
        r = games.apply_recommended(home, key, gpu, game_dir, allow_unpinned, anticheat=anticheat)
    return {"ok": bool(r.get("ok")), "did": "set up" if r.get("ok") else "", "error": r.get("error"), "mode": mode, "plan": p}


def _repair(home: str, key: str, gpu: dict, game_dir: str | None) -> str:
    """A game update (or "Verify files") took our files out while the launch settings still ask for them: put the
    same choice back."""
    launch = games.get_launch(home, key)
    folder = games.load_state(home)["opti_games"].get(str(key))
    if not folder or launch.get("opti") in (None, "off"):
        return ""
    if optiscaler.owner(folder)["owner"] == "gamecove" and _proxy_there(folder):
        return ""
    r = games.choose(home, key, launch["opti"], int(launch.get("fg") or 0) or (2 if launch.get("opti_fg") not in (None, "off") else 0),
                     gpu, game_dir, launch.get("opti_overlay"), generator=launch.get("fg_out"))
    return "put back after a game update" if r.get("ok") else ""


def _proxy_there(folder: str) -> bool:
    m = optiscaler._manifest(folder) or {}
    return all(os.path.isfile(os.path.join(folder, *str(x).split("/"))) for x in (m.get("added") or [])[:40])


def _fallback(home: str, key: str, gpu: dict, game_dir: str | None, p: dict) -> str:
    """The pick didn't come up in the last starts: one step down, once, and say so."""
    launch = games.get_launch(home, key)
    cur = launch.get("opti")
    if cur not in FALLBACK:
        return _repair(home, key, gpu, game_dir)
    st = status(home, key, gpu, game_dir)
    s = games.load_state(home)
    strikes = s.setdefault("strikes", {})
    seen = s.setdefault("seen_start", {})
    started = _stamp(home, key)
    if not started or seen.get(str(key)) == started:
        return _repair(home, key, gpu, game_dir)
    seen[str(key)] = started
    bad = st["active"]["state"] == "not_loaded" or (st["active"]["state"] == "loaded" and st["active"].get("errors"))
    strikes[str(key)] = strikes.get(str(key), 0) + 1 if bad else 0
    games.save_state(home, s)
    if strikes[str(key)] < STRIKES:
        return _repair(home, key, gpu, game_dir)
    r = games.choose(home, key, FALLBACK[cur], int(launch.get("fg") or 0), gpu, game_dir, launch.get("opti_overlay"),
                     generator=launch.get("fg_out"))
    if not r.get("ok"):
        return ""
    s = games.load_state(home)
    s.setdefault("fell_back", {})[str(key)] = {"from": cur, "to": FALLBACK[cur], "at": int(time.time())}
    s.get("strikes", {}).pop(str(key), None)
    games.save_state(home, s)
    return f"{active.LABELS[cur]} didn't start in this game twice: switched to {active.LABELS[FALLBACK[cur]]}"


def status(home: str, key: str, gpu: dict, game_dir: str | None = None) -> dict:
    """games.status plus the mode and the read-out of the last start (active.state)."""
    st = games.status(home, key, gpu, game_dir)
    launch = st["launch"]
    fg = int(st.get("fg") or 0)
    intel = games.vendor(gpu) == "intel"
    gen = "xefg" if intel else (launch.get("fg_out") or (chips.generators(gpu) or [""])[0])
    env_only = bool(launch.get("proton_fsr4")) and st["owner"] != "gamecove"
    up = "fsr" if env_only else st["upscaler"]
    xmx = None
    if intel and gpu.get("xmx") and str(key).isdigit() and up.startswith("fsr4_xmx"):
        try:
            xmx = xess.xmx_proof(home, key, os.path.join(home, games.DATA))
        except OSError:
            xmx = None
    a = active.state(st.get("folder"), st["owner"], up, fg, gen, chips.latency(gpu, gen if fg else ""),
                     _stamp(home, key), _installed_at(st.get("folder")), env_only, xmx)
    fb = (games.load_state(home).get("fell_back") or {}).get(str(key))
    if fb and a["state"] != "own":
        a["line"] += f" ({active.LABELS.get(fb['from'], fb['from'])} didn't start here, so we switched.)"
    return {**st, "ok": True, "mode": get_mode(home, key), "active": a, "generator": gen if fg else "",
            "generators": chips.generators(gpu), "chip": chips.capabilities(gpu), "fell_back": fb}


def native(home: str, key: str, gpu: dict, game_dir: str | None = None) -> dict:
    """"Native": everything GameCove put into the game out again, nothing added from now on."""
    r = games.undo(home, key, gpu, game_dir)
    set_mode(home, key, "native")
    return {**r, "ok": bool(r.get("ok", True)), "mode": "native"}


def menu_key(home: str, key: str, gpu: dict, game_dir: str | None = None) -> dict:
    """The key that opens OptiScaler's own menu in this game (Insert; the Capcom setup keeps it too, REFramework's
    moves to Delete), or why there is none."""
    st = games.status(home, key, gpu, game_dir)
    if st["owner"] != "gamecove":
        return {"ok": False, "error": "Our upscaler isn't in this game, so it has no menu to open."}
    return {"ok": True, "key": "Insert", "keysym": "Insert", "capcom": launchenv.capcom(st["launch"])}
