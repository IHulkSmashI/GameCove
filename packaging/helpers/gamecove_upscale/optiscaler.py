"""GameCove's own OptiScaler: download once, put into a game with its settings, take out again exactly.

What Decky Framegen does on SteamOS, done by GameCove so one tap covers everything the
recommended setup needs (FSR 4 on XMX, REFramework, the game's fixes from assets/games.json) and the OptiScaler
version is GameCove's to choose:

  install()  OptiScaler's release .7z (the newest from the signed index, else the pin in data/versions.json; from
             GameCove's mirror, then upstream; sha256 checked) unpacked into ~/.local/share/gamecove/optiscaler/<version>.
             Optional extras with their own sha256 (OptiPatcher, fakenvapi); a newer extra for the same OptiScaler
             replaces just that file. .gamecove-package.json in the package says what it is.
  patch()    into the folder of the game's main exe: OptiScaler.dll under a proxy name (dxgi.dll, or the next free
             one: winmm, version, dbghelp, winhttp; the usual order), OptiScaler.ini with the game's settings, the
             libraries it ships, OptiPatcher in plugins/, and for "FSR 4 on XMX" nitec's files from ~/fsr4-xmx with
             GameCove's own cabinet.dll (tools/cabinet-lzms, in the plugin's bin/: no Windows file needed). Any
             file it replaces is moved to .gamecove-optiscaler/backup first; everything is listed in
             .gamecove-optiscaler/manifest.json. Proton loads the proxy through WINEDLLOVERRIDES=<name>=n,b (the
             launch wrapper sets it from the game's launch file).
  unpatch()  removes what the manifest lists and puts the backups back, but only files whose sha256 still matches
             what GameCove put there (manifest "sha256"); a file someone changed since (a game update, the user's
             own OptiScaler.ini edits) is kept and reported, and a backup is never put over a newer game file.

Two package layouts (versions.json "layout"):
  flat       OptiScaler 0.9.4 (every game but Capcom's): its libraries, D3D12_Optiscaler/ and plugins/ next to the exe.
  subfolder  OptiScaler v10 (Capcom RE Engine games): only the proxy DLL
             and OptiScaler.ini next to the exe; the libraries, D3D12_OptiScaler/ and plugins/ in OptiScaler/
             (OptiDllPath=.\\OptiScaler). nitec's FSR 4.1.2 files go into OptiScaler/ too; GameCove's cabinet.dll
             (LZMS) and Wine's as cabinet_wine.dll stay next to the exe, where Wine loads them. The folders GameCove creates are listed in
             the manifest ("dirs"), so unpatch() takes them away with what OptiScaler wrote into them.

OptiScaler from another tool (Decky Framegen's fgmod, files from a Windows install, by hand) is never
touched: owner() says whose it is and the panel shows a warning instead.
"""
from __future__ import annotations

import glob
import json
import logging
import os
import re
import shutil
import subprocess
import time
import urllib.error

from . import downloads, userexec
from .mirror import VERSION_RE


def mirror_version_ok(v: str) -> bool:
    """A version names a folder (package_dir): plain characters only, never a path."""
    return isinstance(v, str) and bool(VERSION_RE.match(v)) and ".." not in v

log = logging.getLogger("gamecove.optiscaler")

ROOT = ".local/share/gamecove/optiscaler"
STATE = ".gamecove-optiscaler"
# logs and caches OptiScaler, fakenvapi and OptiPatcher create in the game folder at run time (not in the manifest)
RUNTIME_FILES = ("OptiScaler.log", "OptiScaler.log.*", "OptiScaler*.log", "fakenvapi.log", "OptiPatcher.log",
                 "dlssg_to_fsr3.log", "nvngx.log")
PROXIES = ("dxgi.dll", "winmm.dll", "version.dll", "dbghelp.dll", "winhttp.dll", "wininet.dll")
FSR4_XMX_DIR = "fsr4-xmx"
FSR4_XMX_FILES = ("amd_fidelityfx_upscaler_dx12.dll", "fsr-original.dll")   # what the user puts in ~/fsr4-xmx
# GameCove's own cabinet.dll (tools/cabinet-lzms, ported from ClawDeck, same author; built by the release workflow
# and shipped as <package>/bin/cabinet.dll): the Compression API LZMS decompressor nitec's build imports (Cabinet.dll
# ordinals 40, 43, 45), which Wine's cabinet.dll lacks; its FDI/FCI exports forward to cabinet_wine.dll. The first
# copy found is used: GAMECOVE_CABINET, the package this helper is part of (ClawDeck's OWN_CABINET rule: bin/ two
# folders above the module, /usr/lib/gamecove/bin in every GameCove package), a source checkout's build output,
# GameCove's data folder, then an installed ClawDeck (the same bytes).
_HERE = os.path.dirname(os.path.realpath(__file__))
SYSTEM_CABINET = "/usr/lib/gamecove/bin/cabinet.dll"
PACKAGE_CABINET = os.path.join(os.path.dirname(os.path.dirname(_HERE)), "bin", "cabinet.dll")
CHECKOUT_CABINET = os.path.join(os.path.dirname(os.path.dirname(os.path.dirname(_HERE))), "tools", "cabinet-lzms", "out", "cabinet.dll")
CABINET_PLACES = (".local/share/gamecove/cabinet.dll", "homebrew/plugins/ClawDeck/bin/cabinet.dll")


def own_cabinet(home: str) -> str:
    """Where the LZMS cabinet.dll is, or the first place it would go ("" never: callers check isfile)."""
    env = os.environ.get("GAMECOVE_CABINET", "")
    places = ([env] if env else []) + [PACKAGE_CABINET, SYSTEM_CABINET, CHECKOUT_CABINET] + \
        [os.path.join(home, p) for p in CABINET_PLACES]
    return next((p for p in places if os.path.isfile(p)), places[0])


