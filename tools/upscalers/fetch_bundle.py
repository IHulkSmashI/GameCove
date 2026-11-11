#!/usr/bin/env python3
"""Build step: everything upscaling needs that we may redistribute, into the app tarball (<export dir>/bin/upscalers),
so GameCove is one install: no download when a game is first set up, and it works offline.

What goes in (each at the version pinned in data/versions.json, sha256 checked, shipped byte for byte):
  OptiScaler 0.9.4 and the v10 nightly for the Capcom setup   GPL-3.0; their own archives, which carry Intel's XeSS
                                                              libraries, AMD's FSR libraries, fakenvapi and
                                                              dlssg-to-fsr3 under their own licences
  OptiPatcher, fakenvapi                                       GPL-3.0, MIT
  REFramework (the fork the Capcom setup uses)                 MIT
  the XeSS XMX driver's release                                MIT and the licences in its THIRD_PARTY.md
  AMD's FSR 4.1.2 upscaler DLL (FSR SDK)                       AMD's binary licence, its notice next to it
Not in here, on purpose: the FSR 4.1.2 XMX build (bin/fsr4-xmx, fetch_fsr4.py), anything from NVIDIA, AMD's driver
DLLs (Proton fetches those itself), lsfg-vk (its licence asks that it come from its author) and what the XMX
driver's own installer fetches from Intel and AMD on XMX devices.

Files are stored under their sha256 (that is how the helper finds them: downloads.bundled), with bundle.json naming
each: component, version, file name, size, licence, where it came from. A file whose bytes are already in
bin/fsr4-xmx (AMD's upscaler DLL is its fsr-original.dll) is not stored twice: bundle.json points at it.

  tools/upscalers/fetch_bundle.py <destination folder> [--fsr4 <bin/fsr4-xmx>]   fetch, check, write bundle.json
  tools/upscalers/fetch_bundle.py --check <folder>                               check a folder against the pins (no network)
"""
from __future__ import annotations

import json
import os
import shutil
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, os.path.join(ROOT, "packaging", "helpers"))

from gamecove_upscale import downloads  # noqa: E402

PINS = os.path.join(ROOT, "packaging", "helpers", "gamecove_upscale", "data", "versions.json")
MANIFEST = "bundle.json"
LICENSES = {"optiscaler": "GPL-3.0 (bundles Intel Simplified Software License, AMD FidelityFX binary licence, MIT parts)",
            "optiscaler_v10": "GPL-3.0 (bundles Intel Simplified Software License, AMD FidelityFX binary licence, MIT parts)",
            "optipatcher": "GPL-3.0", "fakenvapi": "MIT", "reframework": "MIT", "xess_xmx_linux": "MIT and its THIRD_PARTY.md",
            "fsr4_amd": "AMD FidelityFX SDK binary licence (notice shipped as licenses/AMD-FidelityFX-SDK-license.md)"}


def items(pins: dict) -> list[dict]:
    """Every file to bundle: {"component", "version", "name", "sha256", "urls"}."""
    out: list[dict] = []

    def add(comp, version, name, sha, src):
        if not any(i["sha256"] == sha for i in out):
            out.append({"component": comp, "version": str(version), "name": name, "sha256": sha.lower(), "urls": downloads.sources(src)})

    for key in ("optiscaler", "optiscaler_v10", "reframework", "xess_xmx_linux"):
        e = pins[key]
        add(key, e["version"], e.get("asset") or e["url"].rsplit("/", 1)[1], e["sha256"], e)
    for key in ("optiscaler", "optiscaler_v10"):
        for x in pins[key].get("extras", []):
            comp = {"OptiPatcher": "optipatcher", "fakenvapi": "fakenvapi"}.get(x.get("name", ""))
            if comp:
                add(comp, x.get("version", ""), x["url"].rsplit("/", 1)[1], x["sha256"], x)
    amd = pins["fsr4_amd"]
    for name, sha in amd["files"].items():
        mirror = (amd.get("mirror") or {}).get(name)
        add("fsr4_amd", amd["version"], name, sha, {"mirror": mirror, "url": amd["base"].rstrip("/") + "/" + name})
    return out


