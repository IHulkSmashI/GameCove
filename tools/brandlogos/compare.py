#!/usr/bin/env python3
"""Overlap score between a reference image (PNG alpha/dark pixels or SVG) and an SVG.

Both are rendered/cropped to their ink bounding box, scaled to the same size and
binarised; score = IoU of ink pixels. Also writes a diff PNG (red = only in ref,
blue = only in candidate).

usage: compare.py REF(.png|.svg) CAND.svg [--width 1600] [--diff out.png] [--ink alpha|dark]
"""
import argparse
import io
import sys

import cairosvg
import numpy as np
from PIL import Image


def ink_mask(img, mode, level=127):
    img = img.convert("RGBA")
    a = np.asarray(img).astype(float)
    if mode == "alpha":
        m = a[..., 3] > 127
    elif mode == "light":
        lum = (0.299 * a[..., 0] + 0.587 * a[..., 1] + 0.114 * a[..., 2])
        m = (a[..., 3] > 127) & (lum > level)
    else:
        lum = (0.299 * a[..., 0] + 0.587 * a[..., 1] + 0.114 * a[..., 2])
        m = (a[..., 3] > 127) & (lum < level)
    return m


def load(path, width, mode, level=127):
    if path.endswith(".svg"):
        png = cairosvg.svg2png(url=path, output_width=width * 2)
        img = Image.open(io.BytesIO(png))
        mode = "alpha"
    else:
        img = Image.open(path)
    m = ink_mask(img, mode, level)
    ys, xs = np.nonzero(m)
    m = m[ys.min():ys.max() + 1, xs.min():xs.max() + 1]
    return m


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("ref")
    ap.add_argument("cand")
    ap.add_argument("--width", type=int, default=1600)
    ap.add_argument("--diff")
    ap.add_argument("--ink", default="alpha", choices=["alpha", "dark", "light"])
    ap.add_argument("--level", type=float, default=127)
    a = ap.parse_args()
    r = load(a.ref, a.width, a.ink, a.level)
    c = load(a.cand, a.width, "alpha")
    w = a.width
    h = max(1, round(r.shape[0] * w / r.shape[1]))
    rs = np.asarray(Image.fromarray(r.astype(np.uint8) * 255).resize((w, h), Image.LANCZOS)) > 127
    cs = np.asarray(Image.fromarray(c.astype(np.uint8) * 255).resize((w, h), Image.LANCZOS)) > 127
    inter = (rs & cs).sum()
    union = (rs | cs).sum()
    iou = inter / union
    aspect_r = r.shape[1] / r.shape[0]
    aspect_c = c.shape[1] / c.shape[0]
    print("IoU %.4f  aspect ref %.4f cand %.4f (%.2f%%)" % (iou, aspect_r, aspect_c, 100 * abs(aspect_c / aspect_r - 1)))
    if a.diff:
        d = np.full((h, w, 3), 255, np.uint8)
        d[rs & cs] = (40, 40, 40)
        d[rs & ~cs] = (230, 30, 30)
        d[cs & ~rs] = (30, 60, 230)
        Image.fromarray(d).save(a.diff)
    return 0


if __name__ == "__main__":
    sys.exit(main())