PACKAGE_RECORD = ".gamecove-package.json"
SKIP = {"setup_linux.sh", "setup_windows.bat", "OptiScaler.dll", "OptiScaler.ini", PACKAGE_RECORD}
SKIP_PREFIX = ("!!", "Licenses/")
SKIP_SUFFIX = (".bat",)                  # v10: OptiScaler/Streamlined_fetcher_windows.bat (a Windows download helper)
# always: OptiPatcher (plugins/) loads, and the HQ font stays off (its auto mode asserts on a missing font under
# Proton; Decky Framegen sets the same two)
BASE_INI = {"Plugins_LoadAsiPlugins": "true", "Menu_UseHQFont": "false"}
MAIN_EXE_SKIP = re.compile(r"(unins|crash|setup|redist|launcher|vc_?redist|dxsetup|easyanticheat|eac|ue4prereq|cefprocess|helper|report)", re.I)


# ---- the package ------------------------------------------------------------------------------------------------
def package_dir(home: str, version: str) -> str:
    return os.path.join(home, ROOT, version)


def installed(home: str, version: str) -> bool:
    d = package_dir(home, version)
    return os.path.isfile(os.path.join(d, "OptiScaler.dll")) and os.path.isfile(os.path.join(d, "OptiScaler.ini"))


def _get(item: dict, dest: str) -> str:
    """One versions entry or extra ({url, mirror, sha256}) to dest: the mirror first, then upstream, sha256 checked."""
    return downloads.get_verified(downloads.sources(item), item.get("sha256", ""), dest)


def package_record(home: str, version: str) -> dict:
    try:
        with open(os.path.join(package_dir(home, version), PACKAGE_RECORD), "r", encoding="utf-8") as f:
            r = json.load(f)
        return r if isinstance(r, dict) else {}
    except (OSError, ValueError):
        return {}


def packages(home: str) -> list[dict]:
    """Every OptiScaler package downloaded, newest install first: [{version, layout, sha256, installed, dir}]."""
    root = os.path.join(home, ROOT)
    out = []
    try:
        names = os.listdir(root)
    except OSError:
        return []
    for v in names:
        if v.startswith(".") or v.endswith(".new") or not installed(home, v):
            continue
        r = package_record(home, v)
        d = package_dir(home, v)
        out.append({"version": v, "layout": r.get("layout") or ("subfolder" if os.path.isdir(os.path.join(d, "OptiScaler")) else "flat"),
                    "sha256": r.get("sha256"), "installed": float(r.get("installed") or os.path.getmtime(d)), "dir": d})
    return sorted(out, key=lambda p: p["installed"], reverse=True)


def _unpack(arc: str, dest: str) -> str | None:
    """OptiScaler ships as .7z (with BCJ2): 7-Zip if the system has it (7z, 7za, 7zz), else libarchive's bsdtar.
    Returns an error text, or None when unpacked."""
    os.makedirs(dest, exist_ok=True)
    tried = []
    for cmd in (["7z", "x", "-y", "-o" + dest, arc], ["7za", "x", "-y", "-o" + dest, arc], ["7zz", "x", "-y", "-o" + dest, arc],
                ["bsdtar", "-xf", arc, "-C", dest]):
        if not shutil.which(cmd[0]):
            continue
        try:
            r = subprocess.run(cmd, capture_output=True, text=True, timeout=300, check=False, env={**os.environ, "LD_LIBRARY_PATH": ""})
        except (OSError, subprocess.SubprocessError) as e:
            tried.append(f"{cmd[0]}: {e}")
            continue
        if r.returncode == 0:
            return None
        tried.append(f"{cmd[0]}: {(r.stderr or r.stdout).strip()[-200:]}")
    return "; ".join(tried) or "no unpacker for .7z on this system (7z or bsdtar)"


# fakenvapi.ini with tested values (its Windows Onimusha install, OptiScaler\fakenvapi.ini, 2026-11-04): the
# game's own Reflex setting decides (force_reflex=0), no LatencyFlex
FAKENVAPI_INI = ("[fakenvapi]\nenable_logs=1\nenable_trace_logs=0\nforce_latencyflex=0\nforce_reflex=0\n")
EXTRA_INIS = {"fakenvapi": FAKENVAPI_INI}


def extra_dests(x: dict) -> list[str]:
    """Where an extra lands in the package: one file (dest), or files taken out of its archive (files) plus the
    ini GameCove writes for it (ini)."""
    if "dest" in x:
        return [x["dest"]]
    return list((x.get("files") or {}).values()) + ([x["ini"]] if x.get("ini") else [])


def extra_hashes(x: dict) -> dict[str, str]:
    """{path in the package: the sha256 it must have} for one extra (its ini is GameCove's own text: not listed)."""
    if "dest" in x:
        return {x["dest"]: x.get("sha256", "").lower()}
    return {to: ((x.get("file_sha256") or {}).get(src) or "").lower() for src, to in (x.get("files") or {}).items()}


def extras_ready(home: str, entry: dict) -> bool:
    """Every extra in place (any build: a game is patched with what's there, also offline)."""
    d = package_dir(home, entry["version"])
    return all(os.path.isfile(os.path.join(d, p)) for x in entry.get("extras", []) for p in extra_dests(x))


def extras_current(home: str, entry: dict) -> bool:
    """Every extra in place with the bytes this entry names (a newer OptiPatcher in the index: not current)."""
    d = package_dir(home, entry["version"])
    for x in entry.get("extras", []):
        if not all(os.path.isfile(os.path.join(d, p)) for p in extra_dests(x)):
            return False
        for p, sha in extra_hashes(x).items():
            if sha and downloads.sha256_of(os.path.join(d, p)) != sha:
                return False
    return True


def _extra_ready(pkg: str, x: dict) -> bool:
    return all(os.path.isfile(os.path.join(pkg, p)) for p in extra_dests(x)) and \
        all(not sha or downloads.sha256_of(os.path.join(pkg, p)) == sha for p, sha in extra_hashes(x).items())


