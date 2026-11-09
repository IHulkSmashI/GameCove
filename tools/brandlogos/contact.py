#!/usr/bin/env python3
"""Contact sheet of every bundled brand logo on dark and light backgrounds.

Mono logos are tinted the way the UI does it (fill on the <svg> root): white
on dark, near-black on light, plus a third column in the brand's own hex.

usage: contact.py REPO_ROOT OUT.png
"""
import io
import json
import sys

import cairosvg
from PIL import Image, ImageDraw, ImageFont

root, out = sys.argv[1], sys.argv[2]
table = json.load(open(root + "/app/data/brand_logos.json"))["brands"]
CELL_W, CELL_H, LOGO_H, PAD = 360, 120, 64, 16
cols = [("dark", (24, 26, 32), "FFFFFF"), ("light", (240, 240, 236), "16181D"), ("brand", (128, 128, 128), None)]
keys = [k for k, e in table.items() if e.get("file")]
W = 220 + CELL_W * len(cols)
H = 40 + CELL_H * len(keys)
sheet = Image.new("RGB", (W, H), (60, 60, 60))
d = ImageDraw.Draw(sheet)
try:
    font = ImageFont.truetype("/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf", 18)
    small = ImageFont.truetype("/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf", 13)
except OSError:
    font = small = ImageFont.load_default()
for i, (label, _, _) in enumerate(cols):
    d.text((220 + i * CELL_W + 10, 10), label, fill=(230, 230, 230), font=font)


def render(svg, tint, h):
    if tint:
        svg = svg.replace("<svg ", '<svg fill="#%s" ' % tint, 1)
    png = cairosvg.svg2png(bytestring=svg.encode(), output_height=h * 2)
    im = Image.open(io.BytesIO(png)).convert("RGBA")
    im = im.resize((max(1, im.width // 2), h), Image.LANCZOS)
    if im.width > CELL_W - 2 * PAD:
        im = im.resize((CELL_W - 2 * PAD, max(1, round(h * (CELL_W - 2 * PAD) / im.width))), Image.LANCZOS)
    return im


for r, k in enumerate(keys):
    e = table[k]
    y = 40 + r * CELL_H
    svg = open(root + "/app/" + e["file"].replace("res://", "")).read()
    d.text((12, y + 40), e["name"], fill=(240, 240, 240), font=font)
    d.text((12, y + 66), "%s%s" % ("mono " if e.get("mono") else "colour ", ("#" + e["hex"]) if e.get("hex") else ""),
           fill=(190, 190, 190), font=small)
    for i, (label, bg, tint) in enumerate(cols):
        x = 220 + i * CELL_W
        d.rectangle([x + 2, y + 2, x + CELL_W - 2, y + CELL_H - 2], fill=bg)
        t = tint if e.get("mono") else None
        if label == "brand" and e.get("mono"):
            t = e.get("hex") or "000000"
        im = render(svg, t, LOGO_H)
        sheet.paste(im, (x + (CELL_W - im.width) // 2, y + (CELL_H - im.height) // 2), im)
sheet.save(out)
print("wrote", out, sheet.size, len(keys), "logos")
