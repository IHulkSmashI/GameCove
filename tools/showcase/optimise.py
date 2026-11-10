#!/usr/bin/env python3
"""README copies of screenshots: 1600 px wide WebP (quality 82; GitHub shows
it inline, and it's smaller and cleaner than a palette PNG). --png also writes
a dithered 256-colour PNG next to it (octree palette, so small UI colours such
as the button glyphs stay true) for places that can't show WebP.

    python3 -I tools/showcase/optimise.py [--png] SRC.png=DEST_BASE [...]
    (DEST_BASE without extension, or ending in .png / .webp)
"""

import os
import sys

from PIL import Image

WIDTH = 1600


def one(src, dest, png=False):
    base = dest[:-5] if dest.endswith(".webp") else (dest[:-4] if dest.endswith(".png") else dest)
    if not os.path.exists(src):
        print("missing " + src)
        return
    im = Image.open(src).convert("RGB")
    if im.width > WIDTH:
        im = im.resize((WIDTH, round(im.height * WIDTH / im.width)), Image.LANCZOS)
    im.save(base + ".webp", "WEBP", quality=82, method=6)
    line = "%-40s webp %4d KB" % (os.path.basename(base), os.path.getsize(base + ".webp") // 1024)
    if png:
        q = im.quantize(colors=256, method=Image.Quantize.FASTOCTREE, dither=Image.Dither.FLOYDSTEINBERG)
        q.save(base + ".png", optimize=True)
        line += "  png %4d KB" % (os.path.getsize(base + ".png") // 1024)
    print(line)


def main():
    png = "--png" in sys.argv
    for arg in sys.argv[1:]:
        if arg == "--png":
            continue
        src, _, dest = arg.partition("=")
        one(src, dest, png)


if __name__ == "__main__":
    main()
