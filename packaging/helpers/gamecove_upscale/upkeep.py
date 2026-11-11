"""What is downloaded, what the newest is, and bringing it up to date (gamecove-upscale check / update).

check()   per component: the version on this handheld, the newest (verified index, else the pins), and whether
          an update is waiting. Only components GameCove downloaded count: one not downloaded yet gets the newest
          the first time it's used anyway, and files the user put there by hand (an unknown sha256) are never
          called outdated. Read-only; with refresh=True the signed index is fetched first.
update()  every component with an update: OptiScaler packages (and their OptiPatcher / fakenvapi), the XeSS XMX
          driver (its own install.sh, as the installer runs it), the FSR 4 files. Games keep the copy they have
          until their own "Update" (games.game_update), so nothing changes under a running game.
"""
from __future__ import annotations

import shutil

import os

from . import downloads, games, lsfg, mirror, optiscaler, selfcheck, xess


def _labels(home: str) -> dict[str, str]:
    """sha256 -> version for every file GameCove knows (the pins and the verified index)."""
    out: dict[str, str] = {}
    for v in (games.pins(), games.versions(home)):
        for key in ("optiscaler", "optiscaler_v10"):
            for x in (v.get(key) or {}).get("extras", []):
                for sha in optiscaler.extra_hashes(x).values():
                    if sha:
                        out.setdefault(sha, str(x.get("version", "")) or sha[:8])
        for key in mirror.FILES_COMPONENTS:
            e = v.get(key) or {}
            for sha in (e.get("files") or {}).values():
                out.setdefault(sha, str(e.get("version", "")) or sha[:8])
    return out


def _row(key: str, installed: str | None, latest: str | None, update: bool, **more) -> dict:
    return {"id": key, "name": mirror.NAMES.get(key, key), "installed": installed, "latest": latest,
            "update": bool(update and installed), **more}


def check(home: str, gpu: dict, refresh: bool = False) -> dict:
    idx_state = mirror.refresh(home) if refresh else None
    eff = games.versions(home)
    labels = _labels(home)
    rows = []
    pk = optiscaler.packages(home)
    for key in ("optiscaler", "optiscaler_v10"):
        e = eff.get(key)
        if not e:
            continue
        layout = e.get("layout") or "flat"
        mine = next((p for p in pk if p["layout"] == layout), None)
        if not mine:
            continue
        have_latest = optiscaler.installed(home, e["version"])
        rows.append(_row(key, mine["version"], e["version"], not have_latest))
        # its extras, as they are in the newest package of this kind
        pkg = optiscaler.package_dir(home, e["version"]) if have_latest else mine["dir"]
        for x in e.get("extras", []):
            xid = {"OptiPatcher": "optipatcher", "fakenvapi": "fakenvapi"}.get(x.get("name", ""))
            if not xid or any(r["id"] == xid for r in rows):
                continue
            for rel, sha in optiscaler.extra_hashes(x).items():
                p = os.path.join(pkg, rel)
                if not os.path.isfile(p):
                    continue
                cur = downloads.sha256_of(p)
                rows.append(_row(xid, labels.get(cur, "unknown"), str(x.get("version", "")) or sha[:8],
                                 sha and cur != sha and cur in labels))
                break
    if games.vendor(gpu) == "intel" and gpu.get("xmx"):
        src = xess.source_of(xess.package_dir(home))
        e = eff.get("xess_xmx_linux") or {}
        if src and src.get("tag"):
            rows.append(_row("xess_xmx_linux", src["tag"], e.get("tag"), e.get("tag") and src["tag"] != e.get("tag")))
    dirs = {"fsr4_xmx": os.path.join(home, optiscaler.FSR4_XMX_DIR), "fsr4_amd": os.path.join(home, optiscaler.FSR4_AMD_DIR)}
    for key, d in dirs.items():
        e = eff.get(key) or {}
        files = e.get("files") or {}
        if not files or not all(os.path.isfile(os.path.join(d, n)) for n in files):
            continue
        cur = {n: downloads.sha256_of(os.path.join(d, n)) for n in files}
        known = all(s in labels for s in cur.values())
        same = cur == {n: s.lower() for n, s in files.items()}
        installed = e.get("version") if same else (labels.get(next(iter(cur.values()))) if known else "your own files")
        rows.append(_row(key, installed, e.get("version"), known and not same))
    st = mirror.status(home)
    return {"ok": True, "components": rows, "update": any(r["update"] for r in rows),
            "index": {**st, **({"refresh": idx_state} if idx_state else {})}}


