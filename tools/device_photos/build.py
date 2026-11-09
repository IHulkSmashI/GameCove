#!/usr/bin/env python3
"""Build the "device-photos" release: real photos of each handheld.

Reads app/data/device_photos.json, re-checks every photo's license at its
source, downloads a ~1200 px rendition, converts it to WebP and writes the
files plus manifest.json (sha256, size, credit) to --out. Sources:

- Wikimedia Commons (default; "file"): license from the Commons API
  (extmetadata LicenseShortName).
- Openverse ("source": "openverse", "openverse_id"): Flickr and other photos
  Openverse indexes. License, author and the original file URL come from
  Openverse's image API (Flickr's own API needs a key). Only Flickr landing
  pages are accepted, so the credit always links to the photographer's page.

The license must be CC0, public domain, CC BY or CC BY-SA; anything else is
skipped with a loud warning. Entries with any other source (YouTube frames,
Unsplash, Pexels) can't be re-checked automatically and are skipped with a
warning; "_manual" lists such candidates for a person to handle.

    python tools/device_photos/build.py --out dist [--previous prev/manifest.json]

--previous: last published manifest. When a download fails for a network
reason (not a license reason), that device keeps its previous entry, so a
flaky run doesn't take photos away for a week. The old asset stays on the
release because uploads never delete.

"maker_image" entries (the makers' own product images, used by link only)
are never downloaded or published here; rows that only have one are skipped
quietly. See makers.py.

Needs Pillow. The same license rule lives in app/scripts/device/photo.gd
(license_allowed); keep the two in step.
"""

from __future__ import annotations

import argparse
import hashlib
import io
import json
import re
import sys
import time
import urllib.parse
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
API = "https://commons.wikimedia.org/w/api.php"
PAGE = "https://commons.wikimedia.org/wiki/File:"
OPENVERSE = "https://api.openverse.org/v1/images/"
FLICKR_PAGE = "https://www.flickr.com/photos/"
# Credit links the app accepts (photo.gd PAGE_PREFIXES); keep in step.
PAGE_PREFIXES = (PAGE, FLICKR_PAGE)
WIDTH = 1200
MAX_BYTES = 4 * 1024 * 1024
BAD = (" nc", " nd", "noncommercial", "non commercial", "noderiv", "no deriv",
       "fair use", "non free", "copyrighted")
GOOD = {"cc0", "cc0 1.0", "cc zero", "public domain", "pd", "no restrictions"}
CC = re.compile(r"^cc by( sa)? \d\.\d( [a-z]+)?$")


def license_allowed(short_name: str) -> bool:
    s = re.sub(r"[-_\s]+", " ", (short_name or "").strip().lower())
    if not s:
        return False
    if any(b in " " + s for b in BAD):
        return False
    if s in GOOD or s.startswith("public domain") or s.startswith("pd "):
        return True
    return CC.match(s) is not None


def warn(msg: str) -> None:
    # GitHub turns this into a yellow annotation on the run page.
    print(f"::warning::{msg}", flush=True)


def user_agent() -> str:
    ver = "dev"
    spec = ROOT / "packaging/rpm/gamecove.spec"
    if spec.exists():
        m = re.search(r"^Version:\s*(\S+)", spec.read_text(), re.M)
        if m:
            ver = m.group(1)
    return f"GameCove/{ver} (+https://github.com/IHulkSmashI/GameCove)"


def get(url: str, tries: int = 4) -> bytes:
    delay = 5.0
    for i in range(tries):
        req = urllib.request.Request(url, headers={"User-Agent": user_agent()})
        try:
            with urllib.request.urlopen(req, timeout=60) as r:
                return r.read(MAX_BYTES * 4 + 1)
        except urllib.error.HTTPError as e:
            if e.code not in (429, 500, 502, 503, 504) or i == tries - 1:
                raise
            wait = float(e.headers.get("Retry-After") or delay)
            time.sleep(min(wait, 60))
            delay *= 2
        except urllib.error.URLError:
            if i == tries - 1:
                raise
            time.sleep(delay)
            delay *= 2
    raise RuntimeError("unreachable")


