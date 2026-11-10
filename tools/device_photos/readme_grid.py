#!/usr/bin/env python3
"""The README's "Supported handhelds" picture: every row in app/data/devices.json
(family rows shown as "other models"), grouped by maker, each shown with its real
head-on photo and labelled with its name. Models we've tested GameCove on carry a
"Tested on hardware" pill.

Photos come from --photos DIR, named <device_id>.<png|jpg|jpeg|webp>: the bundled,
free (Wikimedia Commons) and maker images listed in app/data/device_photos.json, as
downloaded for the photo audit. Maker images are their makers' property, appear only
in this README composite, and are removed on request (CREDITS.md, docs/BRANDS.md).
A model without a photo falls back to GameCove's own drawing
(app/assets/devices/art/<art>.svg).

Needs rsvg-convert (fallback drawings only) and Pillow.

    python3 -I tools/device_photos/readme_grid.py docs/images/devices.png --photos DIR
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
import tempfile
from pathlib import Path

from PIL import Image, ImageChops, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parents[2]
DEVICES = ROOT / "app/data/devices.json"
ART = ROOT / "app/assets/devices/art"
FONTS = ROOT / "app/fonts"
PHOTOS = json.loads((ROOT / "app/data/device_photos.json").read_text(encoding="utf-8"))

WIDTH, COLS, PAD, GAP = 1600, 5, 28, 14
ART_H, LABEL_H = 170, 52
BG, CARD, TEXT, QUIET, GOOD = (16, 22, 34), (28, 37, 54), (236, 241, 248), (150, 163, 184), (52, 199, 128)
MAKERS = ["Valve", "ASUS", "Lenovo", "MSI", "OneXPlayer", "AOKZOE", "AYANEO", "GPD", "ZOTAC", "Acer", "Orange Pi"]


def models(doc: dict) -> list[dict]:
    rows = list(doc["devices"])
    order = {m: i for i, m in enumerate(MAKERS)}
    return sorted(rows, key=lambda r: (order.get(r.get("maker", ""), len(MAKERS)), r.get("tier") == "family"))


EXTS = (".png", ".jpg", ".jpeg", ".webp")


def candidates(d: Path | None, dev: str) -> list[Path]:
    """A bundled picture (app/assets/device_photos, wins in the app too), then --photos."""
    out = []
    bundled = PHOTOS.get(dev, {}).get("bundled", "") if isinstance(PHOTOS.get(dev), dict) else ""
    if bundled:
        out.append(ROOT / str(bundled).replace("res://", "app/"))
    if d is not None:
        out += [d / (dev + ext) for ext in EXTS]
    return out


def photo(d: Path | None, dev: str) -> Image.Image | None:
    """The device's photo, cropped to the device (uniform border trimmed)."""
    for f in candidates(d, dev):
        if f.is_file():
            im = Image.open(f).convert("RGBA")
            bg = Image.new("RGBA", im.size, im.getpixel((2, 2)))
            diff = ImageChops.difference(im, bg).convert("L").point(lambda v: 255 if v > 24 else 0)
            box = diff.getbbox()
            if box:
                pad = 8
                box = (max(0, box[0] - pad), max(0, box[1] - pad), min(im.width, box[2] + pad), min(im.height, box[3] + pad))
                im = im.crop(box)
            return im
    return None


def render(svg: Path, width: int, tmp: Path) -> Image.Image:
    out = tmp / (svg.stem + f"-{width}.png")
    if not out.exists():
        subprocess.run(["rsvg-convert", "-w", str(width), str(svg), "-o", str(out)], check=True)
    return Image.open(out).convert("RGBA")


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("out")
    ap.add_argument("--photos", default="", help="folder of <device_id>.<ext> photos")
    a = ap.parse_args(argv)
    pdir = Path(a.photos) if a.photos else None
    drawn = []
    doc = json.loads(DEVICES.read_text(encoding="utf-8"))
    rows = models(doc)
    cell_w = (WIDTH - 2 * PAD - (COLS - 1) * GAP) // COLS
    cell_h = ART_H + LABEL_H + 20
    nrows = (len(rows) + COLS - 1) // COLS
    height = 2 * PAD + nrows * cell_h + (nrows - 1) * GAP
    sheet = Image.new("RGB", (WIDTH, height), BG)
    dr = ImageDraw.Draw(sheet)
    name_font = ImageFont.truetype(str(FONTS / "PlusJakartaSans-SemiBold.ttf"), 19)
    maker_font = ImageFont.truetype(str(FONTS / "PlusJakartaSans-Medium.ttf"), 15)
    pill_font = ImageFont.truetype(str(FONTS / "PlusJakartaSans-Bold.ttf"), 13)
    with tempfile.TemporaryDirectory() as t:
        tmp = Path(t)
        for i, r in enumerate(rows):
            x = PAD + (i % COLS) * (cell_w + GAP)
            y = PAD + (i // COLS) * (cell_h + GAP)
            dr.rounded_rectangle([x, y, x + cell_w, y + cell_h], 14, fill=CARD)
            im = photo(pdir, r["id"])
            if im is not None:
                fill = im.getpixel((0, 0))[:3]
                dr.rounded_rectangle([x + 6, y + 6, x + cell_w - 6, y + ART_H + 12], 10, fill=fill)
                im.thumbnail((cell_w - 24, ART_H - 4), Image.LANCZOS)
            else:
                drawn.append(r["id"])
                svg = ART / f"{r.get('art') or 'generic'}.svg"
                if not svg.is_file():
                    svg = ART / "generic.svg"
                im = render(svg, cell_w - 36, tmp)
                im.thumbnail((cell_w - 36, ART_H))
            sheet.paste(im, (x + (cell_w - im.width) // 2, y + 9 + (ART_H - im.height) // 2), im)
            maker = r.get("maker", "")
            name = r.get("name", r["id"])
            short = name[len(maker):].strip() if name.lower().startswith(maker.lower()) else name
            short = short.replace("(unknown model)", "other models").strip()
            ty = y + ART_H + 18
            dr.text((x + 14, ty), maker, fill=QUIET, font=maker_font)
            dr.text((x + 14, ty + 20), short, fill=TEXT, font=name_font)
            if r.get("support") == "full":
                label = "TESTED ON HARDWARE"
                tw = dr.textlength(label, font=pill_font)
                px = x + cell_w - tw - 30
                dr.rounded_rectangle([px, y + 10, px + tw + 18, y + 32], 11, fill=GOOD)
                dr.text((px + 9, y + 13), label, fill=BG, font=pill_font)
    Path(a.out).parent.mkdir(parents=True, exist_ok=True)
    # Photos make a big PNG: 256 colours with dithering keeps it README-sized.
    sheet.quantize(256, method=Image.Quantize.MEDIANCUT, dither=Image.Dither.FLOYDSTEINBERG).save(a.out, optimize=True)
    print(a.out, sheet.size, len(rows), "models;", "drawings for: " + (", ".join(drawn) or "none"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