def _checked(home: str, e: dict, result: dict) -> dict:
    """The self-check after an update (selfcheck.package). A package that fails it is deleted again and its version
    remembered as bad: the device stays on the package it had (rollback), games keep theirs, and the tested pin is
    what new games get until a later version passes."""
    pkg = optiscaler.package_dir(home, e["version"])
    problems = selfcheck.package(pkg, e.get("layout") or "flat")
    if not problems:
        return result
    shutil.rmtree(pkg, ignore_errors=True)
    s = games.load_state(home)
    bad = s.setdefault("bad_versions", [])
    if e["version"] not in bad:
        bad.append(e["version"])
    games.save_state(home, s)
    return {"ok": False, "rolled_back": True, "version": e["version"],
            "error": f"version {e['version']} failed its check ({problems[0]}); kept the one before"}


def update(home: str, gpu: dict, only: str | None = None) -> dict:
    """Every component check() calls outdated (or just `only`). Returns {"ok", "results": {id: result}}."""
    mirror.refresh(home)
    eff = games.versions(home)
    every = check(home, gpu)["components"]
    have = {r["id"] for r in every}
    rows = {r["id"]: r for r in every if r["update"] and (not only or r["id"] == only)}
    extras_due = "optipatcher" in rows or "fakenvapi" in rows
    res: dict = {}
    for key in ("optiscaler", "optiscaler_v10"):
        e = eff.get(key)
        if not e or key not in have:
            continue
        if key in rows or (extras_due and optiscaler.installed(home, e["version"]) and not optiscaler.extras_current(home, e)):
            res[key] = optiscaler.install(home, e)
            if res[key].get("ok"):
                res[key] = _checked(home, e, res[key])
    if "xess_xmx_linux" in rows:
        res["xess_xmx_linux"] = xess.install(home, eff["xess_xmx_linux"])
    if "fsr4_xmx" in rows:
        res["fsr4_xmx"] = optiscaler.fsr4_xmx_download(home, eff["fsr4_xmx"])
    if "fsr4_amd" in rows:
        res["fsr4_amd"] = optiscaler.fsr4_amd_download(home, eff["fsr4_amd"])
    games.prune(home)
    errors = [f"{mirror.NAMES.get(k, k)}: {r.get('error')}" for k, r in res.items() if not r.get("ok")]
    outdated_games = []
    for key, folder in games.load_state(home)["opti_games"].items():
        entry = games._opti_entry(games.get_launch(home, key), home)
        if games.game_outdated(folder, entry):
            outdated_games.append(key)
    return {"ok": not errors, "results": res, "error": "; ".join(errors) or None, "games": outdated_games}


# ---- GameCove: one managed place, its size, and a clean uninstall --------------------------------------------------
# everything upscaling keeps in the user's home, below ~/.local/share/gamecove unless it says otherwise
MANAGED = (("OptiScaler packages", os.path.join(games.DATA, "optiscaler")), ("Downloads and the signed list", os.path.join(games.DATA, "upscalers")),
           ("FSR 4 (AMD)", optiscaler.FSR4_AMD_DIR), ("FSR 4.1.2 on XMX", optiscaler.FSR4_XMX_DIR),
           ("Game lists", games.LISTS), ("Launch settings", os.path.join(games.DATA, "launch")),
           ("Verification tool", os.path.join(games.DATA, "tools")))


