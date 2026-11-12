"""gamecove-upscale: the command GameCove's perf controls run (through its command runner) for per-game upscaling.

  gamecove-upscale <command> --home HOME [--key KEY] [--gpu JSON] [--dir GAME_DIR] [options]

Prints one JSON object on stdout and exits 0 (also for {"ok": false, "error": ...}); exit 2 is bad usage. Commands:
  recommend   what the game ships and what this GPU should use (games.recommend)
  status      what is set for the game and whose OptiScaler is in its folder (read-only)
  choose      --upscaler U --fg N [--overlay N]: put it in (or take it out with "own")
  apply       the recommended setup;  undo: everything GameCove put into the game out again
  state       OptiScaler package, Decky Framegen, the XeSS XMX driver, the FSR 4 files (read-only)
  refresh     the per-game lists (ClawDeck's games.json, OptiScaler's compatibility list), at most twice a day
  latency     what XeLL did in the game's last launch (Intel XMX)
  xess-install  the XeSS XMX driver (xess-xmx-linux, pinned in versions.json): the installer's one-time
                option on Intel Arc handhelds with XMX; --gpu must say xmx=1. Runs as the desktop user.
  xess-remove   take out a driver GameCove installed (its own uninstall.sh), as on uninstall
  check       per component: the version here, the newest, "update" (upkeep.check); --online fetches the signed
              upscalers index first (GameCove's background check, at most daily, and the Check button)
  update      every downloaded component that has a newer version ([--component ID] for one); games keep theirs
  game-update --key KEY: GameCove's OptiScaler in this game (and its REFramework) up to the newest, settings kept
  fsr4-rollback  the FSR 4.1.2 XMX files in ~/fsr4-xmx back to the set before the last update (the one replaced is
                 kept in its place, so running it again returns to the newer set)

Which versions: the newest from GameCove's signed upscalers index (mirror.py), fetched before anything is
installed; without a verified index, the tested pins in data/versions.json. Every file is sha256 checked.
"""
from __future__ import annotations

import argparse
import json
import os
import sys

from . import best, chips, downloads, framegen, games, launchenv, livedb, lsfg, mirror, optiscaler, upkeep, xess

COMMANDS = ("recommend", "status", "choose", "apply", "undo", "state", "refresh", "latency", "xess-install", "xess-remove",
            "check", "update", "game-update", "plan", "prepare", "mode", "native", "caps", "lsfg-install", "lsfg-remove", "lsfg-state", "storage", "purge",
            "fsr4-rollback", "opt-in")
# commands that may download: the signed index is fetched (at most every mirror.FRESH_S) before they run
INSTALLS = ("choose", "apply", "xess-install", "game-update", "opt-in")
# GameCove: "best for your handheld" (best.py)
#   plan      what GameCove would pick for the game and whether it may set it up by itself (read-only)
#   prepare   set the game up ahead of its start when that is safe (run when a game is installed, updated or opened)
#   opt-in    the player takes our pick for a game we don't set up by ourselves (an online game, one no list knows)
#   mode      --mode best|custom|native: how the game is handled;  native: everything out, nothing added
#   caps      what this GPU can run (chips.capabilities), no game needed
#   status    also answers "active": the read-out of the last start, and "mode"
# commands that first do what ClawDeck does at every plugin start (games.xmx_upkeep): Protons added since the XeSS
# XMX driver was installed get the per-game scope, and the FSR 4.1.2 XMX files that came with the package go to
# ~/fsr4-xmx when they aren't there. Not "status" / "latency": those only read.
XMX_UPKEEP = ("state", "recommend", "check", "choose", "apply", "update", "game-update", "plan", "prepare", "mode", "opt-in")


