#!/usr/bin/env python3
"""Build step: nitec's FSR 4.1.2 XMX files for the app tarball (<export dir>/bin/fsr4-xmx), the way ClawDeck's
build puts them into its zip (ClawDeck tools/fetch_fsr4.py, same author): from where data/versions.json "fsr4_xmx"
says they are hosted (the fsr4-xmx-files branch of the ClawDeck repository at a pinned commit), each sha256 checked.
A file that doesn't match stops the build. Next to them goes set.json, the set's manifest (version, the sha256 of
each file, where it came from), which the helper reads before it copies them to ~/fsr4-xmx.

  tools/upscalers/fetch_fsr4.py <destination folder>              fetch, check, write set.json
  tools/upscalers/fetch_fsr4.py --check <folder>                  only check a folder against the pins (no network)

The files are shipped as they are, byte for byte: nothing here changes them."""
import hashlib
import json
import os
import sys
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
PINS = os.path.join(ROOT, "packaging", "helpers", "gamecove_upscale", "data", "versions.json")
MANIFEST = "set.json"
MAX_FILE = 256 << 20                    # nitec's upscaler is ~100 MB


def entry() -> dict:
    with open(PINS, encoding="utf-8") as f:
        return json.load(f)["fsr4_xmx"]


def sha256_of(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        while chunk := f.read(1 << 20):
            h.update(chunk)
    return h.hexdigest()


def manifest(e: dict) -> dict:
    return {"component": "fsr4_xmx", "version": e["version"], "files": dict(e["files"]), "base": e["base"],
            "credit": "FSR 4 on XMX by nitec and the OptiScaler community: the FSR 4.1.2 build for the XMX cores. "
                      "Shipped unmodified."}


def check(dest: str, e: dict | None = None) -> list[str]:
    """What is wrong with the folder (nothing: every pinned file is there with its sha256, and set.json says so)."""
    e = e or entry()
    bad = []
    for name, sha in e["files"].items():
        p = os.path.join(dest, name)
        if not os.path.isfile(p):
            bad.append(f"{name}: missing")
        elif sha256_of(p) != sha:
            bad.append(f"{name}: sha256 {sha256_of(p)} doesn't match {sha}")
    try:
        with open(os.path.join(dest, MANIFEST), encoding="utf-8") as f:
            m = json.load(f)
        if m.get("files") != e["files"] or m.get("version") != e["version"]:
            bad.append(f"{MANIFEST}: not the pinned set")
    except (OSError, ValueError):
        bad.append(f"{MANIFEST}: missing or unreadable")
    extra = sorted(set(os.listdir(dest)) - set(e["files"]) - {MANIFEST}) if os.path.isdir(dest) else []
    if extra:
        bad.append("unexpected files: " + ", ".join(extra))
    return bad


def fetch(dest: str, opener=urllib.request.urlopen) -> int:
    e = entry()
    os.makedirs(dest, exist_ok=True)
    for name, sha in e["files"].items():
        url = e["base"].rstrip("/") + "/" + name
        path = os.path.join(dest, name)
        total = 0
        with opener(url, timeout=300) as r, open(path, "wb") as f:
            while chunk := r.read(1 << 20):
                total += len(chunk)
                if total > MAX_FILE:            # never more than a pinned file can be (review 6 low)
                    break
                f.write(chunk)
        if total > MAX_FILE:
            os.remove(path)
            print(f"{name}: larger than {MAX_FILE} bytes, stopped", file=sys.stderr)
            return 1
        got = sha256_of(path)
        if got != sha:
            os.remove(path)
            print(f"{name}: sha256 {got} doesn't match {sha}", file=sys.stderr)
            return 1
        print(f"{name}: ok ({os.path.getsize(path)} bytes)")
    with open(os.path.join(dest, MANIFEST), "w", encoding="utf-8") as f:
        json.dump(manifest(e), f, indent=1, sort_keys=True)
        f.write("\n")
    return 0


def main(argv: list[str]) -> int:
    if len(argv) == 2 and argv[0] == "--check":
        bad = check(argv[1])
        for b in bad:
            print(b, file=sys.stderr)
        return 1 if bad else 0
    if len(argv) != 1:
        print(__doc__, file=sys.stderr)
        return 64
    return fetch(argv[0])


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