def _du(path: str) -> int:
    total = 0
    for r, _d, files in os.walk(path):
        for f in files:
            try:
                total += os.lstat(os.path.join(r, f)).st_size
            except OSError:
                pass
    return total


def storage(home: str) -> dict:
    """What upscaling takes on this handheld: each managed folder's size, the XeSS XMX driver's folders, what came
    inside the install (read-only, counted apart), and how many games have our files in them."""
    parts = []
    for name, rel in MANAGED:
        p = os.path.join(home, rel)
        if os.path.isdir(p):
            parts.append({"name": name, "path": p, "bytes": _du(p)})
    root = os.path.join(home, games.DATA)
    xmx = [os.path.join(root, d) for d in (os.listdir(root) if os.path.isdir(root) else []) if d.startswith("xess-xmx-linux")]
    xmx += [p for p in (os.path.join(home, ".cache", "xess-xmx"),) if os.path.isdir(p)]
    if xmx:
        parts.append({"name": "XeSS XMX driver", "path": xmx[0], "bytes": sum(_du(p) for p in xmx)})
    s = games.load_state(home)
    in_games = [k for k, folder in s["opti_games"].items() if optiscaler.owner(folder)["owner"] == "gamecove"]
    bundle = downloads.bundle_info()
    return {"ok": True, "bytes": sum(p["bytes"] for p in parts), "parts": parts, "folder": root, "games": len(in_games),
            "bundle_bytes": int(bundle.get("bytes") or 0), "bundle_files": int(bundle.get("files") or 0)}


def purge(home: str, gpu: dict) -> dict:
    """Uninstall: every game goes back to how it shipped (the same exact undo as Native), the XeSS XMX driver and an
    lsfg-vk GameCove installed come out, and the managed folders are deleted. The user's own files stay: saves,
    lsfg-vk's config, and FSR 4.1.2 XMX files they put there themselves (only a set that came from GameCove goes)."""
    s = games.load_state(home)
    done, failed = [], []
    for key in sorted(set(s["opti_games"]) | set(s["launch"])):
        try:
            r = games.undo(home, key, gpu, None)
            (done if r.get("ok", True) else failed).append(key)
        except (OSError, ValueError) as e:
            failed.append(f"{key}: {e}")
    out = {"ok": not failed, "games": done, "failed": failed}
    try:
        out["xess"] = xess.remove_for_uninstall(home)
    except (OSError, ValueError) as e:
        out["xess"] = {"ok": False, "error": str(e)}
    out["lsfg_vk"] = lsfg.remove(home)
    removed = []
    for _name, rel in MANAGED:
        p = os.path.join(home, rel)
        if rel == optiscaler.FSR4_XMX_DIR and not _our_fsr4_set(home):
            continue
        if os.path.isdir(p):
            shutil.rmtree(p, ignore_errors=True)
            removed.append(rel)
    for f in (games.STATE,):
        try:
            os.remove(os.path.join(home, f))
        except OSError:
            pass
    out["removed"] = removed
    return out


def _our_fsr4_set(home: str) -> bool:
    """~/fsr4-xmx holds exactly a set GameCove knows (packaged or pinned): then it is ours to remove."""
    d = os.path.join(home, optiscaler.FSR4_XMX_DIR)
    known = [games.pins().get("fsr4_xmx", {}).get("files") or {}]
    packaged = getattr(optiscaler, "fsr4_packaged", lambda: None)()
    if packaged:
        known.append(packaged["files"])
    try:
        have = {n: downloads.sha256_of(os.path.join(d, n)) for n in optiscaler.FSR4_XMX_FILES if os.path.isfile(os.path.join(d, n))}
    except OSError:
        return False
    return bool(have) and any(all(k.get(n) == h for n, h in have.items()) for k in known)