def _state(home: str, gpu: dict) -> dict:
    v = games.versions(home)
    e = v["optiscaler"]
    # the newest downloaded (an older one still runs games until it's updated); "latest": what GameCove would get now
    pk = [p["version"] for p in optiscaler.packages(home) if p["layout"] == (e.get("layout") or "flat")]
    have = e["version"] if optiscaler.installed(home, e["version"]) else (pk[0] if pk else None)
    return {"optiscaler": {"version": have or e["version"], "installed": bool(have), "latest": e["version"]},
            "decky_framegen": framegen.state(home),
            "xess": xess.state(home) if games.vendor(gpu) == "intel" else None,
            "fsr4_xmx_missing": optiscaler.fsr4_xmx_missing(home),
            "fsr4_xmx_set": {**optiscaler.fsr4_xmx_set(home), "packaged": (optiscaler.fsr4_packaged() or {}).get("version")},
            "fsr4_amd_missing": optiscaler.fsr4_amd_missing(home),
            "upscalers": games.upscalers_for(gpu), "frame_gens": games.fg_for(gpu), "vendor": games.vendor(gpu),
            "index": mirror.status(home)}


def parse_gpu(text: str) -> dict:
    """--gpu as a JSON object (what GameCove sends), or as vendor=amd,family=amd-rdna3,arch=RDNA3.5,xmx=0
    (older GameCove builds and the installer's fixed xess-install call)."""
    text = text.strip()
    if text.startswith("{"):
        gpu = json.loads(text)
        if not isinstance(gpu, dict):
            raise ValueError("--gpu must be a JSON object")
        return gpu
    gpu: dict = {}
    for part in filter(None, text.split(",")):
        k, sep, v = part.partition("=")
        if not sep or k not in ("vendor", "family", "arch", "xmx", "chip"):
            raise ValueError(f"bad --gpu entry {part!r}")
        gpu[k] = v in ("1", "true") if k == "xmx" else v
    return gpu


