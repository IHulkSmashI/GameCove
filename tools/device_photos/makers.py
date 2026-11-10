#!/usr/bin/env python3
"""Maker images: the makers' own official product images, used BY LINK ONLY.

For a handheld with no freely licensed photo, app/data/device_photos.json may
carry "maker_image": {url, page_url, maker, checked, view}. The app never copies
these images (only the README grid, readme_grid.py, composites them) and build.py never downloads them for
the device-photos release. The app fetches that one image from the maker's
site on the user's device and credits "Image: <Maker>".

This module checks the entries (no network) and, with --check, requests every
link once and writes a Markdown report of broken ones, for the weekly
workflow that opens or updates a single GitHub issue. Nothing is stored: the
response body is read only far enough to recognise an image and discarded.

    python tools/device_photos/makers.py --check --report broken.md
    exit 0: all links fine, 2: some links broken (report written), 1: bad entries

Family rows ("<maker> (unknown model)") carry "representative": the model whose
picture stands in for them (photo.gd parse_representatives). The link check
covers them through that model's link, and reports them by name, so a broken
link shows every row that loses its picture.

Bundled pictures ("bundled": "res://assets/device_photos/<id>.webp") ship
inside the app: they have no link, so the link check and the maker-domain
rules skip them; bundled_problems() checks the path and that the file exists.

The rules here match app/scripts/device/photo.gd (parse_maker_sources,
parse_bundled); keep them in step.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
import time
import urllib.parse
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SRC = ROOT / "app/data/device_photos.json"
MAX_BYTES = 3 * 1024 * 1024
DATE = re.compile(r"^\d{4}-\d{2}-\d{2}$")
BUNDLED = re.compile(r"^res://assets/device_photos/[a-z0-9][a-z0-9._-]{0,80}\.(webp|png|jpg)$")
BUNDLED_MAX_BYTES = 512 * 1024
UA = "GameCove-link-check/1 (+https://github.com/IHulkSmashI/GameCove)"


def sniff(head: bytes) -> str:
    """'png' | 'jpg' | 'webp' | '' from the first bytes (same as photo.gd)."""
    if head.startswith(b"\x89PNG\r\n\x1a\n"):
        return "png"
    if head.startswith(b"\xff\xd8\xff"):
        return "jpg"
    if len(head) >= 12 and head[:4] == b"RIFF" and head[8:12] == b"WEBP":
        return "webp"
    return ""


def host_ok(url: str, domains: list[str]) -> bool:
    if not url.startswith("https://"):
        return False
    host = (urllib.parse.urlsplit(url).hostname or "").lower()
    return any(host == d or host.endswith("." + d) for d in domains)


def entry_problems(dev: str, m: object, makers: dict) -> list[str]:
    """Why a maker_image entry is not acceptable ([] when it is)."""
    if not isinstance(m, dict):
        return [f"{dev}: maker_image is not an object"]
    out = []
    maker = str(m.get("maker", ""))
    rules = makers.get(maker)
    if not rules:
        return [f"{dev}: maker {maker!r} is not in _makers"]
    url = str(m.get("url", ""))
    if not any(url.startswith(p) for p in rules.get("image_prefixes", [])):
        out.append(f"{dev}: url {url!r} is not on {maker}'s own site or image CDN (_makers)")
    if not host_ok(str(m.get("page_url", "")), rules.get("page_domains", [])):
        out.append(f"{dev}: page_url {m.get('page_url')!r} is not a {maker} page")
    if not DATE.match(str(m.get("checked", ""))):
        out.append(f"{dev}: checked must be YYYY-MM-DD")
    out += view_problems(dev, m)
    return out


def bundled_file(path: str) -> Path:
    """res://assets/device_photos/x.webp -> <repo>/app/assets/device_photos/x.webp"""
    return ROOT / "app" / path[len("res://"):]


def bundled_problems(dev: str, e: dict) -> list[str]:
    """Why a "bundled" entry is not acceptable ([] when it is): path rule (same as
    photo.gd parse_bundled), file present, a real image of its type, small, front view."""
    path = str(e.get("bundled", ""))
    if not BUNDLED.match(path) or ".." in path:
        return [f"{dev}: bundled {path!r} must be res://assets/device_photos/<name>.webp|png|jpg"]
    f = bundled_file(path)
    if not f.is_file():
        return [f"{dev}: bundled file {f} is missing"]
    data = f.read_bytes()
    kind = sniff(data[:16])
    out = []
    if kind != path.rsplit(".", 1)[1]:
        out.append(f"{dev}: {f.name} is not a {path.rsplit('.', 1)[1]} image (looks like {kind or 'neither'})")
    imp = f.with_name(f.name + ".import")
    if not imp.is_file() or 'importer="keep"' not in imp.read_text(encoding="utf-8"):
        out.append(f"{dev}: {imp.name} must say importer=\"keep\" (Godot otherwise exports only a texture, "
                   "not the file the app reads)")
    if len(data) > BUNDLED_MAX_BYTES:
        out.append(f"{dev}: {f.name} is {len(data)} bytes; keep bundled pictures under {BUNDLED_MAX_BYTES}")
    return out + view_problems(dev, e)


def bundled_rows(path: Path = SRC) -> dict:
    """{device_id: entry} for rows with a bundled picture."""
    doc = json.loads(path.read_text(encoding="utf-8"))
    return {k: v for k, v in doc.items()
            if not k.startswith("_") and isinstance(v, dict) and "bundled" in v}


