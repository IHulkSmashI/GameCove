#!/usr/bin/env python3
"""The upscalers publish job's own check of what the build job handed over (review 2, problem 15).

The build job runs third-party code (downloads, archives, 7-Zip); the publish job signs whatever it gets. So before
signing, this re-checks the artifact with Python's standard library and GameCove's own mirror.py only:

  - upscalers.json parses as an index devices accept (mirror.parse), which also means every upstream URL is the
    component's official repository (mirror.UPSTREAM);
  - every planned upload is a plain file under dist/upload/<tag>/<name>, with a release tag and asset name of the
    expected shape;
  - every planned file is re-hashed: its name carries the first 8 hex digits of that hash, and when the index or a
    pin in versions.json names that file, the full sha256 must be the one named. A file neither names (other than
    AMD's licence notice, which goes next to its DLL) is refused.

  check_plan.py <dist> <versions.json>      exit 0 when it all holds, else 1 with the reason
"""
from __future__ import annotations

import hashlib
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "..", "packaging", "helpers"))

from gamecove_upscale import mirror  # noqa: E402

COMPONENTS = tuple(mirror.UPSTREAM)


def _sha(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def _named(idx: dict, pins: dict) -> dict:
    """{mirror file name: sha256} for every file the index or the pins name."""
    out: dict = {}

    def add(url, sha):
        if isinstance(url, str) and isinstance(sha, str) and mirror.is_mirror_url(url):
            out[url.rsplit("/", 1)[1]] = sha.lower()

    def walk_index(e):
        if not isinstance(e, dict):
            return
        add(e.get("mirror_url"), e.get("sha256"))
        walk_index(e.get("source"))
        for f in (e.get("files") or {}).values():
            walk_index(f)

    for e in idx.get("components", {}).values():
        walk_index(e)
    for e in (idx.get("pin_sources") or {}).values():
        walk_index(e)

    def walk_pins(e):
        if isinstance(e, dict):
            if isinstance(e.get("mirror"), str):
                add(e["mirror"], e.get("sha256"))
            elif isinstance(e.get("mirror"), dict) and isinstance(e.get("files"), dict):
                for fn, sha in e["files"].items():
                    add(e["mirror"].get(fn), sha)
            for v in e.values():
                walk_pins(v)
        elif isinstance(e, list):
            for v in e:
                walk_pins(v)

    walk_pins(pins)
    return out


def check(dist: str, versions_path: str) -> list[str]:
    """What's wrong with the artifact ([] when nothing is)."""
    errs = []
    try:
        idx = mirror.parse(open(os.path.join(dist, mirror.INDEX_NAME), "rb").read())
    except (OSError, ValueError) as e:
        return [f"upscalers.json: {e}"]
    pins = json.load(open(versions_path, encoding="utf-8"))
    named = _named(idx, pins)
    plan = os.path.join(dist, "upload-plan.tsv")
    for line in open(plan, encoding="utf-8") if os.path.exists(plan) else []:
        if not line.strip():
            continue
        parts = line.rstrip("\n").split("\t")
        if len(parts) != 3:
            errs.append(f"plan line: {line!r}")
            continue
        tag, name, rel = parts
        if not re.fullmatch(r"upscalers(-[0-9]{1,3})?", tag) or not mirror.FILE_RE.match(name) or "/" in name:
            errs.append(f"tag or name: {tag}/{name}")
            continue
        if rel != f"upload/{tag}/{name}":
            errs.append(f"path: {rel}")
            continue
        p = os.path.join(dist, rel)
        if not os.path.isfile(p) or os.path.islink(p):
            errs.append(f"missing or not a plain file: {rel}")
            continue
        sha = _sha(p)
        if not name.startswith(tuple(c + "-" for c in COMPONENTS)) or f"-{sha[:8]}-" not in name:
            errs.append(f"{name}: its name doesn't carry its sha256 ({sha[:8]})")
            continue
        if name in named:
            if named[name] != sha:
                errs.append(f"{name}: sha256 {sha} isn't the {named[name]} the index or versions.json names")
        elif not name.endswith("-license.md"):
            errs.append(f"{name}: neither the index nor versions.json names this file")
    return errs


def main(argv: list[str] | None = None) -> int:
    a = sys.argv[1:] if argv is None else argv
    if len(a) != 2:
        print(__doc__, file=sys.stderr)
        return 2
    errs = check(a[0], a[1])
    for e in errs:
        print(f"refused: {e}", file=sys.stderr)
    return 1 if errs else 0


if __name__ == "__main__":
    sys.exit(main())