def _extra(x: dict, pkg: str, work: str) -> None:
    """One extra into the unpacked package: a single file (OptiPatcher), or chosen files out of a release archive
    (fakenvapi's .7z), each with its own pinned sha256."""
    if "dest" in x:
        dest = os.path.join(pkg, x["dest"])
        os.makedirs(os.path.dirname(dest), exist_ok=True)
        _get(x, dest)
        return
    arc = _get(x, os.path.join(work, os.path.basename(x["url"])))
    out = os.path.join(work, "extra-" + x["name"])
    shutil.rmtree(out, ignore_errors=True)
    err = _unpack(arc, out)
    if err:
        raise ValueError(f"unpacking {x['name']}: {err}")
    for src, to in (x.get("files") or {}).items():
        p = os.path.join(out, src)
        want = (x.get("file_sha256") or {}).get(src)
        if not os.path.isfile(p) or (want and downloads.sha256_of(p) != want.lower()):
            raise ValueError(f"{src} from {os.path.basename(x['url'])} is missing or doesn't match its pinned sha256")
        dest = os.path.join(pkg, to)
        os.makedirs(os.path.dirname(dest), exist_ok=True)
        shutil.copyfile(p, dest + ".new")
        os.replace(dest + ".new", dest)
    if x.get("ini"):
        dest = os.path.join(pkg, x["ini"])
        os.makedirs(os.path.dirname(dest), exist_ok=True)
        with open(dest, "w", encoding="utf-8") as f:
            f.write(EXTRA_INIS[x["name"]])


def install(home: str, entry: dict) -> dict:
    """entry (versions.json "optiscaler", or the same with the index's newest): {version, url, mirror, sha256,
    extras: [{name, url, mirror, sha256, dest} or {name, url, mirror, sha256, files: {in archive: in package},
    file_sha256, ini}]}. The package already there with older extras: only those are fetched again."""
    ver = entry["version"]
    if not mirror_version_ok(ver):
        return {"ok": False, "error": f"bad OptiScaler version {ver!r}"}
    d = package_dir(home, ver)
    if installed(home, ver) and extras_current(home, entry):
        return {"ok": True, "already": True, "version": ver, "dir": d}
    work = os.path.join(home, ROOT, ".download")
    if installed(home, ver):              # same OptiScaler, a newer OptiPatcher / fakenvapi
        try:
            os.makedirs(work, exist_ok=True)
            got = []
            for x in entry.get("extras", []):
                if not _extra_ready(d, x):
                    _extra(x, d, work)
                    got.append(x["name"])
            userexec.chown_tree(d, home)
        except (OSError, ValueError, subprocess.SubprocessError, urllib.error.URLError) as e:
            return {"ok": False, "error": f"OptiScaler {ver}: {e}"}
        finally:
            shutil.rmtree(work, ignore_errors=True)
        log.info("OptiScaler %s: updated %s", ver, ", ".join(got))
        return {"ok": True, "version": ver, "dir": d, "updated_extras": got}
    try:
        os.makedirs(work, exist_ok=True)
        arc = _get(entry, os.path.join(work, os.path.basename(entry["url"])))
        tmp = d + ".new"
        shutil.rmtree(tmp, ignore_errors=True)
        r = _unpack(arc, tmp)
        if r:
            return {"ok": False, "error": f"unpacking OptiScaler: {r}"}
        if not os.path.isfile(os.path.join(tmp, "OptiScaler.dll")):
            return {"ok": False, "error": "the OptiScaler archive has no OptiScaler.dll"}
        for x in entry.get("extras", []):
            _extra(x, tmp, work)
        with open(os.path.join(tmp, PACKAGE_RECORD), "w", encoding="utf-8") as f:
            json.dump({"version": ver, "sha256": entry.get("sha256"), "layout": entry.get("layout") or "flat",
                       "source": entry.get("source", "pins"), "installed": time.time()}, f)
        shutil.rmtree(d, ignore_errors=True)
        os.replace(tmp, d)
        userexec.chown_tree(os.path.join(home, ROOT), home)
    except (OSError, ValueError, subprocess.SubprocessError, urllib.error.URLError) as e:
        return {"ok": False, "error": f"OptiScaler {ver}: {e}"}
    finally:
        shutil.rmtree(work, ignore_errors=True)
    log.info("OptiScaler %s into %s", ver, d)
    return {"ok": True, "version": ver, "dir": d}


# ---- the game ---------------------------------------------------------------------------------------------------
def main_exe_dir(game_dir: str, known_exes: list[str] | None = None) -> str | None:
    """Where OptiScaler goes: the folder of the game's real exe. Unreal: <Project>/Binaries/Win64 (the -Shipping exe);
    a known exe name from the game list; else the largest exe that isn't a launcher, installer or crash reporter."""
    best, size = None, -1
    want = {e.lower() for e in known_exes or []}
    base = game_dir.rstrip(os.sep).count(os.sep)
    named: list[str] = []
    shipping: list[tuple[bool, int, str]] = []
    for r, d, f in os.walk(game_dir):
        d.sort()                                         # the same folder every time, whatever the file system's order
        if r.count(os.sep) - base >= 5:
            d[:] = []
        for x in sorted(f):
            lo = x.lower()
            if not lo.endswith(".exe"):
                continue
            if lo.endswith(("-win64-shipping.exe", "-wingdk-shipping.exe")):
                try:
                    shipping.append((os.sep + "binaries" + os.sep in (r + os.sep).lower(), os.path.getsize(os.path.join(r, x)), r))
                except OSError:
                    pass
                continue
            if lo in want:
                named.append(r)
                continue
            if MAIN_EXE_SKIP.search(lo):
                continue
            try:
                s = os.path.getsize(os.path.join(r, x))
            except OSError:
                continue
            if s > size:
                best, size = r, s
    if shipping:
        # Unreal: the -Shipping exe in <Project>/Binaries/Win64, and of several the largest. Gothic 1 Remake ships a
        # 310 KB launcher stub of the same name in its top folder, which the walk reaches first (#162)
        return max(shipping)[2]
    if named:
        # the same exe name in a DirectX 11 and a DirectX 12 folder (The Witcher 3: bin/x64 and bin/x64_dx12, issue
        # #141): DLSS, FSR and XeSS live in the DX12 one, so OptiScaler goes there
        dx12 = [r for r in named if re.search(r"dx12|d3d12", os.path.basename(r), re.I)]
        return (dx12 or named)[0]
    return best