def load_pins() -> dict:
    with open(PINS, encoding="utf-8") as f:
        return json.load(f)


def _in_fsr4(fsr4_dir: str | None, sha: str) -> str | None:
    """A file of bin/fsr4-xmx with these bytes (AMD's upscaler is its fsr-original.dll), as a path relative to the
    bundle folder."""
    try:
        with open(os.path.join(fsr4_dir or "", "set.json"), encoding="utf-8") as f:
            files = json.load(f).get("files") or {}
    except (OSError, ValueError):
        return None
    return next((os.path.join("..", os.path.basename(fsr4_dir.rstrip("/")), n) for n, s in files.items() if str(s).lower() == sha), None)


def fetch(dest: str, fsr4_dir: str | None = None) -> int:
    os.makedirs(dest, exist_ok=True)
    manifest = {"schema": 1, "files": {}}
    for it in items(load_pins()):
        shared = _in_fsr4(fsr4_dir, it["sha256"])
        path = os.path.join(dest, it["sha256"])
        if shared:
            rel = shared
        else:
            rel = it["sha256"]
            if not (os.path.isfile(path) and downloads.sha256_of(path) == it["sha256"]):
                downloads.get_verified(it["urls"], it["sha256"], path, timeout=600.0)
        full = os.path.normpath(os.path.join(dest, rel))
        manifest["files"][it["sha256"]] = {"path": rel, "name": it["name"], "component": it["component"], "version": it["version"],
                                           "size": os.path.getsize(full), "license": LICENSES[it["component"]], "from": it["urls"][-1]}
        print(f"{it['component']} {it['version']}: {it['name']} ok ({os.path.getsize(full)} bytes{', shared with fsr4-xmx' if shared else ''})")
    for stale in set(os.listdir(dest)) - {MANIFEST} - {v["path"] for v in manifest["files"].values()}:
        os.remove(os.path.join(dest, stale))
    with open(os.path.join(dest, MANIFEST), "w", encoding="utf-8") as f:
        json.dump(manifest, f, indent=1, sort_keys=True)
        f.write("\n")
    return 0


def check(dest: str) -> int:
    """The folder holds exactly the pinned files (and nothing else), each with its sha256."""
    try:
        with open(os.path.join(dest, MANIFEST), encoding="utf-8") as f:
            m = json.load(f).get("files") or {}
    except (OSError, ValueError) as e:
        print(f"{dest}: no usable {MANIFEST} ({e})", file=sys.stderr)
        return 1
    want = {i["sha256"]: i for i in items(load_pins())}
    bad = 0
    for sha in sorted(set(want) | set(m)):
        if sha not in m:
            print(f"missing from the bundle: {want[sha]['name']} ({want[sha]['component']})", file=sys.stderr)
            bad = 1
        elif sha not in want:
            print(f"in the bundle but not pinned: {m[sha].get('name')}", file=sys.stderr)
            bad = 1
        else:
            rel = str(m[sha].get("path", ""))
            p = os.path.normpath(os.path.join(dest, rel))
            if os.path.isabs(rel) or not p.startswith(os.path.dirname(os.path.abspath(dest)) + os.sep) and not p.startswith(os.path.normpath(dest)):
                print(f"{rel}: outside the package", file=sys.stderr)
                bad = 1
            elif not os.path.isfile(p) or downloads.sha256_of(p) != sha:
                print(f"{m[sha].get('name')}: not the pinned bytes", file=sys.stderr)
                bad = 1
    extra = set(os.listdir(dest)) - {MANIFEST} - {v.get("path") for v in m.values()}
    if extra:
        print(f"files nobody named: {', '.join(sorted(extra))}", file=sys.stderr)
        bad = 1
    return bad


def main(argv: list[str]) -> int:
    if len(argv) == 2 and argv[0] == "--check":
        return check(argv[1])
    if argv and argv[0] != "--check" and len(argv) in (1, 3) and (len(argv) == 1 or argv[1] == "--fsr4"):
        return fetch(argv[0], argv[2] if len(argv) == 3 else None)
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