def strip_html(s: str) -> str:
    return re.sub(r"\s+", " ", re.sub(r"<[^>]+>", "", s or "")).strip()


def commons_info(file: str) -> dict:
    q = urllib.parse.urlencode({
        "action": "query", "format": "json", "formatversion": "2",
        "prop": "imageinfo", "iiprop": "url|extmetadata|mime",
        "iiurlwidth": str(WIDTH), "titles": "File:" + file,
    })
    doc = json.loads(get(f"{API}?{q}"))
    pages = doc.get("query", {}).get("pages", [])
    if not pages or pages[0].get("missing") or not pages[0].get("imageinfo"):
        return {}
    ii = pages[0]["imageinfo"][0]
    meta = {k: (v or {}).get("value", "") for k, v in ii.get("extmetadata", {}).items()}
    return {
        "license": strip_html(meta.get("LicenseShortName", "")),
        "license_url": strip_html(meta.get("LicenseUrl", "")),
        "non_free": str(meta.get("NonFree", "")).lower() in ("true", "1"),
        "artist": strip_html(meta.get("Artist", "")),
        "thumb": ii.get("thumburl") or ii.get("url", ""),
        "mime": ii.get("mime", ""),
    }


def openverse_license_name(lic: str, version: str) -> str:
    """Openverse's license code + version -> a short name license_allowed() reads."""
    lic = (lic or "").strip().lower()
    version = (version or "").strip()
    if lic == "cc0":
        return "CC0"
    if lic in ("pdm", "pd"):
        return "Public domain"
    if lic in ("by", "by-sa", "by-nc", "by-nd", "by-nc-sa", "by-nc-nd"):
        return f"CC {lic.upper()} {version}".strip()
    return lic


def openverse_info(image_id: str) -> dict:
    if not re.fullmatch(r"[0-9a-f-]{36}", image_id or ""):
        return {}
    doc = json.loads(get(OPENVERSE + image_id + "/"))
    landing = str(doc.get("foreign_landing_url") or "")
    return {
        "license": openverse_license_name(doc.get("license", ""), str(doc.get("license_version") or "")),
        "license_url": str(doc.get("license_url") or ""),
        "non_free": False,
        "artist": str(doc.get("creator") or ""),
        "thumb": str(doc.get("url") or ""),
        "page_url": landing if landing.startswith(FLICKR_PAGE) else "",
        "mime": str(doc.get("filetype") or ""),
    }


def source_key(e: dict) -> tuple[str, str]:
    """(source, id) for an entry: ("commons", file) or ("openverse", uuid)."""
    src = str(e.get("source", "commons")).lower()
    if src == "commons":
        return src, str(e.get("file", ""))
    if src == "openverse":
        return src, str(e.get("openverse_id", ""))
    return src, ""


def has_free_source(e: dict) -> bool:
    """True when the entry names a free photo (Commons file, Openverse id or another
    source to warn about), False for rows that only carry a maker_image link."""
    return any(k in e for k in ("file", "openverse_id", "source"))


def commons_page(file: str) -> str:
    return PAGE + urllib.parse.quote(file.replace(" ", "_"), safe="()_,-.!'")


def to_webp(raw: bytes) -> bytes:
    from PIL import Image
    im = Image.open(io.BytesIO(raw))
    im.load()
    if im.mode not in ("RGB", "RGBA"):
        im = im.convert("RGBA" if "A" in im.getbands() or "transparency" in im.info else "RGB")
    if im.width > WIDTH:
        im = im.resize((WIDTH, round(im.height * WIDTH / im.width)), Image.LANCZOS)
    out = io.BytesIO()
    im.save(out, "WEBP", quality=82, method=6)
    return out.getvalue()


def asset_name(device_id: str) -> str:
    return re.sub(r"[^a-z0-9._-]", "-", device_id.lower()).lstrip(".-")[:70] + ".webp"


