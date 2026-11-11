"""What makes GameCove keep its hands off a game: anti-cheat, another tool's files, a list entry that says it
doesn't work. Read-only; nothing here writes.

Anti-cheat: OptiScaler's README ("Do not use this mod with online games. It may trigger anti-cheat software and cause
bans") and its compatibility list ("the only games not working are Anti-Cheat enabled"). Two sources, either is enough:
the app's own data for the game (Are We Anti-Cheat Yet, passed as --anticheat) and what is in the game's folder.
There is no switch to override it.
"""
from __future__ import annotations

import fnmatch
import os

DEPTH = 4
# folder and file names (lower case, fnmatch) the anti-cheat systems install next to a game
ANTICHEAT = {
    "Easy Anti-Cheat": ("easyanticheat", "easyanticheat_eos", "easyanticheat_x64.dll", "easyanticheat_eos_setup.exe",
                        "start_protected_game.exe", "eac_launcher.exe", "*.eac"),
    "BattlEye": ("battleye", "beservice.exe", "beservice_x64.exe", "beclient_x64.dll", "*_be.exe"),
    "nProtect GameGuard": ("gameguard", "gameguard.des", "npggnt.des"),
    "XIGNCODE3": ("xigncode", "x3.xem", "xcorona_x64.xem"),
    "Vanguard": ("vgc.exe", "vgk.sys", "riot vanguard"),
    "Anti-Cheat Expert": ("anticheatexpert", "ace-base.sys", "ace-base64.dll", "sguard64.exe"),
    "PunkBuster": ("pb", "pbsvc.exe", "punkbuster"),
    "EQU8": ("equ8", "equ8_conf.json"),
    "miHoYo Protect": ("mhyprot2.sys", "mhyprot3.sys", "hoyokprotect.sys", "mhypbase.dll"),
    "FACEIT": ("faceit", "faceitclient.exe"),
    "Denuvo Anti-Cheat": ("denuvo-anti-cheat-update-service.exe", "denuvo anti-cheat"),
    "Ricochet": ("randgrid.sys",),
}
# "pb" as a folder name is too common: only counted together with a PunkBuster file
_WEAK = {"pb"}
# other tools that hook the same DLLs: stacking them with OptiScaler breaks games (OptiScaler wiki, compatibility with
# other mods). GameCove stands aside and says which one it found.
MODS = {
    "ReShade": ("reshade.ini", "reshade.log", "reshadepreset.ini", "reshade64.dll", "reshade-shaders"),
    "Special K": ("specialk64.dll", "specialk.ini", "sk_res", "dxgi.ini"),
    "RenoDX": ("renodx*.addon64",),
    "DLSS Enabler": ("dlss-enabler.dll", "dlss-enabler-upscaler.dll", "_nvngx.dll", "nvngx-wrapper.dll"),
    "Luma": ("luma*.addon",),
}


def _walk(game_dir: str, depth: int):
    base = game_dir.rstrip(os.sep).count(os.sep)
    for r, d, f in os.walk(game_dir):
        if r.count(os.sep) - base >= depth:
            d[:] = []
        yield r, d, f


def anticheat(game_dir: str | None) -> list[str]:
    """Names of the anti-cheat systems whose files are in the game's folder ([] = none found)."""
    if not game_dir or not os.path.isdir(game_dir):
        return []
    seen: set[str] = set()
    for _r, dirs, files in _walk(game_dir, DEPTH):
        names = {x.lower() for x in dirs} | {x.lower() for x in files}
        for system, pats in ANTICHEAT.items():
            strong = [p for p in pats if p not in _WEAK]
            if any(fnmatch.filter(names, p) for p in strong):
                seen.add(system)
    return sorted(seen)


def mods(folder: str | None) -> list[str]:
    """Other injectors in the folder of the game's exe."""
    if not folder or not os.path.isdir(folder):
        return []
    names = {x.lower() for x in os.listdir(folder)}
    return sorted(m for m, pats in MODS.items() if any(fnmatch.filter(names, p) for p in pats))


def refusal(game_dir: str | None, folder: str | None, flagged: bool = False, entry: dict | None = None) -> dict | None:
    """Why nothing may be put into this game, or None. flagged: the app's anti-cheat data says the game has one;
    entry: the knowledge base's row for the game."""
    found = anticheat(game_dir)
    if flagged or found or (entry or {}).get("anticheat"):
        what = ", ".join(found) if found else "anti-cheat"
        return {"code": "anticheat", "error": f"This game uses {what}. We never put an upscaler into a game with "
                "anti-cheat: it can get an account banned. The game's own settings still work."}
    other = mods(folder)
    if other:
        return {"code": "mod", "error": f"{other[0]} is already in this game's folder. We don't stack on top of it: "
                f"take {other[0]} out first, or keep using it."}
    if (entry or {}).get("status") == "broken":
        return {"code": "broken", "error": "OptiScaler's own list says this game doesn't work with it"
                + (f" ({entry.get('notes')})" if (entry or {}).get("notes") else "") + "."}
    return None
