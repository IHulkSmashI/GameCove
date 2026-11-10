#!/usr/bin/env python3
"""README copies of screenshots: 1600 px wide, as a dithered 256-colour PNG
(octree palette, so small UI colours such as the button glyphs stay true; a
few hundred KB) and a WebP next to it (smaller and cleaner; GitHub shows both).

    python3 -I tools/showcase/optimise.py SRC.png=DEST_BASE [...]
    (DEST_BASE without extension, or ending in .png)
"""

import os
import sys

from PIL import Image

WIDTH = 1600


def one(src, dest):
    base = dest[:-4] if dest.endswith(".png") else dest
    if not os.path.exists(src):
        print("missing " + src)
        return
    im = Image.open(src).convert("RGB")
    if im.width > WIDTH:
        im = im.resize((WIDTH, round(im.height * WIDTH / im.width)), Image.LANCZOS)
    im.save(base + ".webp", "WEBP", quality=82, method=6)
    q = im.quantize(colors=256, method=Image.Quantize.FASTOCTREE, dither=Image.Dither.FLOYDSTEINBERG)
    q.save(base + ".png", optimize=True)
    print("%-40s png %4d KB  webp %4d KB" % (os.path.basename(base), os.path.getsize(base + ".png") // 1024,
                                          os.path.getsize(base + ".webp") // 1024))


def main():
    for arg in sys.argv[1:]:
        src, _, dest = arg.partition("=")
        one(src, dest)


if __name__ == "__main__":
    main()
