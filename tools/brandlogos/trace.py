#!/usr/bin/env python3
"""Trace an official raster logo into a single-colour SVG with potrace (potracer).

The ink mask comes from alpha (transparent PNGs), dark or light pixels, or a
colour distance to --color. The image is upscaled (--scale, Lanczos) before
thresholding so curves are smooth, then potrace fits Bezier curves. Specks
smaller than --turdsize (in upscaled px) are dropped. The output viewBox is the
tight ink box in original-pixel units (kept proportions).

usage: trace.py IN.png OUT.svg --title Brand [--ink alpha|dark|light|color]
       [--color RRGGBB --tol 80] [--scale 4] [--turdsize 40] [--alphamax 1.0]
       [--opttolerance 0.2] [--crop x0,y0,x1,y1]
"""
import argparse

import numpy as np
import potrace
from PIL import Image


def mask_of(img, ink, color, tol):
    a = np.asarray(img.convert("RGBA")).astype(float)
    alpha = a[..., 3] / 255.0
    lum = 0.299 * a[..., 0] + 0.587 * a[..., 1] + 0.114 * a[..., 2]
    if ink == "alpha":
        return alpha
    if ink == "dark":
        return alpha * (1 - lum / 255.0)
    if ink == "light":
        return alpha * (lum / 255.0)
    c = np.array([int(color[i:i + 2], 16) for i in (0, 2, 4)], float)
    d = np.sqrt(((a[..., :3] - c) ** 2).sum(-1))
    return alpha * np.clip(1 - d / tol, 0, 1)


def fmt(v):
    s = "%.2f" % v
    s = s.rstrip("0").rstrip(".")
    return "0" if s in ("-0", "") else s


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("src")
    ap.add_argument("dst")
    ap.add_argument("--title", required=True)
    ap.add_argument("--ink", default="alpha", choices=["alpha", "dark", "light", "color"])
    ap.add_argument("--color", default="000000")
    ap.add_argument("--tol", type=float, default=80)
    ap.add_argument("--scale", type=float, default=4)
    ap.add_argument("--turdsize", type=int, default=40)
    ap.add_argument("--alphamax", type=float, default=1.0)
    ap.add_argument("--opttolerance", type=float, default=0.2)
    ap.add_argument("--crop")
    ap.add_argument("--level", type=float, default=0.5, help="ink threshold 0..1")
    ap.add_argument("--mask-out", help="write the binary mask PNG used (original size)")
    a = ap.parse_args()
    img = Image.open(a.src).convert("RGBA")
    if a.crop:
        img = img.crop(tuple(int(v) for v in a.crop.split(",")))
    m = mask_of(img, a.ink, a.color, a.tol)
    mi = Image.fromarray((m * 255).astype(np.uint8))
    if a.mask_out:
        mi.point(lambda v: 255 if v > a.level * 255 else 0).save(a.mask_out)
    W, H = int(img.width * a.scale), int(img.height * a.scale)
    big = np.asarray(mi.resize((W, H), Image.LANCZOS)) > a.level * 255
    # potracer treats False (dark) as ink, like a 1-bit image: pass the inverse.
    bm = potrace.Bitmap(~big)
    plist = bm.trace(turdsize=a.turdsize, turnpolicy=potrace.POTRACE_TURNPOLICY_MINORITY,
                     alphamax=a.alphamax, opticurve=True, opttolerance=a.opttolerance)
    s = 1.0 / a.scale
    ys, xs = np.nonzero(big)
    x0, y0 = xs.min() * s, ys.min() * s
    x1, y1 = (xs.max() + 1) * s, (ys.max() + 1) * s

    def P(p):
        return "%s %s" % (fmt(p.x * s - x0), fmt(p.y * s - y0))

    d = []
    for curve in plist:
        d.append("M" + P(curve.start_point))
        for seg in curve.segments:
            if seg.is_corner:
                d.append("L" + P(seg.c) + "L" + P(seg.end_point))
            else:
                d.append("C" + P(seg.c1) + " " + P(seg.c2) + " " + P(seg.end_point))
        d.append("Z")
    svg = ('<svg xmlns="http://www.w3.org/2000/svg" role="img" viewBox="0 0 %s %s">'
           '<title>%s</title><path fill-rule="evenodd" d="%s"/></svg>\n') % (
        fmt(x1 - x0), fmt(y1 - y0), a.title, "".join(d))
    open(a.dst, "w").write(svg)
    print("wrote %s: %d curves, %d bytes, viewBox %s x %s, box %s,%s,%s,%s" % (a.dst, len(plist), len(svg), fmt(x1 - x0), fmt(y1 - y0), x0, y0, x1, y1))


if __name__ == "__main__":
    main()