def _manifest(folder: str) -> dict | None:
    try:
        with open(os.path.join(folder, STATE, "manifest.json"), "r", encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


def owner(folder: str | None) -> dict:
    """Whose OptiScaler is in this folder: "gamecove", "decky-framegen", "other" (by hand, files from a
    Windows install, another tool) or None."""
    if not folder or not os.path.isdir(folder):
        return {"owner": None}
    m = _manifest(folder)
    if m:
        return {"owner": "gamecove", "version": m.get("version"), "dll": m.get("dll"), "preset": m.get("preset")}
    if os.path.isfile(os.path.join(folder, ".clawdeck-optiscaler", "manifest.json")):
        return {"owner": "clawdeck"}           # ClawDeck's own install (same author, its own manifest): left to ClawDeck
    names = {x.lower() for x in os.listdir(folder)}
    if "framegen_patch" in names or any(n.endswith(".b") for n in names if n.startswith(PROXIES)):
        return {"owner": "decky-framegen"}
    if "optiscaler.ini" in names or "optiscaler.log" in names or "optiscaler.dll" in names:
        return {"owner": "other"}
    return {"owner": None}


def set_ini(text: str, values: dict[str, str]) -> str:
    """OptiScaler.ini with [Section] Key=value set for each "Section_Key" (sections are matched without - and .,
    as Decky Framegen does: V-Sync = VSync). A key missing from its section is added at the section's end; a missing
    section at the end of the file."""
    lines = text.splitlines()
    for sk, v in values.items():
        sec, key = sk.split("_", 1)
        cur, start, end, done = None, None, None, False
        for i, line in enumerate(lines):
            s = line.strip()
            if s.startswith("[") and s.endswith("]"):
                if cur == sec:
                    end = i
                    break
                cur = s[1:-1].replace("-", "").replace(".", "")
                if cur == sec:
                    start = i
                continue
            if cur == sec and re.match(rf"^\s*{re.escape(key)}\s*=", line):
                lines[i] = f"{key}={v}"
                done = True
                break
        if done:
            continue
        if start is None:
            lines += ["", f"[{sec}]", f"{key}={v}"]
        else:
            lines.insert(end if end is not None else len(lines), f"{key}={v}")
    return "\n".join(lines) + "\n"


def _mkdirs(folder: str, rel_dir: str, dirs: list | None) -> None:
    """makedirs for folder/rel_dir, recording each folder that didn't exist yet (so unpatch takes it away again)."""
    if not rel_dir or rel_dir == ".":
        return
    parts = rel_dir.replace(os.sep, "/").split("/")
    for i in range(1, len(parts) + 1):
        rel = "/".join(parts[:i])
        p = os.path.join(folder, rel)
        if not os.path.isdir(p):
            os.makedirs(p, exist_ok=True)
            if dirs is not None and rel not in dirs:
                dirs.append(rel)


def _put(src: str, dest: str, folder: str, added: list, backed: list, dirs: list | None = None,
         hashes: dict | None = None) -> None:
    rel = os.path.relpath(dest, folder).replace(os.sep, "/")
    _mkdirs(folder, os.path.dirname(rel), dirs)
    bak = os.path.join(folder, STATE, "backup", rel)
    ours = rel in added
    if ours and hashes is not None and rel in hashes and os.path.isfile(dest) and \
            downloads.sha256_of(dest) != hashes[rel]:
        ours = False      # ours once, replaced since (a game update): the game's file now, backed up afresh
    if os.path.lexists(dest) and not ours:
        os.makedirs(os.path.dirname(bak), exist_ok=True)
        if not os.path.exists(bak) or rel in added:
            os.replace(dest, bak)
            if rel not in backed:
                backed.append(rel)
    os.makedirs(os.path.dirname(dest), exist_ok=True)
    shutil.copyfile(src, dest)
    if rel not in added:
        added.append(rel)
    if hashes is not None:
        hashes[rel] = downloads.sha256_of(dest)


def fsr4_xmx_missing(home: str) -> list[str]:
    """What FSR 4 on XMX still needs: nitec's two files in ~/fsr4-xmx, and GameCove's cabinet.dll from the package
    (missing only in a source checkout where tools/cabinet-lzms/build.sh hasn't run)."""
    xdir = os.path.join(home, FSR4_XMX_DIR)
    need = [f for f in FSR4_XMX_FILES if not os.path.isfile(os.path.join(xdir, f))]
    if not os.path.isfile(own_cabinet(home)):
        need.append("GameCove's LZMS cabinet.dll (/usr/lib/gamecove/bin/cabinet.dll; in a source checkout run tools/cabinet-lzms/build.sh)")
    return need


IMPORT_FROM = ("Downloads", "Desktop", "Documents")


def fsr4_xmx_import(home: str, depth: int = 3) -> dict:
    """nitec's two files from where a download lands, into ~/fsr4-xmx, so FSR 4.1.2 needs no folder made by hand
    (maintainer, 2026-11-05: "make it seamless"), for a build without the packaged set or a newer pair the user
    got from the OptiScaler Discord. Taken only as a pair, from one folder or one .zip, since a game's own
    amd_fidelityfx_upscaler_dx12.dll has the same name: both files next to each other are nitec's build."""
    xdir = os.path.join(home, FSR4_XMX_DIR)
    if all(os.path.isfile(os.path.join(xdir, f)) for f in FSR4_XMX_FILES):
        return {"ok": True, "imported": False, "dir": xdir}
    import zipfile
    want = {f.lower() for f in FSR4_XMX_FILES}
    for top in IMPORT_FROM:
        root = os.path.join(home, top)
        base = root.rstrip(os.sep).count(os.sep)
        for r, d, f in os.walk(root):
            if r.count(os.sep) - base >= depth:
                d[:] = []
            lo = {x.lower(): x for x in f}
            if want <= set(lo):
                os.makedirs(xdir, exist_ok=True)
                for name in FSR4_XMX_FILES:
                    shutil.copy2(os.path.join(r, lo[name.lower()]), os.path.join(xdir, name))
                userexec.chown_tree(xdir, home)
                log.info("FSR 4.1.2 XMX files taken from %s", r)
                return {"ok": True, "imported": True, "from": r, "dir": xdir}
            for z in (x for x in f if x.lower().endswith(".zip")):
                try:
                    with zipfile.ZipFile(os.path.join(r, z)) as zf:
                        members = {os.path.basename(m).lower(): m for m in zf.namelist() if not m.endswith("/")}
                        if not want <= set(members):
                            continue
                        os.makedirs(xdir, exist_ok=True)
                        for name in FSR4_XMX_FILES:
                            with zf.open(members[name.lower()]) as src, open(os.path.join(xdir, name), "wb") as dst:
                                shutil.copyfileobj(src, dst)
                except (OSError, zipfile.BadZipFile) as e:
                    log.info("FSR 4.1.2 XMX: %s: %s", z, e)
                    continue
                userexec.chown_tree(xdir, home)
                log.info("FSR 4.1.2 XMX files taken from %s", os.path.join(r, z))
                return {"ok": True, "imported": True, "from": os.path.join(r, z), "dir": xdir}
    return {"ok": True, "imported": False, "dir": xdir}


def fsr4_xmx_download(home: str, entry: dict) -> dict:
    """nitec's FSR 4.1.2 XMX files into ~/fsr4-xmx from where GameCove hosts them (versions.json "fsr4_xmx"), each
    sha256 checked; a file already there with the right sha256 isn't fetched again. Blocking (about 100 MB)."""
    xdir = os.path.join(home, FSR4_XMX_DIR)
    os.makedirs(xdir, exist_ok=True)
    got = []
    _fsr4_keep_previous(home, entry.get("files") or {})      # a different set there now: kept for rollback
    for name, sha in (entry.get("files") or {}).items():
        dest = os.path.join(xdir, name)
        if os.path.isfile(dest) and downloads.sha256_of(dest) == sha:
            continue
        # GameCove's mirror first, then where it came from: a files-only branch pinned by commit (base), not on the
        # Releases page (maintainer, 2026-11-05); a release tag still works for old entries
        url = (entry["base"].rstrip("/") + "/" + name if entry.get("base")
               else f"https://github.com/{entry['repo']}/releases/download/{entry['tag']}/{name}")
        err = _get_file(entry, name, url, dest)
        if err:
            return {"ok": False, "error": err}
        got.append(name)
    if got:
        _fsr4_record(home, entry.get("version"))
        userexec.chown_tree(xdir, home)
        log.info("FSR 4.1.2 XMX files downloaded: %s", ", ".join(got))
    return {"ok": True, "downloaded": got, "dir": xdir}


def _get_file(entry: dict, name: str, base_url: str, dest: str) -> str | None:
    """One FSR 4 file: the mirror, then the index's upstream URL or base_url; sha256 checked. An error text or None."""
    up = (entry.get("upstream") or {}).get(name) or base_url
    item = {"mirror": (entry.get("mirror") or {}).get(name), "url": up, "sha256": entry["files"][name]}
    try:
        downloads.get_verified(downloads.sources(item), item["sha256"], dest, timeout=120.0)
    except ValueError:
        return f"{name}: the download doesn't match its sha256 (not used)"
    except (OSError, PermissionError) as e:
        return f"{name}: {e}"
    return None


FSR4_BUNDLED = os.path.join("bin", "fsr4-xmx")      # inside the plugin: the build puts the files there


def fsr4_xmx_from_plugin(home: str, plugin_dir: str, entry: dict) -> dict:
    """The FSR 4.1.2 XMX files that came inside the package (plugin_dir/bin/fsr4-xmx; the build adds them, sha256 checked: nothing to download,
    maintainer 2026-11-06) copied to ~/fsr4-xmx, where the launch wrapper takes them from. Each one is checked again
    against versions.json; a file already in place with the right sha256 is left as it is."""
    src = os.path.join(plugin_dir, FSR4_BUNDLED)
    xdir = os.path.join(home, FSR4_XMX_DIR)
    got, missing = [], []
    for name, sha in (entry.get("files") or {}).items():
        dest, here = os.path.join(xdir, name), os.path.join(src, name)
        if os.path.isfile(dest) and downloads.sha256_of(dest) == sha:
            continue
        if not os.path.isfile(here) or downloads.sha256_of(here) != sha:
            missing.append(name)
            continue
        os.makedirs(xdir, exist_ok=True)
        shutil.copyfile(here, dest + ".new")
        os.replace(dest + ".new", dest)
        got.append(name)
    if got:
        userexec.chown_tree(xdir, home)
        log.info("FSR 4.1.2 XMX files from the plugin: %s", ", ".join(got))
    return {"ok": not missing, "copied": got, "missing": missing, "dir": xdir}


# ---- the FSR 4.1.2 XMX files as one set: shipped in the package, swapped as a unit, the one before kept -------------
PACKAGE_DIR = os.path.dirname(os.path.dirname(_HERE))          # /usr/lib/gamecove (ClawDeck's PLUGIN_DIR)
SYSTEM_DIR = "/usr/lib/gamecove"
FSR4_SET = ".gamecove-set.json"                                # in ~/fsr4-xmx: which set GameCove put there
FSR4_PREVIOUS = ".local/share/gamecove/fsr4-xmx-previous"      # the set before the last swap, for rollback


def fsr4_packaged() -> dict | None:
    """The set this GameCove package carries (bin/fsr4-xmx/set.json, written by tools/upscalers/fetch_fsr4.py):
    {"version", "files": {name: sha256}, "dir"}, or None in a build without it (a source checkout)."""
    for root in dict.fromkeys((PACKAGE_DIR, SYSTEM_DIR)):
        d = os.path.join(root, FSR4_BUNDLED)
        try:
            with open(os.path.join(d, "set.json"), "r", encoding="utf-8") as f:
                m = json.load(f)
        except (OSError, ValueError):
            continue
        if isinstance(m, dict) and isinstance(m.get("files"), dict) and set(m["files"]) == set(FSR4_XMX_FILES):
            return {"version": str(m.get("version", "")), "files": {k: str(v).lower() for k, v in m["files"].items()}, "dir": d}
    return None


def fsr4_xmx_set(home: str) -> dict:
    """What is in ~/fsr4-xmx now: {"present", "files": {name: sha256}, "version" (GameCove's record, None for files
    the user put there), "previous": the kept set's version or None}."""
    xdir = os.path.join(home, FSR4_XMX_DIR)
    present = all(os.path.isfile(os.path.join(xdir, f)) for f in FSR4_XMX_FILES)
    files = {f: downloads.sha256_of(os.path.join(xdir, f)) for f in FSR4_XMX_FILES} if present else {}
    rec = _read_json(os.path.join(xdir, FSR4_SET))
    version = rec.get("version") if present and rec.get("files") == files else None
    prev = _read_json(os.path.join(home, FSR4_PREVIOUS, FSR4_SET))
    return {"present": present, "files": files, "version": version, "previous": prev.get("version") if prev else None}


def _read_json(path: str) -> dict:
    try:
        with open(path, "r", encoding="utf-8") as f:
            d = json.load(f)
        return d if isinstance(d, dict) else {}
    except (OSError, ValueError):
        return {}


def _fsr4_record(home: str, version: str | None) -> None:
    xdir = os.path.join(home, FSR4_XMX_DIR)
    files = {f: downloads.sha256_of(os.path.join(xdir, f)) for f in FSR4_XMX_FILES}
    with open(os.path.join(xdir, FSR4_SET + ".new"), "w", encoding="utf-8") as f:
        json.dump({"component": "fsr4_xmx", "version": version, "files": files, "installed": time.time()}, f)
    os.replace(os.path.join(xdir, FSR4_SET + ".new"), os.path.join(xdir, FSR4_SET))


def _fsr4_keep_previous(home: str, incoming: dict) -> bool:
    """Before a different set goes into ~/fsr4-xmx: the complete set there now is copied to the rollback folder
    (one set kept: the one before the last swap). False when there was nothing to keep or it is the same set."""
    cur = fsr4_xmx_set(home)
    want = {k: str(v).lower() for k, v in (incoming or {}).items()}
    if not cur["present"] or cur["files"] == want:
        return False
    xdir, keep = os.path.join(home, FSR4_XMX_DIR), os.path.join(home, FSR4_PREVIOUS)
    tmp = keep + ".new"
    shutil.rmtree(tmp, ignore_errors=True)
    os.makedirs(tmp)
    for f in FSR4_XMX_FILES:
        shutil.copyfile(os.path.join(xdir, f), os.path.join(tmp, f))
    with open(os.path.join(tmp, FSR4_SET), "w", encoding="utf-8") as f:
        json.dump({"component": "fsr4_xmx", "version": cur["version"] or "your own files", "files": cur["files"],
                   "kept": time.time()}, f)
    shutil.rmtree(keep, ignore_errors=True)
    os.replace(tmp, keep)
    userexec.chown_tree(keep, home)
    return True


def fsr4_xmx_rollback(home: str) -> dict:
    """The set before the last swap back into ~/fsr4-xmx, and the one that was there kept in its place (so rolling
    back twice returns to where you were). Every file is checked against the kept set's own record first. Games
    keep the copy they have until GameCove's OptiScaler is put into them again."""
    keep, xdir = os.path.join(home, FSR4_PREVIOUS), os.path.join(home, FSR4_XMX_DIR)
    rec = _read_json(os.path.join(keep, FSR4_SET))
    files = rec.get("files") if isinstance(rec.get("files"), dict) else None
    if not files or set(files) != set(FSR4_XMX_FILES):
        return {"ok": False, "error": "no earlier FSR 4.1.2 XMX set is kept"}
    for f, sha in files.items():
        p = os.path.join(keep, f)
        if not os.path.isfile(p) or downloads.sha256_of(p) != sha:
            return {"ok": False, "error": f"the kept set is damaged ({f}); nothing changed"}
    cur = fsr4_xmx_set(home)
    stage = keep + ".swap"
    shutil.rmtree(stage, ignore_errors=True)
    os.makedirs(stage)
    for f in FSR4_XMX_FILES:
        shutil.copyfile(os.path.join(keep, f), os.path.join(stage, f))
    _fsr4_keep_previous(home, files)                    # what is there now becomes the kept set
    os.makedirs(xdir, exist_ok=True)
    for f in FSR4_XMX_FILES:
        os.replace(os.path.join(stage, f), os.path.join(xdir, f))
    shutil.rmtree(stage, ignore_errors=True)
    version = rec.get("version")
    _fsr4_record(home, None if version == "your own files" else version)
    userexec.chown_tree(xdir, home)
    log.info("FSR 4.1.2 XMX: back to %s (was %s)", version, cur.get("version") or "your own files")
    return {"ok": True, "version": version, "was": cur.get("version") or ("your own files" if cur["present"] else None), "dir": xdir}


def fsr4_xmx_from_package(home: str, entry: dict) -> dict:
    """ClawDeck's fsr4_xmx_from_plugin for GameCove's package: the files that came with the install
    (<package>/bin/fsr4-xmx) copied to ~/fsr4-xmx, each checked against `entry`'s sha256."""
    last: dict = {"ok": False, "copied": [], "missing": list(FSR4_XMX_FILES), "dir": os.path.join(home, FSR4_XMX_DIR)}
    for root in dict.fromkeys((PACKAGE_DIR, SYSTEM_DIR)):
        if not os.path.isdir(os.path.join(root, FSR4_BUNDLED)):
            continue
        _fsr4_keep_previous(home, entry.get("files") or {})
        last = fsr4_xmx_from_plugin(home, root, entry)
        if last.get("ok"):
            _fsr4_record(home, entry.get("version"))
            return last
    return last


def fsr4_xmx_ready(home: str, entries: list[dict], download: bool = False) -> dict:
    """ClawDeck's _fsr4_fetch (it runs at every plugin start): nothing to do while both files are in ~/fsr4-xmx (also
    the user's own, newer ones: never replaced here). Else the set that came with the package (checked against the
    newest entry, then the tested pins), else a pair found in Downloads / Desktop, else, with download=True, the
    download as before. Returns {"ok": files are there, "how"}."""
    def missing() -> bool:
        return any(m in FSR4_XMX_FILES for m in fsr4_xmx_missing(home))
    if not missing():
        return {"ok": True, "how": "there"}
    for e in entries:
        if e and fsr4_xmx_from_package(home, e).get("ok"):
            return {"ok": True, "how": "package", "version": e.get("version")}
    try:
        if fsr4_xmx_import(home).get("imported"):
            return {"ok": True, "how": "imported"}
    except OSError as e:
        log.info("FSR 4.1.2 XMX import: %s", e)
    if download:
        for e in entries:
            if not e:
                continue
            r = fsr4_xmx_download(home, e)
            if r.get("ok"):
                return {"ok": True, "how": "downloaded", "version": e.get("version")}
            log.info("FSR 4.1.2 XMX download: %s", r.get("error"))
    return {"ok": not missing(), "how": "missing"}


def _proton_cabinet(home: str) -> str | None:
    for p in sorted(glob.glob(os.path.join(home, ".local/share/Steam/steamapps/common/Proton*/files/lib/wine/x86_64-windows/cabinet.dll")), reverse=True):
        return p
    return None


FSR4_AMD_DIR = ".local/share/gamecove/fsr4-amd"     # AMD's FSR SDK upscaler (versions.json "fsr4_amd")
FSR4_AMD_FILE = "amd_fidelityfx_upscaler_dx12.dll"


def fsr4_amd_missing(home: str) -> list[str]:
    return [] if os.path.isfile(os.path.join(home, FSR4_AMD_DIR, FSR4_AMD_FILE)) else [FSR4_AMD_FILE]


def fsr4_amd_download(home: str, entry: dict) -> dict:
    """AMD's FSR SDK upscaler into ~/.local/share/gamecove/fsr4-amd, from AMD's GitHub at a pinned commit, sha256
    checked (the same flow as fsr4_xmx_download)."""
    d = os.path.join(home, FSR4_AMD_DIR)
    os.makedirs(d, exist_ok=True)
    got = []
    for name, sha in (entry.get("files") or {}).items():
        dest = os.path.join(d, name)
        if os.path.isfile(dest) and downloads.sha256_of(dest) == sha:
            continue
        err = _get_file(entry, name, entry["base"].rstrip("/") + "/" + name, dest)
        if err:
            return {"ok": False, "error": err}
        got.append(name)
    return {"ok": True, "downloaded": got, "dir": d}


def patch(home: str, folder: str, version: str, ini: dict[str, str], preset: str = "xess",
          fsr4_xmx: bool = False, layout: str = "flat", proxies: list[str] | None = None,
          fsr4_amd: bool = False, force_reflex: str | None = "2") -> dict:
    """Put GameCove's OptiScaler into `folder` (the game's exe folder). Patching again (another preset) rewrites
    the ini and the FSR 4 files; the proxy name and backups stay. Another version or layout than the one in the
    folder is taken out first, then put in fresh. `proxies`: the file names OptiScaler's Compatibility List gives
    for this game, tried first in its order (livedb.game_page), then PROXIES."""
    if layout not in ("flat", "subfolder"):
        return {"ok": False, "error": f"unknown OptiScaler layout {layout!r}"}
    pkg = package_dir(home, version)
    if not installed(home, version):
        return {"ok": False, "error": f"OptiScaler {version} isn't downloaded yet"}
    need = fsr4_xmx_missing(home) if fsr4_xmx else []
    if fsr4_amd and fsr4_amd_missing(home):
        return {"ok": False, "error": f"FSR 4 needs AMD's FSR SDK upscaler in {os.path.join(home, FSR4_AMD_DIR)} (download it first)"}
    if need:                                  # checked before anything is written: no half-patched folder
        return {"ok": False, "error": f"FSR 4 on XMX needs {', '.join(need)} (nitec's files go in {os.path.join(home, FSR4_XMX_DIR)})"}
    who = owner(folder)
    if who["owner"] not in (None, "gamecove"):
        return {"ok": False, "owner": who["owner"],
                "error": "this game already has OptiScaler from " + {"decky-framegen": "Decky Framegen", "clawdeck": "ClawDeck"}.get(who["owner"], "another tool or by hand")
                         + "; remove that first (GameCove never overwrites it)"}
    m = _manifest(folder)
    if m and (m.get("version") != version or (m.get("layout") or "flat") != layout):
        r = unpatch(folder, home)             # 0.9.4 (flat) -> v10 (subfolder) and back: nothing of the old one stays
        if not r.get("ok"):
            return {"ok": False, "error": f"taking out OptiScaler {m.get('version')} first: {r.get('error')}"}
        m = None
    m = m or {"version": version, "layout": layout, "dll": None, "added": [], "backed": [], "dirs": [], "sha256": {}}
    added, backed = m["added"], m["backed"]
    dirs = m.setdefault("dirs", [])
    hashes = m.setdefault("sha256", {})
    sub = "OptiScaler/" if layout == "subfolder" else ""        # where OptiScaler's libraries (and FSR 4's) go
    try:
        dll = m.get("dll")
        if not dll:
            for name in dict.fromkeys([*(x.lower() for x in proxies or [] if x.lower() in PROXIES), *PROXIES]):
                p = os.path.join(folder, name)
                if not os.path.exists(p):
                    dll = name
                    break
            if not dll:
                return {"ok": False, "error": f"every proxy name ({', '.join(PROXIES)}) is taken in {folder}"}
        os.makedirs(os.path.join(folder, STATE), exist_ok=True)
        _put(os.path.join(pkg, "OptiScaler.dll"), os.path.join(folder, dll), folder, added, backed, dirs, hashes)
        for r, d, f in os.walk(pkg):
            for x in f:
                rel = os.path.relpath(os.path.join(r, x), pkg).replace(os.sep, "/")
                if rel in SKIP or rel.startswith(SKIP_PREFIX) or rel.endswith(SKIP_SUFFIX):
                    continue
                if (fsr4_xmx or fsr4_amd) and rel == sub + "amd_fidelityfx_upscaler_dx12.dll":
                    continue
                _put(os.path.join(r, x), os.path.join(folder, rel), folder, added, backed, dirs, hashes)
        # FSR 4 on XMX: nitec's upscaler instead of AMD's, with what it needs; or AMD's back when switched away.
        # The upscaler and fsr-original.dll sit where OptiScaler loads its libraries from (OptiScaler/ in the
        # subfolder layout); GameCove's cabinet.dll and Wine's own as cabinet_wine.dll next to the exe, where Wine
        # loads them (cabinet=n,b).
        xdir = os.path.join(home, FSR4_XMX_DIR)
        extra = (sub + "fsr-original.dll", "cabinet.dll", "cabinet_wine.dll")
        if fsr4_amd:                          # GameCove, AMD: AMD's own FSR SDK 2.4 upscaler instead of the package's
            _put(os.path.join(home, FSR4_AMD_DIR, FSR4_AMD_FILE), os.path.join(folder, sub + FSR4_AMD_FILE), folder,
                 added, backed, dirs, hashes)
        if fsr4_xmx:
            for f in FSR4_XMX_FILES:
                _put(os.path.join(xdir, f), os.path.join(folder, sub + f), folder, added, backed, dirs, hashes)
            _put(own_cabinet(home), os.path.join(folder, "cabinet.dll"), folder, added, backed, dirs, hashes)
            wcab = os.path.join(xdir, "cabinet_wine.dll")
            wcab = wcab if os.path.isfile(wcab) else _proton_cabinet(home)
            if wcab:
                _put(wcab, os.path.join(folder, "cabinet_wine.dll"), folder, added, backed, dirs, hashes)
        else:
            for f in extra:
                if f in added and os.path.exists(os.path.join(folder, f)):
                    if f not in hashes or downloads.sha256_of(os.path.join(folder, f)) == hashes[f]:
                        os.remove(os.path.join(folder, f))
                    added.remove(f)
                    hashes.pop(f, None)
        ini_text = open(os.path.join(pkg, "OptiScaler.ini"), "r", encoding="utf-8", errors="replace").read()
        ini_path = os.path.join(folder, "OptiScaler.ini")
        with open(ini_path, "w", encoding="utf-8") as f:
            f.write(set_ini(ini_text, {**BASE_INI, **ini}))
        if "OptiScaler.ini" not in added:
            added.append("OptiScaler.ini")
        hashes["OptiScaler.ini"] = downloads.sha256_of(ini_path)
        # low latency always on: the game's Reflex becomes XeLL through fakenvapi, forced on even where the game's
        # menu leaves Reflex off (xess-xmx-linux's shim then runs XeLL on the frames)
        fk = os.path.join(folder, "fakenvapi.ini")
        if force_reflex is not None and os.path.isfile(fk) and "fakenvapi.ini" in added:
            t = open(fk, "r", encoding="utf-8", errors="replace").read()
            want = force_reflex                        # Intel: "2", XeLL in every game (maintainer, 2026-11-04)
            t = re.sub(r"(?m)^force_reflex=.*$", f"force_reflex={want}", t) if re.search(r"(?m)^force_reflex=", t) else t + f"\nforce_reflex={want}\n"
            with open(fk, "w", encoding="utf-8") as f:
                f.write(t)
            hashes["fakenvapi.ini"] = downloads.sha256_of(fk)
        m.update({"version": version, "layout": layout, "dll": dll, "preset": preset, "ini": ini, "added": added,
                  "backed": backed, "dirs": dirs, "sha256": hashes})
        with open(os.path.join(folder, STATE, "manifest.json"), "w", encoding="utf-8") as f:
            json.dump(m, f, indent=1)
        for rel in added + [STATE] + [x for x in dirs if "/" not in x]:
            p = os.path.join(folder, rel)
            if os.path.exists(p):
                userexec.chown_tree(p, home)
    except OSError as e:
        return {"ok": False, "error": f"putting OptiScaler into {folder}: {e}"}
    log.info("OptiScaler %s (%s) into %s as %s (%s)", version, layout, folder, dll, preset)
    return {"ok": True, "dll": dll, "dll_override": dll[:-4], "folder": folder, "version": version, "layout": layout}


def unpatch(folder: str | None, home: str | None = None) -> dict:
    """Take GameCove's OptiScaler out (review S2-3): a listed file goes only while its sha256 is what GameCove put
    there; a backup comes back only where the game's file is gone (never over a newer one). Manifests from before
    the hashes: a file is ours when it matches the package file it came from (needs `home`), else it is kept.
    Returns {"ok", "removed", "kept": [files left because they changed], "error"}."""
    m = _manifest(folder) if folder else None
    if not m:
        return {"ok": True, "removed": False, "kept": []}
    errors, kept = [], []
    hashes = m.get("sha256") or {}
    pkg = package_dir(home, m.get("version", "")) if home and m.get("version") else None

    def source_sha(rel: str) -> str | None:
        if not pkg:
            return None
        src = os.path.join(pkg, "OptiScaler.dll") if rel == m.get("dll") else os.path.join(pkg, rel)
        return downloads.sha256_of(src) if os.path.isfile(src) else None

    for rel in m.get("added", []):
        try:
            p = os.path.join(folder, rel)
            if not os.path.isfile(p):
                continue
            want = hashes.get(rel) or source_sha(rel)
            if not want or downloads.sha256_of(p) != want:
                kept.append(rel)          # changed since GameCove put it there (or can't tell): not ours to delete
                continue
            os.remove(p)
        except OSError as e:
            errors.append(f"{rel}: {e}")
    for rel in m.get("backed", []):
        bak = os.path.join(folder, STATE, "backup", rel)
        target = os.path.join(folder, rel)
        if os.path.lexists(target):
            if rel not in kept:
                kept.append(rel)          # a newer file is there (a game update): the old backup never goes over it
            continue
        try:
            os.replace(bak, target)
        except OSError as e:
            errors.append(f"restoring {rel}: {e}")
    if kept:
        log.info("OptiScaler undo in %s kept changed files: %s", folder, ", ".join(kept))
    # what OptiScaler and its helpers write while the game runs: gone too, so the folder is as the game shipped it
    # (maintainer, 2026-11-04: "uninstall removes everything we installed and reverts everything back")
    for pat in RUNTIME_FILES:
        for p in glob.glob(os.path.join(glob.escape(folder), pat)):
            try:
                if os.path.isfile(p) and os.path.relpath(p, folder) not in m.get("backed", []):
                    os.remove(p)
            except OSError:
                pass
    shutil.rmtree(os.path.join(folder, "D3D12_Optiscaler"), ignore_errors=True)
    # the folders GameCove created (manifest "dirs", deepest first): OptiScaler/ of the subfolder layout goes with
    # whatever OptiScaler wrote into it (its caches, logs); any other only when empty
    for rel in sorted(m.get("dirs") or [], key=lambda x: x.count("/"), reverse=True):
        p = os.path.join(folder, rel)
        if rel == "OptiScaler":
            shutil.rmtree(p, ignore_errors=True)
        else:
            try:
                os.rmdir(p)
            except OSError:
                pass
    for d in ("D3D12_Optiscaler", "plugins"):
        try:
            os.rmdir(os.path.join(folder, d))                 # only when empty: the game may have its own plugins/
        except OSError:
            pass
    if not errors:
        shutil.rmtree(os.path.join(folder, STATE), ignore_errors=True)
    return {"ok": not errors, "removed": True, "kept": kept, "error": "; ".join(errors) or None}