def run(argv: list[str]) -> dict:
    p = argparse.ArgumentParser(prog="gamecove-upscale")
    p.add_argument("command", choices=COMMANDS)
    p.add_argument("--home", required=True)
    p.add_argument("--key", default="")
    p.add_argument("--gpu", default="{}")
    p.add_argument("--dir", default=None)
    p.add_argument("--name", default=None)
    p.add_argument("--upscaler", default="own")
    p.add_argument("--fg", type=int, default=0)
    p.add_argument("--overlay", type=int, default=None)
    p.add_argument("--online", action="store_true")
    p.add_argument("--allow-unpinned", action="store_true")
    p.add_argument("--component", default=None, choices=sorted(mirror.NAMES))
    p.add_argument("--generator", default=None, choices=sorted(launchenv.FG_OUTS))
    p.add_argument("--mode", default=None, choices=best.MODES)
    p.add_argument("--anticheat", action="store_true", help="the app's data says this game has anti-cheat")
    p.add_argument("--no-download", action="store_true",
                   help="run by GameCove itself with Background lookups off: nothing is fetched from the network")
    a = p.parse_args(argv)
    downloads.NO_NETWORK = bool(a.no_download)
    gpu = parse_gpu(a.gpu)
    home = a.home
    if a.command in ("recommend", "status", "choose", "apply", "undo", "latency", "game-update", "plan", "prepare", "mode", "native", "opt-in") and not a.key:
        raise ValueError(f"{a.command} needs --key")
    if a.command in INSTALLS and not (a.command == "choose" and a.upscaler == "own") and not a.no_download:
        mirror.refresh(home)
    if a.command in XMX_UPKEEP:
        games.xmx_upkeep(home, gpu)
    if a.command == "storage":             # Settings > Device > Storage: what upscaling takes here (upkeep.storage)
        return upkeep.storage(home)
    if a.command == "purge":               # uninstall: every game as shipped, drivers out, the managed folders gone
        return upkeep.purge(home, gpu)
    if a.command == "lsfg-install":        # the user pressed "Set up Lossless frame generation" (lsfg.py)
        return lsfg.install(home, games.versions(home).get("lsfg_vk") or games.pins().get("lsfg_vk"))
    if a.command == "lsfg-remove":
        return lsfg.remove(home)
    if a.command == "lsfg-state":
        return {"ok": True, **lsfg.state(home)}
    if a.command == "caps":
        return {"ok": True, **chips.capabilities(gpu)}
    if a.command == "plan":
        return best.plan(home, a.key, gpu, a.dir, a.name, a.anticheat)
    if a.command == "prepare":
        return best.prepare(home, a.key, gpu, a.dir, a.name, a.anticheat, a.allow_unpinned)
    if a.command == "native":
        return best.native(home, a.key, gpu, a.dir)
    if a.command == "opt-in":
        return best.opt_in(home, a.key, gpu, a.dir, a.name, a.anticheat, a.allow_unpinned)
    if a.command == "mode":
        if a.mode == "native":
            return best.native(home, a.key, gpu, a.dir)
        if a.mode:
            best.set_mode(home, a.key, a.mode)
        return {"ok": True, "mode": best.get_mode(home, a.key),
                **(best.prepare(home, a.key, gpu, a.dir, a.name, a.anticheat) if a.mode == "best" else {})}
    if a.command == "check":
        return upkeep.check(home, gpu, refresh=a.online)
    if a.command == "update":
        return upkeep.update(home, gpu, a.component)
    if a.command == "game-update":
        return games.game_update(home, a.key, gpu, a.dir, a.name, a.anticheat)
    if a.command == "fsr4-rollback":
        return optiscaler.fsr4_xmx_rollback(home)
    if a.command == "recommend":
        return {"ok": True, **games.recommend(home, a.key, gpu, a.dir, a.name, a.online)}
    if a.command == "status":
        return best.status(home, a.key, gpu, a.dir)
    if a.command == "choose":
        r = games.choose(home, a.key, a.upscaler, a.fg, gpu, a.dir, a.overlay, a.allow_unpinned, a.online,
                         generator=a.generator, anticheat=a.anticheat, name=a.name)
        if r.get("ok"):
            best.set_mode(home, a.key, "custom")
        return r
    if a.command == "apply":
        r = games.apply_recommended(home, a.key, gpu, a.dir, a.allow_unpinned, a.online, anticheat=a.anticheat, name=a.name)
        if r.get("ok"):
            best.set_mode(home, a.key, "best")
        return r
    if a.command == "undo":
        return games.undo(home, a.key, gpu, a.dir)
    if a.command == "state":
        return {"ok": True, **_state(home, gpu)}
    if a.command == "xess-install":
        # same code path as ClawDeck's main.py xess_install (same author): pinned release, its install.sh as the user
        if games.vendor(gpu) != "intel" or not gpu.get("xmx"):
            return {"ok": False, "error": "this GPU has no XMX cores: XeSS runs on its general path without this driver"}
        return xess.install(home, games.versions(home)["xess_xmx_linux"], a.allow_unpinned)
    if a.command == "xess-remove":
        return xess.remove_for_uninstall(home)
    if a.command == "refresh":
        mirror.refresh(home)
        return {"ok": True, "lists": livedb.refresh(os.path.join(home, games.LISTS), games.BUNDLED_GAMES,
                                                    signed=lambda: mirror.fetch_data(home, "games"))}
    on = games.get_launch(home, a.key).get("low_latency", True) is not False
    return {"ok": True, **xess.game_latency(home, a.key, on)}


def main(argv: list[str] | None = None) -> int:
    try:
        out = run(sys.argv[1:] if argv is None else argv)
    except SystemExit as e:
        return int(e.code or 0) if e.code not in (0, None) else 2
    except (ValueError, OSError) as e:
        out = {"ok": False, "error": str(e)}
    print(json.dumps(out, default=str, sort_keys=True))
    return 0


__all__ = ["main", "run", "launchenv"]
