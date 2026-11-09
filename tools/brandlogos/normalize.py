#!/usr/bin/env python3
"""Normalise an official single-colour SVG for GameCove's mono brand logos.

Geometry is copied unchanged. Only presentation is removed so the UI can tint
the logo with one flat colour (same shape as a Simple Icons file):
fill/stroke/class/style/id/data-* attributes, <title>, <desc>, <style>, <defs>
with only styles, metadata. Adds a viewBox from width/height when missing and
drops width/height. Optionally keeps only elements whose original fill is in
--keep-fill (to split a two-colour logo) and wraps the result in a
role="img" <svg> with a <title>.

usage: normalize.py IN.svg OUT.svg --title "Brand" [--keep-fill '#9146ff' ...]
       [--drop-fill '#fff'] [--viewbox 'x y w h']
"""
import argparse
import re
import sys
from lxml import etree

SVG = "http://www.w3.org/2000/svg"
SHAPES = {"path", "polygon", "rect", "circle", "ellipse", "polyline", "line", "g"}


def local(t):
    return t.split("}")[-1] if isinstance(t, str) else ""


def css_fills(root):
    """class name -> fill from <style> blocks."""
    out = {}
    for st in root.iter("{%s}style" % SVG, "style"):
        for m in re.finditer(r"\.([\w-]+)\s*\{[^}]*?fill\s*:\s*([^;}\s]+)", st.text or ""):
            out[m.group(1)] = m.group(2).lower()
    return out


def fill_of(el, classes, inherited):
    f = el.get("fill")
    st = el.get("style") or ""
    m = re.search(r"fill\s*:\s*([^;]+)", st)
    if m:
        f = m.group(1).strip()
    for c in (el.get("class") or "").split():
        if c in classes:
            f = classes[c]
    return (f or inherited or "#000000").lower()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("src")
    ap.add_argument("dst")
    ap.add_argument("--title", required=True)
    ap.add_argument("--keep-fill", action="append", default=[])
    ap.add_argument("--drop-fill", action="append", default=[])
    ap.add_argument("--viewbox")
    a = ap.parse_args()
    keep = {k.lower() for k in a.keep_fill}
    drop = {k.lower() for k in a.drop_fill}
    root = etree.parse(a.src, etree.XMLParser(remove_comments=True)).getroot()
    classes = css_fills(root)
    vb = a.viewbox or root.get("viewBox")
    if not vb:
        w = float(re.sub(r"[a-z]+$", "", root.get("width")))
        h = float(re.sub(r"[a-z]+$", "", root.get("height")))
        vb = "0 0 %g %g" % (w, h)
    out = etree.Element("{%s}svg" % SVG, nsmap={None: SVG})
    out.set("role", "img")
    out.set("viewBox", vb)
    t = etree.SubElement(out, "{%s}title" % SVG)
    t.text = a.title

    def walk(src, dst, inherited):
        for el in src:
            name = local(el.tag)
            if name not in SHAPES:
                continue
            f = fill_of(el, classes, inherited)
            if name == "g":
                g = etree.SubElement(dst, "{%s}g" % SVG)
                if el.get("transform"):
                    g.set("transform", el.get("transform"))
                walk(el, g, f)
                if len(g) == 0:
                    dst.remove(g)
                continue
            if f in drop or (keep and f not in keep) or f == "none":
                continue
            n = etree.SubElement(dst, "{%s}%s" % (SVG, name))
            for k, v in el.attrib.items():
                lk = local(k)
                if lk in ("fill", "stroke", "class", "style", "id", "opacity") or lk.startswith("data-"):
                    continue
                n.set(lk, v)
            if el.get("fill-rule") is None and "evenodd" in (el.get("style") or ""):
                n.set("fill-rule", "evenodd")

    walk(root, out, None)
    # flatten groups without transforms
    for g in list(out.iter("{%s}g" % SVG)):
        if g.get("transform") is None and g.getparent() is not None:
            p = g.getparent()
            i = p.index(g)
            for c in list(g):
                p.insert(i, c)
                i += 1
            p.remove(g)
    s = etree.tostring(out, encoding="unicode")
    s = re.sub(r">\s+<", "><", s)
    open(a.dst, "w").write(s + "\n")
    print("wrote", a.dst, len(s), "bytes,", len(out) - 1, "shapes")


if __name__ == "__main__":
    sys.exit(main())