def main(argv=None) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--src", default=str(ROOT / "app/data/device_photos.json"))
    ap.add_argument("--out", required=True)
    ap.add_argument("--previous", default="")
    a = ap.parse_args(argv)
    out = Path(a.out)
    out.mkdir(parents=True, exist_ok=True)
    src = json.loads(Path(a.src).read_text(encoding="utf-8"))
    prev = {}
    if a.previous and Path(a.previous).is_file():
        try:
            prev = json.loads(Path(a.previous).read_text()).get("devices", {})
        except ValueError:
            prev = {}

    devices: dict[str, dict] = {}
    built: dict[str, dict] = {}   # Commons file -> {asset, sha256, size, license, license_url}
    refused: list[str] = []
    for dev_id, e in src.items():
        if dev_id.startswith("_") or not isinstance(e, dict):
            continue
        if not has_free_source(e):
            continue  # maker_image only: shown by link in the app, never copied
        src, file = source_key(e)
        if src not in ("commons", "openverse"):
            warn(f"SKIPPED {dev_id}: source {src!r} can't be re-checked automatically; "
                 "upload the photo to Commons first (docs/DEVICES.md)")
            refused.append(dev_id)
            continue
        if not file:
            continue
        if file not in built:
            try:
                info = commons_info(file) if src == "commons" else openverse_info(file)
            except Exception as ex:  # network: keep last week's entry
                warn(f"{dev_id}: Commons API failed for {file!r} ({ex}); keeping the previous entry if any")
                if dev_id in prev and prev[dev_id].get("credit", {}).get("file") == file:
                    devices[dev_id] = prev[dev_id]
                continue
            if src == "openverse" and info and not info["page_url"]:
                warn(f"SKIPPED {dev_id}: Openverse image {file!r} isn't from Flickr; only Flickr pages are accepted")
                info = {}
            if not info:
                warn(f"SKIPPED {dev_id}: {file!r} not found ({src})")
                refused.append(dev_id)
                continue
            if info["non_free"] or not license_allowed(info["license"]):
                warn(f"SKIPPED {dev_id}: {file!r} has license {info['license']!r}, which is not allowed "
                     "(only CC0, public domain, CC BY, CC BY-SA)")
                refused.append(dev_id)
                continue
            if info["license"].lower() != str(e.get("license", "")).lower():
                warn(f"{dev_id}: license on Commons is {info['license']!r}, device_photos.json says "
                     f"{e.get('license')!r}; using Commons' value. Please update device_photos.json.")
            try:
                data = to_webp(get(info["thumb"]))
            except Exception as ex:
                warn(f"{dev_id}: download/convert failed for {file!r} ({ex}); keeping the previous entry if any")
                if dev_id in prev and prev[dev_id].get("credit", {}).get("file") == file:
                    devices[dev_id] = prev[dev_id]
                continue
            if len(data) > MAX_BYTES:
                warn(f"SKIPPED {dev_id}: {file!r} is too big after conversion ({len(data)} bytes)")
                continue
            name = asset_name(e.get("family_of") or dev_id)
            (out / name).write_bytes(data)
            built[file] = {"asset": name, "sha256": hashlib.sha256(data).hexdigest(), "size": len(data),
                           "license": info["license"], "license_url": info["license_url"] or e.get("license_url", ""),
                           "page_url": commons_page(file) if src == "commons" else info["page_url"]}
            time.sleep(1.0)  # be gentle with Commons and Openverse
        b = built.get(file)
        if b is None:
            continue
        devices[dev_id] = {
            "asset": b["asset"], "sha256": b["sha256"], "size": b["size"],
            "credit": {
                "author": str(e.get("author", "")),
                "license": b["license"],
                "license_url": b["license_url"] if str(b["license_url"]).startswith("https://") else "",
                "page_url": b["page_url"],
                "file": file,
            },
        }
        if e.get("family_of"):
            devices[dev_id]["family_of"] = e["family_of"]

    manifest = {"version": 1, "generated": int(time.time()), "devices": dict(sorted(devices.items()))}
    (out / "manifest.json").write_text(json.dumps(manifest, indent=1, ensure_ascii=False) + "\n", encoding="utf-8")
    print(f"{len(devices)} devices with a photo, {len(built)} files built, {len(refused)} refused: {refused}")
    return 0 if devices else 1


if __name__ == "__main__":
    sys.exit(main())
