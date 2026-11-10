#!/usr/bin/env python3
"""The README's "Supported devices" picture: every model in app/data/devices.json
(family / unknown-model rows left out), grouped by maker, each drawn with GameCove's
own front-view drawing (app/assets/devices/art/<art>.svg, GPL-3.0-or-later) and
labelled with its name. Models we've tested GameCove on carry a "Tested" pill.

Maker product photos aren't used here on purpose: they're shown in the app by link
only and never distributed with GameCove (CREDITS.md, "Maker images").

Needs rsvg-convert and Pillow.

    python3 -I tools/device_photos/readme_grid.py docs/images/devices.png
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
import tempfile
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parents[2]
DEVICES = ROOT / "app/data/devices.json"
ART = ROOT / "app/assets/devices/art"
FONTS = ROOT / "app/fonts"

WIDTH, COLS, PAD, GAP = 1600, 5, 28, 14
ART_H, LABEL_H = 150, 52
BG, CARD, TEXT, QUIET, GOOD = (16, 22, 34), (28, 37, 54), (236, 241, 248), (150, 163, 184), (52, 199, 128)
MAKERS = ["Valve", "ASUS", "Lenovo", "MSI", "OneXPlayer", "AOKZOE", "AYANEO", "GPD", "ZOTAC", "Acer", "Orange Pi"]


def models(doc: dict) -> list[dict]:
    rows = [r for r in doc["devices"] if r.get("tier") != "family"]
    order = {m: i for i, m in enumerate(MAKERS)}
    return sorted(rows, key=lambda r: order.get(r.get("maker", ""), len(MAKERS)))


def render(svg: Path, width: int, tmp: Path) -> Image.Image:
    out = tmp / (svg.stem + f"-{width}.png")
    if not out.exists():
        subprocess.run(["rsvg-convert", "-w", str(width), str(svg), "-o", str(out)], check=True)
    return Image.open(out).convert("RGBA")


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("out")
    a = ap.parse_args(argv)
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
            svg = ART / f"{r.get('art') or 'generic'}.svg"
            if not svg.is_file():
                svg = ART / "generic.svg"
            im = render(svg, cell_w - 36, tmp)
            im.thumbnail((cell_w - 36, ART_H))
            sheet.paste(im, (x + (cell_w - im.width) // 2, y + 12 + (ART_H - im.height) // 2), im)
            maker = r.get("maker", "")
            name = r.get("name", r["id"])
            short = name[len(maker):].strip() if name.lower().startswith(maker.lower()) else name
            ty = y + ART_H + 18
            dr.text((x + 14, ty), maker, fill=QUIET, font=maker_font)
            dr.text((x + 14, ty + 20), short, fill=TEXT, font=name_font)
            if r.get("support") == "full":
                label = "TESTED"
                tw = dr.textlength(label, font=pill_font)
                px = x + cell_w - tw - 30
                dr.rounded_rectangle([px, y + 10, px + tw + 18, y + 32], 11, fill=GOOD)
                dr.text((px + 9, y + 13), label, fill=BG, font=pill_font)
    Path(a.out).parent.mkdir(parents=True, exist_ok=True)
    sheet.save(a.out, optimize=True)
    print(a.out, sheet.size, len(rows), "models")
    return 0


if __name__ == "__main__":
    sys.exit(main())