# Owner's rule: every picture is a flat, head-on front view (camera straight at the
# screen; no angle, tilt, side or back view, no hands). "best-available" marks the few
# rows where no such image exists anywhere we looked; view_note says why.
VIEWS = ("front", "best-available")


def view_problems(dev: str, e: dict) -> list[str]:
    """Why a picture entry's "view" is not acceptable ([] when it is)."""
    view = e.get("view")
    if view not in VIEWS:
        return [f"{dev}: view must be one of {VIEWS} (a flat, head-on front view), got {view!r}"]
    if view == "best-available" and not str(e.get("view_note", "")).strip():
        return [f"{dev}: view 'best-available' needs a view_note saying why no head-on image exists"]
    return []


def load(path: Path = SRC) -> tuple[dict, dict]:
    """(makers rules, {device_id: maker_image})."""
    doc = json.loads(path.read_text(encoding="utf-8"))
    makers = doc.get("_makers", {})
    entries = {k: v["maker_image"] for k, v in doc.items()
               if not k.startswith("_") and isinstance(v, dict) and "maker_image" in v and "bundled" not in v}
    return makers, entries


def representatives(doc: dict) -> dict:
    """{family id: representative id} (same rule as photo.gd parse_representatives)."""
    out = {}
    for k, v in doc.items():
        if k.startswith("_") or not isinstance(v, dict) or "representative" not in v:
            continue
        rep = str(v["representative"])
        r = doc.get(rep)
        if rep != k and isinstance(r, dict) and "representative" not in r and \
                any(x in r for x in ("file", "openverse_id", "maker_image", "bundled")):
            out[k] = rep
    return out


def family_problems(doc: dict) -> list[str]:
    """Why a family row's representative can't stand in ([] when all are fine)."""
    reps = representatives(doc)
    return [f"{k}: representative {v.get('representative')!r} is not a row with a picture of its own"
            for k, v in doc.items()
            if not k.startswith("_") and isinstance(v, dict) and "representative" in v and k not in reps]


def checked_rows(path: Path = SRC) -> dict:
    """Every row the link check covers: {device_id: maker_image}, families through
    their representative's link. Bundled pictures have no link and are skipped."""
    doc = json.loads(path.read_text(encoding="utf-8"))
    _, entries = load(path)
    out = dict(entries)
    for fam, rep in representatives(doc).items():
        if rep in entries:
            out[fam] = dict(entries[rep], via=rep)
    return out


def check_url(url: str, timeout: float = 20.0, tries: int = 3) -> str:
    """'' when the link answers with an image under the size cap, else why not.
    A failed request is tried again (some makers' hosts drop the odd connection)."""
    why = ""
    for i in range(tries):
        why = _check_once(url, timeout)
        if not why.startswith("request failed"):
            return why
        time.sleep(2 * (i + 1))
    return why


def _check_once(url: str, timeout: float) -> str:
    req = urllib.request.Request(url, headers={"User-Agent": UA, "Accept": "image/png,image/jpeg,image/webp,*/*;q=0.5"})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            size = int(r.headers.get("Content-Length") or 0)
            head = r.read(64)
    except Exception as ex:  # noqa: BLE001 - any failure is a broken link
        return f"request failed: {ex}"
    if size > MAX_BYTES:
        return f"too big ({size} bytes, cap {MAX_BYTES})"
    if not sniff(head):
        return "not a PNG, JPEG or WebP image"
    return ""


def report(broken: list[tuple[str, dict, str]]) -> str:
    lines = ["Weekly check of the makers' product-image links in `app/data/device_photos.json` "
             "(shown by link only; see docs/DEVICES.md). These no longer answer with an image, "
             "so the app falls back to the drawing for them. Find the new image on the maker's "
             "product page and update `url`, `page_url` and `checked`.", "",
             "| Device | Maker | Problem | Image link | Product page |", "|---|---|---|---|---|"]
    for dev, m, why in broken:
        name = f"`{dev}` (shows `{m['via']}`)" if m.get("via") else f"`{dev}`"
        lines.append(f"| {name} | {m.get('maker', '')} | {why.replace('|', '/')} | {m.get('url', '')} | {m.get('page_url', '')} |")
    return "\n".join(lines) + "\n"


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--src", default=str(SRC))
    ap.add_argument("--check", action="store_true", help="request every link (network)")
    ap.add_argument("--report", default="", help="write the Markdown list of broken links here")
    a = ap.parse_args(argv)
    makers, entries = load(Path(a.src))
    problems = [p for dev, m in entries.items() for p in entry_problems(dev, m, makers)]
    problems += family_problems(json.loads(Path(a.src).read_text(encoding="utf-8")))
    problems += [p for dev, e in bundled_rows(Path(a.src)).items() for p in bundled_problems(dev, e)]
    for p in problems:
        print("BAD ENTRY", p, file=sys.stderr)
    if problems:
        return 1
    if not a.check:
        print(f"{len(entries)} maker image links, all well-formed")
        return 0
    broken = []
    seen: dict[str, str] = {}
    entries = checked_rows(Path(a.src))
    for dev, m in sorted(entries.items()):
        url = m["url"]
        if url not in seen:
            seen[url] = check_url(url)
        if seen[url]:
            broken.append((dev, m, seen[url]))
            print(f"BROKEN {dev}: {seen[url]}")
    if a.report:
        Path(a.report).write_text(report(broken) if broken else "", encoding="utf-8")
    print(f"{len(entries)} links checked, {len(broken)} broken")
    return 2 if broken else 0


if __name__ == "__main__":
    sys.exit(main())
