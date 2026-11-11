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

from .optiscaler import EXE_DEPTH

# every folder OptiScaler can be put into (optiscaler.main_exe_dir looks EXE_DEPTH levels down) is scanned, and one
# level inside each, so a folder of anti-cheat files next to the exe is seen too (review H4: the scan stopped one
# level short of where OptiScaler goes)
DEPTH = EXE_DEPTH + 1
# folders that hold many games (a library): the scan upwards from a game's folder stops below them
LIBRARY_DIRS = {"common", "steamapps", "games", "heroic", "gog games", "epic games", "lutris", "legendary", "itch",
                "roms", "faugus", "bottles", "drive_c", "program files", "program files (x86)"}
MAX_UP = 3
# folder and file names (lower case, fnmatch) the anti-cheat systems install next to a game. Sources, checked
# 2026-11-11: EA's own help pages and EA forum threads for Javelin (EAAntiCheat.GameServiceLauncher.exe/.dll,
# EAAntiCheat.Installer.exe in the game's folder); Steam discussions for NetEase's NEAC (NeacClient.exe in the
# NARAKA: BLADEPOINT folder, the NeacSafe/NeacSafe64 kernel driver); the vendors' and PCGamingWiki's file lists
# for the rest. Most kernel parts (Vanguard's vgk.sys, FACEIT, Javelin's service) live outside the game's folder:
# for those the app's own anti-cheat data (Are We Anti-Cheat Yet) is what refuses the game.
ANTICHEAT = {
    "Easy Anti-Cheat": ("easyanticheat", "easyanticheat_eos", "easyanticheat_x64.dll", "easyanticheat_eos_setup.exe",
                        "start_protected_game.exe", "eac_launcher.exe", "*.eac"),
    "BattlEye": ("battleye", "beservice.exe", "beservice_x64.exe", "beclient_x64.dll", "*_be.exe"),
    "EA Javelin": ("eaanticheat", "eaanticheat.*", "eaanticheat.gameservicelauncher.exe",
                   "eaanticheat.gameservicelauncher.dll", "eaanticheat.installer.exe"),
    "NetEase Anti-Cheat": ("neacclient.exe", "neac*.exe", "neacsafe*.sys", "neacsafe*.dll", "neac_*.dll"),
    "nProtect GameGuard": ("gameguard", "gameguard.des", "npggnt.des", "gamemon.des", "gamemon64.des"),
    "XIGNCODE3": ("xigncode", "x3.xem", "xcorona_x64.xem", "xhunter1.sys", "xhunter64.sys"),
    "Vanguard": ("vgc.exe", "vgk.sys", "riot vanguard"),
    "Anti-Cheat Expert": ("anticheatexpert", "ace-base.sys", "ace-base64.dll", "ace-*.sys", "sguard64.exe",
                          "sguardsvc64.exe"),
    "Tencent TP": ("tenprotect", "tp3helper.dat", "tessafe.sys"),
    "Nexon Game Security": ("blackcipher", "blackcipher64.aes", "blackcall.aes", "blackcall64.aes"),
    "AhnLab HackShield": ("hshield", "ehsvc.dll"),
    # Byfron's Hyperion lives inside Roblox's own client files (no separate file of its own)
    "Hyperion": ("robloxplayerbeta.exe", "robloxplayerbeta.dll", "robloxplayerlauncher.exe"),
    "PunkBuster": ("pb", "pbsvc.exe", "punkbuster"),
    "EQU8": ("equ8", "equ8_conf.json", "equ8*.sys"),
    "miHoYo Protect": ("mhyprot2.sys", "mhyprot3.sys", "hoyokprotect.sys", "mhypbase.dll"),
    "FACEIT": ("faceit", "faceitclient.exe", "faceit.sys"),
    "Denuvo Anti-Cheat": ("denuvo-anti-cheat-update-service.exe", "denuvo anti-cheat", "denuvo-anti-cheat.sys"),
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


def _parents(game_dir: str):
    """The folders above game_dir that still belong to the same game: up to the game's own folder in a library
    (steamapps/common/<game>, Heroic's or Lutris' <game>), never the library itself, the home folder or /."""
    d = os.path.realpath(game_dir)
    stop = {os.path.realpath(os.path.expanduser("~")), os.sep}
    for _ in range(MAX_UP):
        up = os.path.dirname(d)
        if up == d or up in stop or os.path.basename(d).lower() in LIBRARY_DIRS or \
                os.path.basename(up).lower() in LIBRARY_DIRS or os.path.isdir(os.path.join(up, "steamapps")):
            return
        yield up
        d = up


def _match(names: set[str], seen: set[str]) -> None:
    for system, pats in ANTICHEAT.items():
        strong = [p for p in pats if p not in _WEAK]
        if any(fnmatch.filter(names, p) for p in strong):
            seen.add(system)


def anticheat(game_dir: str | None) -> list[str]:
    """Names of the anti-cheat systems whose files are in the game's folder ([] = none found): everything below it
    as deep as OptiScaler can go (DEPTH), and what sits directly in the folders above it up to the game's own
    folder in its library (an app that passes a game's Binaries folder still sees EasyAntiCheat/ at the top)."""
    if not game_dir or not os.path.isdir(game_dir):
        return []
    seen: set[str] = set()
    for _r, dirs, files in _walk(game_dir, DEPTH):
        _match({x.lower() for x in dirs} | {x.lower() for x in files}, seen)
    for up in _parents(game_dir):
        try:
            _match({x.lower() for x in os.listdir(up)}, seen)
        except OSError:
            break
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
