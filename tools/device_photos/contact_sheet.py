#!/usr/bin/env python3
"""Contact sheet of every row's picture in app/data/device_photos.json, to look over
them all at once (the owner's flat, head-on front-view rule).

Bundled pictures ("bundled": res://assets/device_photos/...) are drawn straight from
the repo. Free photos and maker images aren't in the repo (maker images are used by
link only), so pass --dir with the copies you downloaded for the audit, named
<device_id>.<png|jpg|jpeg|webp>; rows without one show MISSING. Family rows show
their representative's picture.

    python tools/device_photos/contact_sheet.py OUT.png [--dir DIR] [ids...]
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

import makers

EXTS = (".png", ".jpg", ".jpeg", ".webp")
W, H, LH, COLS = 360, 240, 34, 5


def sources(doc: dict, d: Path | None) -> dict[str, tuple[Path | None, str]]:
    """{device_id: (image file or None, where it came from)} for every row."""
    files = {}
    if d is not None and d.is_dir():
        files = {p.stem: p for p in sorted(d.iterdir()) if p.suffix.lower() in EXTS}
    reps = makers.representatives(doc)
    out: dict[str, tuple[Path | None, str]] = {}
    for dev, e in doc.items():
        if dev.startswith("_") or not isinstance(e, dict):
            continue
        rid = reps.get(dev, dev)
        r = doc.get(rid, {})
        via = f" via {rid}" if rid != dev else ""
        if "bundled" in r:
            f = makers.bundled_file(str(r["bundled"]))
            out[dev] = (f if f.is_file() else None, "bundled" + via)
        elif rid in files:
            out[dev] = (files[rid], ("maker" if "maker_image" in r else "free") + via)
        else:
            out[dev] = (None, "MISSING" + via)
    return out


def main(argv: list[str] | None = None) -> list[str]:
    ap = argparse.ArgumentParser()
    ap.add_argument("out")
    ap.add_argument("--dir", default="", help="downloaded free photos / maker images, <device_id>.<ext>")
    ap.add_argument("--src", default=str(makers.SRC))
    ap.add_argument("ids", nargs="*")
    a = ap.parse_args(argv)
    doc = json.loads(Path(a.src).read_text(encoding="utf-8"))
    src = sources(doc, Path(a.dir) if a.dir else None)
    ids = a.ids or list(src)
    rows = max(1, (len(ids) + COLS - 1) // COLS)
    sheet = Image.new("RGB", (COLS * W, rows * (H + LH)), (40, 40, 48))
    try:
        font = ImageFont.truetype("/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf", 13)
    except OSError:
        font = ImageFont.load_default()
    dr = ImageDraw.Draw(sheet)
    labels = []
    for i, k in enumerate(ids):
        x, y = (i % COLS) * W, (i // COLS) * (H + LH)
        dr.rectangle([x + 4, y + 4, x + W - 4, y + H - 4], fill=(225, 225, 230))
        f, where = src.get(k, (None, "MISSING"))
        if f is not None and "MISSING" not in where:
            with Image.open(f) as im:
                size = im.size
                im = im.convert("RGBA")
                im.thumbnail((W - 12, H - 12))
                sheet.paste(im, (x + (W - im.width) // 2, y + (H - im.height) // 2), im)
            label = f"{k}  {size[0]}x{size[1]}  {where}"
        else:
            label = f"{k}  {where if 'MISSING' in where else 'MISSING ' + where}"
        labels.append(label)
        dr.text((x + 6, y + H + 8), label, fill=(255, 255, 255), font=font)
    sheet.save(a.out)
    print(a.out, sheet.size, f"{sum('MISSING' not in x for x in labels)}/{len(labels)} pictured")
    return labels


if __name__ == "__main__":
    main()
    sys.exit(0)
