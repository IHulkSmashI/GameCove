"""Decky Framegen (github.com/xXJSONDeruloXx/Decky-Framegen) compatibility. GameCove installs its own pinned
OptiScaler per game (optiscaler.py) and no longer offers Decky Framegen; this module only says whether Decky
Framegen is installed and its ~/fgmod is set up (state), and whether a game's launch options run its fgmod
(uses_fgmod). Such a game is Decky Framegen's: the panel shows a warning and "Stop using Decky Framegen here", and
GameCove's wrapper still goes in front of fgmod ("gamecove-run ~/fgmod/fgmod %command%") so the presets are in
the environment when fgmod reads it.

GameCove ports only the read-only part (ClawDeck's install() is left out: GameCove never installs Decky Framegen).
Layout checked against Decky-Framegen v0.17 (96eb17b, 2026-07-26): ~/fgmod, the FRAMEGEN_PATCH marker and <proxy>.b
backups next to the game's exe.
"""
from __future__ import annotations

import glob
import json
import logging
import os

from . import sysfs

log = logging.getLogger("gamecove.framegen")

NAME = "Decky-Framegen"
PLUGINS = "homebrew/plugins"
FGMOD = "fgmod"


def plugin_dir(home: str) -> str | None:
    """Decky Framegen's folder in Decky's plugins, found by the name in its plugin.json (the folder name varies:
    "Decky-Framegen", "Decky Framegen", a store install's)."""
    for pj in sorted(glob.glob(os.path.join(home, PLUGINS, "*", "plugin.json"))):
        try:
            with open(pj, "r", encoding="utf-8") as f:
                if json.load(f).get("name") == NAME:
                    return os.path.dirname(pj)
        except (OSError, ValueError):
            continue
    return None


def _version_of(d: str) -> str | None:
    try:
        with open(os.path.join(d, "package.json"), "r", encoding="utf-8") as f:
            return json.load(f).get("version")
    except (OSError, ValueError):
        return None


def optiscaler_version(home: str) -> str | None:
    fg = os.path.join(home, FGMOD)
    try:
        with open(os.path.join(fg, "install-manifest.json"), "r", encoding="utf-8") as f:
            v = (json.load(f).get("optiscaler") or {}).get("version")
            if v:
                return str(v)
    except (OSError, ValueError, AttributeError):
        pass
    return (sysfs.read(os.path.join(fg, "version.txt")) or "").strip() or None


def state(home: str) -> dict:
    d = plugin_dir(home)
    fgmod = os.path.join(home, FGMOD, "fgmod")
    ready = os.path.isfile(fgmod) and os.access(fgmod, os.X_OK)
    return {
        "installed": d is not None,
        "dir": d,
        "version": _version_of(d) if d else None,
        "fgmod_ready": ready,                          # "Setup OptiScaler Mod" done in Decky Framegen
        "fgmod": fgmod if ready else None,
        "optiscaler": optiscaler_version(home) if ready else None,
    }


def uses_fgmod(launch_options: str | None) -> bool:
    return bool(launch_options) and "fgmod/fgmod" in launch_options
