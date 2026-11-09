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
"""
from __future__ import annotations

import argparse
import json
import os
import sys

from . import framegen, games, launchenv, livedb, optiscaler, xess

COMMANDS = ("recommend", "status", "choose", "apply", "undo", "state", "refresh", "latency")


def _state(home: str, gpu: dict) -> dict:
    v = games.versions()
    e = v["optiscaler"]
    return {"optiscaler": {"version": e["version"], "installed": optiscaler.installed(home, e["version"])},
            "decky_framegen": framegen.state(home),
            "xess": xess.state(home) if games.vendor(gpu) == "intel" else None,
            "fsr4_xmx_missing": optiscaler.fsr4_xmx_missing(home),
            "fsr4_amd_missing": optiscaler.fsr4_amd_missing(home),
            "upscalers": games.upscalers_for(gpu), "frame_gens": games.fg_for(gpu), "vendor": games.vendor(gpu)}


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
    a = p.parse_args(argv)
    gpu = json.loads(a.gpu)
    if not isinstance(gpu, dict):
        raise ValueError("--gpu must be a JSON object")
    home = a.home
    if a.command in ("recommend", "status", "choose", "apply", "undo", "latency") and not a.key:
        raise ValueError(f"{a.command} needs --key")
    if a.command == "recommend":
        return {"ok": True, **games.recommend(home, a.key, gpu, a.dir, a.name, a.online)}
    if a.command == "status":
        return {"ok": True, **games.status(home, a.key, gpu, a.dir)}
    if a.command == "choose":
        return games.choose(home, a.key, a.upscaler, a.fg, gpu, a.dir, a.overlay, a.allow_unpinned, a.online)
    if a.command == "apply":
        return games.apply_recommended(home, a.key, gpu, a.dir, a.allow_unpinned, a.online)
    if a.command == "undo":
        return games.undo(home, a.key, gpu, a.dir)
    if a.command == "state":
        return {"ok": True, **_state(home, gpu)}
    if a.command == "refresh":
        return {"ok": True, "lists": livedb.refresh(os.path.join(home, games.LISTS), games.BUNDLED_GAMES)}
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
