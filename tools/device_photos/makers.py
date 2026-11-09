#!/usr/bin/env python3
"""Maker images: the makers' own official product images, used BY LINK ONLY.

For a handheld with no freely licensed photo, app/data/device_photos.json may
carry "maker_image": {url, page_url, maker, checked}. GameCove never copies
these images: they are not in the repo and build.py never downloads them for
the device-photos release. The app fetches that one image from the maker's
site on the user's device and credits "Image: <Maker>".

This module checks the entries (no network) and, with --check, requests every
link once and writes a Markdown report of broken ones, for the weekly
workflow that opens or updates a single GitHub issue. Nothing is stored: the
response body is read only far enough to recognise an image and discarded.

    python tools/device_photos/makers.py --check --report broken.md
    exit 0: all links fine, 2: some links broken (report written), 1: bad entries

The rules here match app/scripts/device/photo.gd (parse_maker_sources); keep
them in step.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
import urllib.parse
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SRC = ROOT / "app/data/device_photos.json"
MAX_BYTES = 3 * 1024 * 1024
DATE = re.compile(r"^\d{4}-\d{2}-\d{2}$")
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
    return out


def load(path: Path = SRC) -> tuple[dict, dict]:
    """(makers rules, {device_id: maker_image})."""
    doc = json.loads(path.read_text(encoding="utf-8"))
    makers = doc.get("_makers", {})
    entries = {k: v["maker_image"] for k, v in doc.items()
               if not k.startswith("_") and isinstance(v, dict) and "maker_image" in v}
    return makers, entries


def check_url(url: str, timeout: float = 20.0) -> str:
    """'' when the link answers with an image under the size cap, else why not."""
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
        lines.append(f"| `{dev}` | {m.get('maker', '')} | {why.replace('|', '/')} | {m.get('url', '')} | {m.get('page_url', '')} |")
    return "\n".join(lines) + "\n"


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--src", default=str(SRC))
    ap.add_argument("--check", action="store_true", help="request every link (network)")
    ap.add_argument("--report", default="", help="write the Markdown list of broken links here")
    a = ap.parse_args(argv)
    makers, entries = load(Path(a.src))
    problems = [p for dev, m in entries.items() for p in entry_problems(dev, m, makers)]
    for p in problems:
        print("BAD ENTRY", p, file=sys.stderr)
    if problems:
        return 1
    if not a.check:
        print(f"{len(entries)} maker image links, all well-formed")
        return 0
    broken = []
    seen: dict[str, str] = {}
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
