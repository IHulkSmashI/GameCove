"""lsfg-vk itself (the Vulkan layer that runs Lossless Scaling's frame generation on Linux), installed into the
user's home when the system has none.

Not part of GameCove's package: lsfg-vk 2 is published under CC BY-NC-ND 4.0 (lsfg-vk.dev, 2026-08-27) and its author
asks to be contacted before it is integrated elsewhere. So GameCove fetches the author's own unmodified release
(builds.lsfg-vk.dev, pinned by sha256 in versions.json "lsfg_vk") when the user presses "Set up Lossless frame
generation", unpacks it under ~/.local exactly as its own layout (lib/, share/vulkan/implicit_layer.d/, bin/), and
records every file so remove() takes exactly those out. The Lossless Scaling app and its DLL are the user's own, from
Steam; nothing of it is ever downloaded here.
"""
from __future__ import annotations

import json
import os
import re
import shutil
import tarfile
import tempfile

from . import downloads, userexec

ROOT = ".local"
RECORD = os.path.join(".local", "share", "gamecove", "lsfg-vk.json")
LAYER = os.path.join("share", "vulkan", "implicit_layer.d", "VkLayer_LSFGVK_frame_generation.json")
WANTED = ("lib/", "share/vulkan/implicit_layer.d/", "bin/lsfg-vk-cli")
MAX_FILES = 64
MAX_SIZE = 64 << 20


def state(home: str) -> dict:
    try:
        with open(os.path.join(home, RECORD), encoding="utf-8") as f:
            rec = json.load(f)
    except (OSError, ValueError):
        rec = {}
    there = os.path.isfile(os.path.join(home, ROOT, LAYER))
    return {"installed": bool(rec) and there, "version": rec.get("version") if there else None, "files": rec.get("files") or []}


def _members(tar: tarfile.TarFile) -> list[tarfile.TarInfo]:
    out = []
    for m in tar.getmembers():
        name = m.name.lstrip("./")
        if not m.isfile() or m.size > MAX_SIZE or ".." in name.split("/") or name.startswith("/"):
            continue
        if any(name == w or (w.endswith("/") and name.startswith(w)) for w in WANTED):
            out.append(m)
    if not out or len(out) > MAX_FILES:
        raise ValueError("this isn't an lsfg-vk release as we know it")
    return out


STEAM_ROOTS = (".local/share/Steam", ".steam/steam", ".steam/root")
APP_ID = "993090"
DLLS = ("lsfg-vk.dll", "Lossless.dll")


def owned_install(home: str) -> str | None:
    """The user's own Lossless Scaling from Steam: a library with Steam's install record for app 993090 and the DLL
    in its folder. Its path, or None. This is the only thing that unlocks lsfg-vk here."""
    libs: list[str] = []
    for r in STEAM_ROOTS:
        root = os.path.join(home, r)
        if not os.path.isdir(os.path.join(root, "steamapps")):
            continue
        libs.append(root)
        try:
            with open(os.path.join(root, "steamapps", "libraryfolders.vdf"), encoding="utf-8", errors="replace") as f:
                libs += re.findall(r'"path"\s+"([^"]+)"', f.read())
        except OSError:
            pass
    for lib in dict.fromkeys(os.path.realpath(x) for x in libs):
        if os.path.isfile(os.path.join(lib, "steamapps", f"appmanifest_{APP_ID}.acf")):
            d = os.path.join(lib, "steamapps", "common", "Lossless Scaling")
            for n in DLLS:
                if os.path.isfile(os.path.join(d, n)):
                    return os.path.join(d, n)
    return None


def install(home: str, entry: dict | None) -> dict:
    """The pinned release into ~/.local, only next to the user's own Lossless Scaling from Steam. Files already
    there that aren't ours are never replaced."""
    if not owned_install(home):
        return {"ok": False, "error": "This needs Lossless Scaling, a paid app on Steam, installed from your own Steam "
                "library (beta branch lsfg-vk). Nothing was installed."}
    if not entry or not entry.get("sha256") or not entry.get("url"):
        return {"ok": False, "error": "no pinned lsfg-vk release to install"}
    cur = state(home)
    if cur["installed"] and cur["version"] == entry.get("version"):
        return {"ok": True, "how": "there", "version": cur["version"]}
    work = tempfile.mkdtemp(prefix="gamecove-lsfg-")
    try:
        arc = os.path.join(work, "lsfg-vk.tar.xz")
        try:
            downloads.get_verified(downloads.sources(entry), entry["sha256"], arc)
        except (OSError, ValueError) as e:
            return {"ok": False, "error": f"lsfg-vk couldn't be downloaded ({e}). Nothing was changed; try again when you're online."}
        ours = set(cur["files"])
        placed = []
        try:
            with tarfile.open(arc, "r:xz") as tar:
                for m in _members(tar):
                    rel = m.name.lstrip("./")
                    dest = os.path.join(home, ROOT, rel)
                    if os.path.lexists(dest) and rel not in ours:
                        return {"ok": False, "error": f"~/.local/{rel} is already there and isn't ours: another lsfg-vk "
                                "is installed. Remove that one first, or keep using it."}
                    src = tar.extractfile(m)
                    if src is None:
                        continue
                    os.makedirs(os.path.dirname(dest), exist_ok=True)
                    with open(dest + ".gamecove-tmp", "wb") as f:
                        shutil.copyfileobj(src, f)
                    os.chmod(dest + ".gamecove-tmp", 0o755 if rel.startswith(("bin/", "lib/")) else 0o644)
                    os.replace(dest + ".gamecove-tmp", dest)
                    placed.append(rel)
        except (tarfile.TarError, ValueError, OSError) as e:
            for rel in placed:
                _rm(os.path.join(home, ROOT, rel))
            return {"ok": False, "error": f"lsfg-vk's release couldn't be unpacked: {e}"}
        for rel in ours - set(placed):                  # files of the version before that this one no longer has
            _rm(os.path.join(home, ROOT, rel))
        rec = os.path.join(home, RECORD)
        os.makedirs(os.path.dirname(rec), exist_ok=True)
        with open(rec + ".tmp", "w", encoding="utf-8") as f:
            json.dump({"version": entry.get("version"), "sha256": entry["sha256"], "files": sorted(placed)}, f, indent=1)
        os.replace(rec + ".tmp", rec)
        try:
            userexec.chown_tree(os.path.join(home, ROOT, "share", "vulkan"), home)
        except OSError:
            pass
        return {"ok": True, "how": "installed", "version": entry.get("version"), "files": sorted(placed)}
    finally:
        shutil.rmtree(work, ignore_errors=True)


def _rm(path: str) -> None:
    try:
        os.remove(path)
    except OSError:
        pass


def remove(home: str) -> dict:
    """Exactly the files install() put there; the user's own config (~/.config/lsfg-vk) stays."""
    cur = state(home)
    for rel in cur["files"]:
        _rm(os.path.join(home, ROOT, rel))
    _rm(os.path.join(home, RECORD))
    return {"ok": True, "removed": len(cur["files"])}
