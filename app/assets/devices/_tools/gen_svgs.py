#!/usr/bin/env python3
"""Generates GameCove's button glyphs and device pictures (original drawings).

    python3 -I app/assets/devices/_tools/gen_svgs.py app/assets/devices

Everything is drawn from simple shapes; letters use a small stroke font below
(Godot's SVG importer doesn't render <text>). No brand logos or wordmarks.
GPL-3.0-or-later, like the rest of GameCove.
"""
import os
import sys

OUT = sys.argv[1]

TEXT = "#E8ECF1"
QUIET = "#9AA4B0"
BG = "#12161C"
RAISED = "#1F2630"
BODY = "#262E3A"
EDGE = "#5A6678"
SCREEN = "#0B0E13"
ACCENT = "#4FD1C5"

# ---------------------------------------------------------------- stroke font
# Glyphs on a 4 x 6 grid (x right, y down). Each is a list of polylines.
FONT = {
    "A": [[(0, 6), (2, 0), (4, 6)], [(0.7, 4), (3.3, 4)]],
    "B": [[(0, 0), (0, 6), (3, 6), (4, 5), (4, 4), (3, 3), (0, 3)], [(0, 0), (3, 0), (3.8, 0.8), (3.8, 2.2), (3, 3)]],
    "C": [[(4, 0.8), (3, 0), (1, 0), (0, 1), (0, 5), (1, 6), (3, 6), (4, 5.2)]],
    "L": [[(0, 0), (0, 6), (4, 6)]],
    "M": [[(0, 6), (0, 0), (2, 3.5), (4, 0), (4, 6)]],
    "P": [[(0, 6), (0, 0), (3, 0), (4, 1), (4, 2), (3, 3), (0, 3)]],
    "R": [[(0, 6), (0, 0), (3, 0), (4, 1), (4, 2), (3, 3), (0, 3)], [(2, 3), (4, 6)]],
    "S": [[(4, 0.8), (3, 0), (1, 0), (0, 1), (0, 2), (1, 3), (3, 3), (4, 4), (4, 5), (3, 6), (1, 6), (0, 5.2)]],
    "T": [[(0, 0), (4, 0)], [(2, 0), (2, 6)]],
    "X": [[(0, 0), (4, 6)], [(4, 0), (0, 6)]],
    "Y": [[(0, 0), (2, 3), (4, 0)], [(2, 3), (2, 6)]],
    "1": [[(1, 1), (2, 0), (2, 6)], [(1, 6), (3, 6)]],
    "2": [[(0, 1), (1, 0), (3, 0), (4, 1), (4, 2), (0, 6), (4, 6)]],
    "3": [[(0, 0.6), (1, 0), (3, 0), (4, 1), (4, 2), (3, 3), (1.5, 3)], [(3, 3), (4, 4), (4, 5), (3, 6), (1, 6), (0, 5.4)]],
    "4": [[(3, 6), (3, 0), (0, 4), (4, 4)]],
    "5": [[(4, 0), (0, 0), (0, 3), (3, 3), (4, 4), (4, 5), (3, 6), (0, 6)]],
}


def text_path(s, cx, cy, h, color, width=None):
    """Centered stroke text; h = cap height in px."""
    k = h / 6.0
    adv = 5.4 * k
    total = adv * len(s) - 1.4 * k
    x0 = cx - total / 2
    y0 = cy - h / 2
    d = []
    for i, ch in enumerate(s):
        for line in FONT[ch]:
            pts = [(x0 + i * adv + x * k, y0 + y * k) for x, y in line]
            d.append("M" + " L".join("%.2f %.2f" % p for p in pts))
    w = width if width else max(1.6, h * 0.17)
    return '<path d="%s" fill="none" stroke="%s" stroke-width="%.2f" stroke-linecap="round" stroke-linejoin="round"/>' % (
        " ".join(d), color, w)


def svg(w, h, body, extra=""):
    return ('<svg xmlns="http://www.w3.org/2000/svg" width="%d" height="%d" viewBox="0 0 %d %d"%s>\n%s\n</svg>\n'
            % (w, h, w, h, extra, body))


def write(rel, content):
    p = os.path.join(OUT, rel)
    os.makedirs(os.path.dirname(p), exist_ok=True)
    with open(p, "w") as f:
        f.write(content)


# ---------------------------------------------------------------- glyphs (64 x 64)
def disc(label, h=26):
    return svg(64, 64, '<circle cx="32" cy="32" r="28" fill="%s"/>\n%s' % (TEXT, text_path(label, 32, 32, h, BG)))


def pill(label, w=60, h=20):
    return svg(64, 64, '<rect x="%d" y="%d" width="%d" height="%d" rx="12" fill="%s"/>\n%s' % (
        (64 - w) // 2, 14, w, 36, TEXT, text_path(label, 32, 32, h, BG)))


def bumper(label, top=True):
    shape = ('<path d="M6 46 L6 28 Q6 16 22 16 L42 16 Q58 16 58 28 L58 46 Z" fill="%s"/>' % TEXT) if top else \
        ('<path d="M10 52 L10 22 Q10 8 32 8 Q54 8 54 22 L54 52 Z" fill="%s"/>' % TEXT)
    return svg(64, 64, shape + "\n" + text_path(label, 32, 33 if top else 32, 16, BG))


def stick(label):
    return svg(64, 64, '<circle cx="32" cy="32" r="28" fill="none" stroke="%s" stroke-width="5"/>\n<circle cx="32" cy="32" r="18" fill="%s"/>\n%s' % (
        TEXT, TEXT, text_path(label, 32, 32, 13, BG)))


def dpad(highlight=None):
    arms = {"up": (24, 6, 16, 22), "down": (24, 36, 16, 22), "left": (6, 24, 22, 16), "right": (36, 24, 22, 16)}
    parts = ['<rect x="24" y="24" width="16" height="16" fill="%s"/>' % (TEXT if highlight is None else QUIET)]
    for k, (x, y, w, h) in arms.items():
        c = TEXT if highlight in (None, k) else QUIET
        parts.append('<rect x="%d" y="%d" width="%d" height="%d" rx="3" fill="%s"/>' % (x, y, w, h, c))
    return svg(64, 64, "\n".join(parts))


def view_icon():
    return svg(64, 64, '<circle cx="32" cy="32" r="28" fill="%s"/>\n<rect x="18" y="20" width="18" height="14" rx="2" fill="none" stroke="%s" stroke-width="3.5"/>\n<rect x="26" y="28" width="18" height="14" rx="2" fill="%s" stroke="%s" stroke-width="3.5"/>' % (
        TEXT, BG, TEXT, BG))


def menu_icon():
    lines = "".join('<path d="M19 %d H45" stroke="%s" stroke-width="4" stroke-linecap="round"/>' % (y, BG) for y in (23, 32, 41))
    return svg(64, 64, '<circle cx="32" cy="32" r="28" fill="%s"/>\n%s' % (TEXT, lines))


def ring():
    return svg(64, 64, '<circle cx="32" cy="32" r="28" fill="%s"/>\n<circle cx="32" cy="32" r="15" fill="none" stroke="%s" stroke-width="5"/>' % (TEXT, BG))


def icon(inner, shape="circle"):
    base = '<circle cx="32" cy="32" r="28" fill="%s"/>' % TEXT if shape == "circle" else \
        '<rect x="4" y="4" width="56" height="56" rx="14" fill="%s"/>' % TEXT
    return svg(64, 64, base + "\n" + inner)


S = BG  # stroke colour inside icons
GLYPHS = {
    # xbox-style set
    "xbox/a": disc("A"), "xbox/b": disc("B"), "xbox/x": disc("X"), "xbox/y": disc("Y"),
    "xbox/lb": bumper("LB"), "xbox/rb": bumper("RB"), "xbox/lt": bumper("LT", False), "xbox/rt": bumper("RT", False),
    "xbox/ls": stick("LS"), "xbox/rs": stick("RS"), "xbox/view": view_icon(), "xbox/menu": menu_icon(),
    "xbox/dpad": dpad(), "xbox/dpad_up": dpad("up"), "xbox/dpad_down": dpad("down"),
    "xbox/dpad_left": dpad("left"), "xbox/dpad_right": dpad("right"), "xbox/guide": ring(),
    # Steam Deck set: its own printed labels
    "deck/a": disc("A"), "deck/b": disc("B"), "deck/x": disc("X"), "deck/y": disc("Y"),
    "deck/l1": bumper("L1"), "deck/r1": bumper("R1"), "deck/l2": bumper("L2", False), "deck/r2": bumper("R2", False),
    "deck/l3": stick("L3"), "deck/r3": stick("R3"), "deck/view": view_icon(), "deck/menu": menu_icon(),
    "deck/dpad": dpad(), "deck/dpad_up": dpad("up"), "deck/dpad_down": dpad("down"),
    "deck/dpad_left": dpad("left"), "deck/dpad_right": dpad("right"),
    "deck/steam": svg(64, 64, '<rect x="2" y="14" width="60" height="36" rx="10" fill="%s"/>\n%s' % (TEXT, text_path("S", 32, 32, 18, BG))),
    "deck/qam": svg(64, 64, '<rect x="2" y="14" width="60" height="36" rx="10" fill="%s"/>\n' % TEXT +
                    "".join('<circle cx="%d" cy="32" r="4.5" fill="%s"/>' % (x, BG) for x in (18, 32, 46))),
    "deck/trackpad_l": svg(64, 64, '<rect x="8" y="8" width="48" height="48" rx="12" fill="none" stroke="%s" stroke-width="5"/>\n%s' % (TEXT, text_path("L", 32, 32, 18, TEXT))),
    "deck/trackpad_r": svg(64, 64, '<rect x="8" y="8" width="48" height="48" rx="12" fill="none" stroke="%s" stroke-width="5"/>\n%s' % (TEXT, text_path("R", 32, 32, 18, TEXT))),
    # special buttons: abstract shapes, never a maker's logo
    "special/house": icon('<path d="M17 33 L32 19 L47 33 M21 30 V45 H43 V30" fill="none" stroke="%s" stroke-width="4" stroke-linejoin="round" stroke-linecap="round"/>' % S),
    "special/sliders": icon("".join('<path d="M16 %d H48" stroke="%s" stroke-width="3.5" stroke-linecap="round"/><circle cx="%d" cy="%d" r="5" fill="%s"/>' % (y, S, x, y, S) for y, x in ((22, 24), (32, 40), (42, 28)))),
    "special/keyboard": icon('<rect x="13" y="21" width="38" height="22" rx="4" fill="none" stroke="%s" stroke-width="3.5"/>' % S +
                             "".join('<rect x="%d" y="%d" width="4" height="4" fill="%s"/>' % (x, y, S) for x in (18, 25, 32, 39) for y in (26,)) +
                             '<rect x="21" y="34" width="22" height="4" fill="%s"/>' % S),
    "special/camera": icon('<rect x="14" y="22" width="36" height="24" rx="4" fill="none" stroke="%s" stroke-width="3.5"/><path d="M24 22 L27 17 H37 L40 22" fill="none" stroke="%s" stroke-width="3.5" stroke-linejoin="round"/><circle cx="32" cy="34" r="6" fill="none" stroke="%s" stroke-width="3.5"/>' % (S, S, S)),
    "special/dots": icon("".join('<circle cx="%d" cy="32" r="4.5" fill="%s"/>' % (x, S) for x in (19, 32, 45))),
    "special/guide_ring": ring(),
    "special/command_center": icon("".join('<rect x="%d" y="%d" width="11" height="11" rx="2" fill="%s"/>' % (x, y, S) for x in (19, 34) for y in (19, 34)), "square"),
    "special/armoury_crate": icon('<path d="M32 14 L50 32 L32 50 L14 32 Z" fill="none" stroke="%s" stroke-width="4" stroke-linejoin="round"/><circle cx="32" cy="32" r="4" fill="%s"/>' % (S, S), "square"),
    "special/library": icon("".join('<rect x="%d" y="18" width="7" height="28" rx="2" fill="%s"/>' % (x, S) for x in (18, 28)) +
                            '<rect x="38" y="19" width="7" height="27" rx="2" fill="%s" transform="rotate(-14 41 46)"/>' % S),
    "special/legion_l": icon(text_path("L", 32, 32, 24, S)),
    "special/legion_r": icon(text_path("R", 32, 32, 24, S)),
    "special/view_desktop": view_icon(),
    "special/hamburger": menu_icon(),
    "special/msi_m": icon(text_path("M", 32, 32, 24, S), "square"),
    "special/quick_settings": icon("".join('<path d="M%d 16 V48" stroke="%s" stroke-width="3.5" stroke-linecap="round"/><circle cx="%d" cy="%d" r="5" fill="%s"/>' % (x, S, x, y, S) for x, y in ((22, 26), (32, 40), (42, 22))), "square"),
    "special/turbo": icon('<path d="M35 12 L19 35 H31 L28 52 L45 28 H33 Z" fill="%s" stroke="%s" stroke-width="2" stroke-linejoin="round"/>' % (S, S)),
    "special/home_dot": icon('<circle cx="32" cy="32" r="16" fill="none" stroke="%s" stroke-width="4"/><circle cx="32" cy="32" r="7" fill="%s"/>' % (S, S)),
    "special/aya": icon('<circle cx="32" cy="34" r="15" fill="none" stroke="%s" stroke-width="4"/><circle cx="32" cy="16" r="4" fill="%s"/>' % (S, S)),
    "special/swap": icon('<path d="M18 26 H44 L38 20 M46 38 H20 L26 44" fill="none" stroke="%s" stroke-width="4" stroke-linecap="round" stroke-linejoin="round"/>' % S),
    "generic/button": svg(64, 64, '<circle cx="32" cy="32" r="28" fill="none" stroke="%s" stroke-width="5"/>' % TEXT),
}
for label in ["L4", "L5", "R4", "R5", "M1", "M2", "M3", "Y1", "Y2", "Y3", "LC", "RC", "T", "L", "R", "P1", "P2", "P3"]:
    GLYPHS["paddle/" + label.lower()] = pill(label, w=60 if len(label) > 1 else 44)

for name, content in GLYPHS.items():
    write("glyphs/%s.svg" % name, content)


# ---------------------------------------------------------------- device pictures (480 x 260 front view)
# Parts carry ids named after InputPlumber capabilities so a controller page can
# light them up: btn-South, btn-Guide, btn-QuickAccess, btn-LeftPaddle1,
# axis-LeftStick (group with btn-LeftStick), btn-DPad (group with btn-DPadUp...),
# btn-LeftBumper, btn-LeftTrigger, pad-Left / pad-Right (trackpads),
# dial-Left / dial-Right, part-screen, part-body.
class Art:
    def __init__(self, w=480, h=260):
        self.w, self.h = w, h
        self.parts = []

    def add(self, s):
        self.parts.append(s)

    def body(self, d):
        self.add('<path id="part-body" d="%s" fill="%s" stroke="%s" stroke-width="2.5" stroke-linejoin="round"/>' % (d, BODY, EDGE))

    def rect_body(self, x, y, w, h, r, pid="part-body"):
        self.add('<rect id="%s" x="%g" y="%g" width="%g" height="%g" rx="%g" fill="%s" stroke="%s" stroke-width="2.5"/>' % (pid, x, y, w, h, r, BODY, EDGE))

    def screen(self, x, y, w, h, r=6, pid="part-screen"):
        self.add('<rect id="%s" x="%g" y="%g" width="%g" height="%g" rx="%g" fill="%s" stroke="%s" stroke-width="2"/>' % (pid, x, y, w, h, r, SCREEN, RAISED))
        self.add('<path d="M%g %g L%g %g" stroke="%s" stroke-width="1.2" opacity="0.5"/>' % (x + w * 0.62, y + 8, x + w * 0.80, y + 8, QUIET))

    def stick(self, cx, cy, side, r=17):
        cap = "Left" if side == "L" else "Right"
        self.add('<g id="axis-%sStick"><circle cx="%g" cy="%g" r="%g" fill="%s" stroke="%s" stroke-width="2"/>'
                 '<circle id="btn-%sStick" cx="%g" cy="%g" r="%g" fill="%s" stroke="%s" stroke-width="1.5"/></g>'
                 % (cap, cx, cy, r, RAISED, EDGE, cap, cx, cy, r * 0.62, BODY, QUIET))

    def dial(self, cx, cy, side, r=24):
        self.add('<circle id="dial-%s" cx="%g" cy="%g" r="%g" fill="none" stroke="%s" stroke-width="3" stroke-dasharray="3 3"/>' % (side, cx, cy, r, QUIET))

    def dpad(self, cx, cy, s=11):
        a = s * 1.25
        parts = ['<g id="btn-DPad">']
        for name, (dx, dy, w, h) in {"Up": (-s / 2, -s / 2 - a, s, a), "Down": (-s / 2, s / 2, s, a),
                                     "Left": (-s / 2 - a, -s / 2, a, s), "Right": (s / 2, -s / 2, a, s)}.items():
            parts.append('<rect id="btn-DPad%s" x="%g" y="%g" width="%g" height="%g" rx="2" fill="%s" stroke="%s" stroke-width="1.2"/>'
                         % (name, cx + dx, cy + dy, w, h, RAISED, QUIET))
        parts.append('<rect x="%g" y="%g" width="%g" height="%g" fill="%s"/></g>' % (cx - s / 2, cy - s / 2, s, s, RAISED))
        self.add("".join(parts))

    def face(self, cx, cy, gap=15, r=7.5, labels=("Y", "B", "A", "X")):
        pos = {"North": (0, -gap), "East": (gap, 0), "South": (0, gap), "West": (-gap, 0)}
        for (name, (dx, dy)), lab in zip(pos.items(), labels):
            self.add('<g id="btn-%s"><circle cx="%g" cy="%g" r="%g" fill="%s" stroke="%s" stroke-width="1.5"/>%s</g>'
                     % (name, cx + dx, cy + dy, r, RAISED, QUIET, text_path(lab, cx + dx, cy + dy, r * 0.95, TEXT, 1.3)))

    def small(self, cap, cx, cy, r=5, shape="circle", label=None):
        if shape == "circle":
            s = '<circle cx="%g" cy="%g" r="%g" fill="%s" stroke="%s" stroke-width="1.3"/>' % (cx, cy, r, RAISED, QUIET)
        else:
            s = '<rect x="%g" y="%g" width="%g" height="%g" rx="%g" fill="%s" stroke="%s" stroke-width="1.3"/>' % (cx - r * 1.3, cy - r * 0.8, r * 2.6, r * 1.6, r * 0.6, RAISED, QUIET)
        if label:
            s += text_path(label, cx, cy, r * 0.9, TEXT, 1.1)
        self.add('<g id="btn-%s">%s</g>' % (cap, s))

    def pad(self, x, y, w, h, side):
        self.add('<rect id="pad-%s" x="%g" y="%g" width="%g" height="%g" rx="8" fill="%s" stroke="%s" stroke-width="1.5"/>' % (side, x, y, w, h, RAISED, QUIET))

    def shoulders(self, lx, rx, y, w=54):
        for cap, x in (("LeftTrigger", lx), ("RightTrigger", rx - w)):
            self.add('<rect id="btn-%s" x="%g" y="%g" width="%g" height="10" rx="5" fill="%s" stroke="%s" stroke-width="1.3"/>' % (cap, x, y - 18, w, RAISED, QUIET))
        for cap, x in (("LeftBumper", lx + 6), ("RightBumper", rx - w + 6)):
            self.add('<rect id="btn-%s" x="%g" y="%g" width="%g" height="7" rx="3.5" fill="%s" stroke="%s" stroke-width="1.3"/>' % (cap, x, y - 6, w - 12, BODY, QUIET))

    def paddles(self, labels, y):
        """Back buttons, drawn under the body as 'seen through' dashed outlines."""
        left = [(c, l) for c, l in labels if c.startswith("Left")]
        right = [(c, l) for c, l in labels if not c.startswith("Left")]
        for group, x0, step in ((left, self.w * 0.28, -40), (right, self.w * 0.72, 40)):
            for i, (cap, lab) in enumerate(group):
                cx = x0 + step * i
                self.add('<g id="btn-%s"><rect x="%g" y="%g" width="34" height="16" rx="8" fill="none" stroke="%s" stroke-width="1.5" stroke-dasharray="4 3"/>%s</g>'
                         % (cap, cx - 17, y, QUIET, text_path(lab.upper(), cx, y + 8, 7, QUIET, 1.1)))

    def render(self, title):
        return svg(self.w, self.h, "<title>%s</title>\n" % title + "\n".join(self.parts))


def classic(a, x0, x1, top, bot, grip=26, sx=None):
    """One-piece body with rounded grips."""
    mid = (top + bot) / 2
    a.body("M%g %g H%g Q%g %g %g %g L%g %g Q%g %g %g %g L%g %g Q%g %g %g %g H%g Q%g %g %g %g L%g %g Q%g %g %g %g L%g %g Q%g %g %g %g Z" % (
        x0 + 40, top, x1 - 40, x1, top, x1, top + 34,
        x1 + 4, bot + grip - 30, x1 + 4, bot + grip, x1 - 46, bot + grip,
        x1 - 80, bot, x1 - 90, bot, x1 - 110, bot,
        x0 + 110, x0 + 90, bot, x0 + 80, bot,
        x0 + 46, bot + grip, x0 - 4, bot + grip, x0 - 4, bot + grip - 30,
        x0, top + 34, x0, top, x0 + 40, top))


ARTS = {}


def std_layout(a, x0, x1, top, bot, scr_w, left="stick-dpad", right="face-stick"):
    cx = (x0 + x1) / 2
    a.screen(cx - scr_w / 2, top + 14, scr_w, (bot - top) - 28 if bot - top < 170 else scr_w * 0.6)
    lc = (x0 + cx - scr_w / 2) / 2
    rc = (x1 + cx + scr_w / 2) / 2
    if left == "stick-dpad":
        a.stick(lc, top + 46, "L"); a.dpad(lc, top + 112)
    else:
        a.dpad(lc - 4, top + 46); a.stick(lc + 4, top + 112, "L")
    if right == "face-stick":
        a.face(rc, top + 46); a.stick(rc, top + 112, "R")
    else:
        a.stick(rc - 4, top + 46, "R"); a.face(rc + 4, top + 112)
    return lc, rc, cx


def art_generic():
    a = Art()
    classic(a, 50, 430, 50, 200)
    a.shoulders(58, 422, 50)
    lc, rc, cx = std_layout(a, 50, 430, 50, 200, 230)
    a.small("Select", lc + 24, 186, 4.5, "rect"); a.small("Start", rc - 24, 186, 4.5, "rect")
    a.small("Guide", lc - 22, 186, 6)
    return a.render("Handheld")



# ---------------------------------------------------------------- true-scale device drawings
# Every drawing below uses the same scale, so their sizes compare truthfully:
# 1 mm of the real device = UNITS_PER_MM SVG units (Device.UNITS_PER_MM in GDScript).
# Outline sizes come from "bodies" in app/data/devices.json (maker spec sheets);
# control positions are fractions of that outline, placed from the makers'
# layout descriptions and product views (never traced). No logos or wordmarks.
import json
import math

UNITS_PER_MM = 1.6
MX = 14            # side margin (units)
TOP = 30           # strip above the body for triggers and bumpers
PAD_STRIP = 30     # strip below the body for back buttons
GAP = 30           # clamshells: lid to base (the hinge), holds the shoulders

TABLE = os.path.join(OUT, "..", "..", "data", "devices.json")
BODIES = json.load(open(TABLE))["bodies"]


def num(v):
    return isinstance(v, (int, float)) and not isinstance(v, bool)


def screen_mm(diag, aspect):
    aw, ah = [float(x) for x in aspect.split(":")]
    k = diag * 25.4 / math.hypot(aw, ah)
    return aw * k, ah * k


class Scaled(Art):
    """Art in millimetres: bx, by is the body's top-left corner in units."""

    def __init__(self, w_units, h_units):
        Art.__init__(self, int(math.ceil(w_units)), int(math.ceil(h_units)))
        self.bx = MX
        self.by = TOP

    def X(self, mm):
        return round(self.bx + mm * UNITS_PER_MM, 2)

    def Y(self, mm):
        return round(self.by + mm * UNITS_PER_MM, 2)

    def path_mm(self, cmds):
        """cmds: [("M", x, y), ("Q", cx, cy, x, y), ...] in mm -> path data in units."""
        out = []
        for c in cmds:
            op, vals = c[0], c[1:]
            if op == "H":
                out.append("H%g" % self.X(vals[0]))
            elif op == "Z":
                out.append("Z")
            else:
                pts = ["%g %g" % (self.X(vals[i]), self.Y(vals[i + 1])) for i in range(0, len(vals), 2)]
                out.append(op + " ".join(pts))
        return " ".join(out)


def grip_outline(w, h, rt, rb, hc, gw, inset=0.0):
    """Front outline: straight top, grips reaching the full height at both ends,
    the middle's lower edge at hc * h. All control points stay inside w x h."""
    yc = hc * h
    if hc >= 0.999:
        return [("M", inset + rt, 0), ("H", w - inset - rt), ("Q", w - inset, 0, w - inset, rt),
                ("L", w, h - rb), ("Q", w, h, w - rb, h), ("H", rb), ("Q", 0, h, 0, h - rb),
                ("L", inset, rt), ("Q", inset, 0, inset + rt, 0), ("Z",)]
    t = 0.35 * gw
    rb = min(rb, gw - t - 1)
    return [("M", inset + rt, 0), ("H", w - inset - rt), ("Q", w - inset, 0, w - inset, rt),
            ("L", w, h - rb), ("Q", w, h, w - rb, h), ("L", w - gw + t, h),
            ("C", w - gw, h, w - gw, yc, w - gw - t, yc), ("H", gw + t),
            ("C", gw, yc, gw, h, gw - t, h), ("L", rb, h), ("Q", 0, h, 0, h - rb),
            ("L", inset, rt), ("Q", inset, 0, inset + rt, 0), ("Z",)]


def controller_half(x0, x1, h, side, r_out, r_in=3.0):
    """Detachable controller: rounded on the outer side, square-ish where it meets the tablet."""
    if side == "left":
        return [("M", x1, 0), ("H", x0 + r_out), ("Q", x0, 0, x0, r_out), ("L", x0, h - r_out),
                ("Q", x0, h, x0 + r_out, h), ("H", x1), ("Z",)]
    return [("M", x0, 0), ("H", x1 - r_out), ("Q", x1, 0, x1, r_out), ("L", x1, h - r_out),
            ("Q", x1, h, x1 - r_out, h), ("H", x0), ("Z",)]


def draw(art, spec):
    b = BODIES[art]
    shape = spec.get("shape", "grips")
    h = float(b["h_mm"])
    core = b.get("core_w_mm")
    sw, sh = screen_mm(spec.get("screen_in", b["screen_in"]), b["aspect"])
    # overall width: published, else core + drawn controllers (flagged unverified in devices.json)
    if num(b["w_mm"]):
        w = float(b["w_mm"])
    else:
        w = float(core) + 2 * spec["controller_mm"]
    if shape == "detach":
        core = float(core) if num(core) else sw + 2 * spec.get("bezel_mm", 8)
    paddles = spec.get("paddles", [])
    clam = shape == "clam"
    body_top = (h * UNITS_PER_MM + GAP) if clam else 0
    height = TOP + body_top + h * UNITS_PER_MM + (PAD_STRIP if paddles else 12)
    a = Scaled(w * UNITS_PER_MM + 2 * MX, height + (0 if not clam else 0))
    if clam:
        a.by = 10
    lid_by = a.by
    # ------------------------------------------------ body
    if clam:
        a.add('<path id="part-lid" d="%s" fill="%s" stroke="%s" stroke-width="2.5" stroke-linejoin="round"/>'
              % (a.path_mm(grip_outline(w, h, 7, 7, 1, 0)), BODY, EDGE))
        scy = spec.get("scr_cy", 0.47) * h
        a.screen(a.X(w / 2 - sw / 2), a.Y(scy - sh / 2), sw * UNITS_PER_MM, sh * UNITS_PER_MM, 4)
        a.by = lid_by + h * UNITS_PER_MM + GAP
        a.add('<path id="part-body" d="%s" fill="%s" stroke="%s" stroke-width="2.5" stroke-linejoin="round"/>'
              % (a.path_mm(grip_outline(w, h, spec.get("r_top", 6), spec.get("r_bot", 10), 1, 0)), BODY, EDGE))
    elif shape == "detach":
        x0, x1 = (w - core) / 2, (w + core) / 2
        r_out = spec.get("r_out", 26)
        a.add('<path id="part-controller-left" d="%s" fill="%s" stroke="%s" stroke-width="2.5" stroke-linejoin="round"/>'
              % (a.path_mm(controller_half(0, x0 - 0.6, h, "left", r_out)), BODY, EDGE))
        a.add('<path id="part-controller-right" d="%s" fill="%s" stroke="%s" stroke-width="2.5" stroke-linejoin="round"/>'
              % (a.path_mm(controller_half(x1 + 0.6, w, h, "right", r_out)), BODY, EDGE))
        a.add('<rect id="part-body" x="%g" y="%g" width="%g" height="%g" rx="%g" fill="%s" stroke="%s" stroke-width="2.5"/>'
              % (a.X(x0), a.Y(0), core * UNITS_PER_MM, h * UNITS_PER_MM, 5 * UNITS_PER_MM, BODY, EDGE))
    else:
        inset = (w - float(b["w_top_mm"])) / 2 if num(b.get("w_top_mm")) else 0.0
        hc = spec.get("hc", 1)
        if hc < 0.999:
            # the middle's lower edge sits below the screen (a body never cuts into its panel)
            scy0 = spec.get("scr_cy", 0.45) * h
            hc = min(0.999, max(hc, (scy0 + sh / 2 + 4) / h))
            spec["hc"] = hc
        a.add('<path id="part-body" d="%s" fill="%s" stroke="%s" stroke-width="2.5" stroke-linejoin="round"/>'
              % (a.path_mm(grip_outline(w, h, spec.get("r_top", 18), spec.get("r_bot", 26), hc,
                                        spec.get("gw", 0), inset)), BODY, EDGE))
    # ------------------------------------------------ shoulders (slim strip above the body)
    tw = spec.get("trigger_mm", min(36.0, 0.15 * w))
    ti = spec.get("trigger_in_mm", 0.05 * w)
    ty = a.by - 20
    for cap, x in (("LeftTrigger", ti), ("RightTrigger", w - ti - tw)):
        a.add('<rect id="btn-%s" x="%g" y="%g" width="%g" height="10" rx="5" fill="%s" stroke="%s" stroke-width="1.3"/>'
              % (cap, a.X(x), ty, tw * UNITS_PER_MM, RAISED, QUIET))
    for cap, x in (("LeftBumper", ti + 3), ("RightBumper", w - ti - tw + 3)):
        a.add('<rect id="btn-%s" x="%g" y="%g" width="%g" height="7" rx="3.5" fill="%s" stroke="%s" stroke-width="1.3"/>'
              % (cap, a.X(x), a.by - 8, (tw - 6) * UNITS_PER_MM, BODY, QUIET))
    # ------------------------------------------------ screens and grilles
    if not clam:
        scx = w / 2
        scy = spec.get("scr_cy", 0.5 if spec.get("hc", 1) >= 0.999 else 0.45) * h
        a.screen(a.X(scx - sw / 2), a.Y(scy - sh / 2), sw * UNITS_PER_MM, sh * UNITS_PER_MM, 4)
        sl, sr = scx - sw / 2, scx + sw / 2
    else:
        sl, sr = w / 2 - spec.get("mid_mm", sw) / 2, w / 2 + spec.get("mid_mm", sw) / 2
    if "second_screen" in spec:
        d2, ar2, cy2 = spec["second_screen"]
        w2, h2 = screen_mm(d2, ar2)
        a.screen(a.X(w / 2 - w2 / 2), a.Y(cy2 * h - h2 / 2), w2 * UNITS_PER_MM, h2 * UNITS_PER_MM, 3, "part-screen-2")
    if spec.get("keyboard"):
        kx, ky, kw, kh = spec["keyboard"]
        cols, rows = int(kw // 11), int(kh // 9)
        for r in range(rows):
            for c in range(cols - (r == rows - 1) * 2):
                a.add('<rect x="%g" y="%g" width="%g" height="%g" rx="1.6" fill="%s"/>' % (
                    a.X(kx + c * kw / cols + r * 1.5), a.Y(ky + r * kh / rows), (kw / cols - 1.6) * UNITS_PER_MM,
                    (kh / rows - 1.6) * UNITS_PER_MM, RAISED))
    if spec.get("slider"):
        y = a.Y(spec["slider"] * h)
        a.add('<path d="M%g %g H%g" stroke="%s" stroke-width="1.4" stroke-dasharray="5 4" opacity="0.7"/>'
              % (a.X(sl), y, a.X(sr), QUIET))
    for fx, fy, gw_mm in spec.get("grille", []):
        n = int(gw_mm // 3)
        for i in range(n):
            a.add('<circle cx="%g" cy="%g" r="1" fill="%s" opacity="0.6"/>' % (a.X(fx * w - gw_mm / 2 + i * 3 + 1.5), a.Y(fy * h), QUIET))
    for fx, fy, vw in spec.get("vents", []):
        a.add('<path d="M%g %g H%g M%g %g H%g" stroke="%s" stroke-width="1.6" stroke-linecap="round" opacity="0.5"/>'
              % (a.X(fx * w - vw / 2), a.Y(fy * h), a.X(fx * w + vw / 2), a.X(fx * w - vw / 2), a.Y(fy * h) + 4, a.X(fx * w + vw / 2), QUIET))
    # ------------------------------------------------ main controls
    if shape == "detach":
        lc, rc = (w - core) / 4, w - (w - core) / 4
    else:
        lc, rc = sl / 2, (w + sr) / 2
    lc += spec.get("col_dx", 0)
    rc -= spec.get("col_dx", 0)
    k = spec.get("k", 1.0)
    up, lo = spec.get("fy", (0.3, 0.64))
    S = UNITS_PER_MM
    stick_r, gap, fr, ds = 10.6 * S * k, 9.4 * S * k, 4.7 * S * k, 6.9 * S * k
    layout = spec.get("layout", "xbox")
    if layout == "xbox":
        a.stick(a.X(lc), a.Y(up * h), "L", stick_r); a.dpad(a.X(lc), a.Y(lo * h), ds)
        a.face(a.X(rc), a.Y(up * h), gap, fr); a.stick(a.X(rc), a.Y(lo * h), "R", stick_r)
    elif layout == "inboard":    # D-pad/ABXY outboard, sticks inboard (Steam Deck, ZOTAC Zone)
        dx = spec.get("spread_mm", 14)
        a.dpad(a.X(lc - dx), a.Y(up * h), ds); a.stick(a.X(lc + dx), a.Y(up * h), "L", stick_r)
        a.face(a.X(rc + dx), a.Y(up * h), gap, fr); a.stick(a.X(rc - dx), a.Y(up * h), "R", stick_r)
        if spec.get("dials"):
            a.dial(a.X(lc + dx), a.Y(up * h), "Left", stick_r * 1.3)
            a.dial(a.X(rc - dx), a.Y(up * h), "Right", stick_r * 1.3)
    for side, fx, fy, pw, ph in spec.get("pads", []):
        a.pad(a.X(fx * w - pw / 2), a.Y(fy * h - ph / 2), pw * S, ph * S, side)
    for item in spec.get("small", []):
        cap, fx, fy, r = item[:4]
        shape_ = item[4] if len(item) > 4 else "circle"
        x, y = fx * w, fy * h
        half = r * (1.3 if shape_ == "rect" else 1.0) + 2.0
        if not clam and scy - sh / 2 - half < y < scy + sh / 2 + half and sl - half < x < sr + half:
            x = sl - half if x < w / 2 else sr + half   # keep buttons off the panel
        a.small(cap, a.X(x), a.Y(y), r * S, shape_)
    # ------------------------------------------------ back buttons
    py = a.by + h * S + 8
    left = [p for p in paddles if p[0].startswith("Left")]
    right = [p for p in paddles if not p[0].startswith("Left")]
    for group, x0, step in ((left, a.X(lc), -40), (right, a.X(rc), 40)):
        for i, (cap, lab) in enumerate(group):
            cx = x0 + step * i
            a.add('<g id="btn-%s"><rect x="%g" y="%g" width="34" height="16" rx="8" fill="none" stroke="%s" stroke-width="1.5" stroke-dasharray="4 3"/>%s</g>'
                  % (cap, cx - 17, py, QUIET, text_path(lab.upper(), cx, py + 8, 7, QUIET, 1.1)))
    return a.render(spec["title"] + " (1 mm = %g units)" % UNITS_PER_MM)


# Shared small-button sets (fractions of the outline; radius in mm).
def menu_pair(fx_l, fx_r, fy, r=2.6):
    return [("Select", fx_l, fy, r), ("Start", fx_r, fy, r)]


P_ALLY = [("LeftPaddle1", "M1"), ("RightPaddle1", "M2")]
P_LEGION = [("LeftPaddle1", "Y1"), ("LeftPaddle2", "Y2"), ("RightPaddle1", "Y3"), ("RightPaddle2", "M3")]
P_CLAW = [("LeftPaddle1", "M2"), ("RightPaddle1", "M1")]
P_DECK = [("LeftPaddle1", "L4"), ("LeftPaddle2", "L5"), ("RightPaddle1", "R4"), ("RightPaddle2", "R5")]
P_M12 = [("LeftPaddle1", "M1"), ("RightPaddle1", "M2")]

SPECS = {
    "steam-deck": dict(title="Steam Deck", layout="inboard", hc=0.9, gw=62, r_top=30, r_bot=32, scr_cy=0.45,
                       fy=(0.26, 0.6), spread_mm=13, trigger_mm=38,
                       pads=[("Left", 0.2, 0.66, 32.5, 32.5), ("Right", 0.8, 0.66, 32.5, 32.5)],
                       small=menu_pair(0.215, 0.785, 0.075, 2.4) + [("Guide", 0.215, 0.87, 2.8, "rect"), ("QuickAccess", 0.785, 0.87, 2.6, "rect")],
                       paddles=P_DECK),
    "rog-ally": dict(title="ROG Ally / Ally X", hc=1, r_top=34, r_bot=40, fy=(0.3, 0.66),
                     small=[("Guide", 0.205, 0.12, 2.7, "rect"), ("QuickAccess", 0.795, 0.12, 2.7, "rect")] + menu_pair(0.205, 0.795, 0.88),
                     paddles=P_ALLY),
    "rog-xbox-ally": dict(title="ROG Xbox Ally / Xbox Ally X", hc=0.8, gw=68, r_top=26, r_bot=34, fy=(0.27, 0.6),
                          small=[("Guide", 0.06, 0.14, 3.6)] + menu_pair(0.2, 0.8, 0.1) +
                                [("Keyboard", 0.2, 0.84, 2.7, "rect"), ("QuickAccess", 0.8, 0.84, 2.7, "rect")],
                          paddles=P_ALLY),
    "rog-xbox-ally-x20": dict(title="ROG Xbox Ally X20", hc=0.8, gw=70, r_top=26, r_bot=34, fy=(0.27, 0.6), screen_in=7.4,
                              small=[("Guide", 0.06, 0.14, 3.6)] + menu_pair(0.2, 0.8, 0.1) +
                                    [("Keyboard", 0.2, 0.84, 2.7, "rect"), ("QuickAccess", 0.8, 0.84, 2.7, "rect")],
                              paddles=P_ALLY),
    "legion-go": dict(title="Legion Go (detachable controllers)", shape="detach", r_out=30, fy=(0.27, 0.53),
                      pads=[("Right", 0.926, 0.78, 28.5, 28.5)],
                      small=[("Guide", 0.074, 0.9, 2.6, "rect"), ("QuickAccess", 0.926, 0.97, 2.4, "rect"),
                             ("Select", 0.12, 0.76, 2.2), ("Start", 0.88, 0.6, 2.2),
                             ("LeftStickTouch", 0.035, 0.76, 2.2), ("RightStickTouch", 0.965, 0.6, 2.2)],
                      paddles=P_LEGION),
    "legion-go-2": dict(title="Legion Go 2 (detachable controllers)", shape="detach", r_out=32, fy=(0.27, 0.53),
                        pads=[("Right", 0.922, 0.78, 24, 24)],
                        small=[("Guide", 0.075, 0.9, 2.6, "rect"), ("QuickAccess", 0.925, 0.97, 2.4, "rect"),
                               ("Select", 0.12, 0.76, 2.2), ("Start", 0.88, 0.62, 2.2),
                               ("Keyboard", 0.12, 0.09, 2.2), ("QuickAccess2", 0.88, 0.09, 2.2)],
                        paddles=P_LEGION),
    "legion-go-s": dict(title="Legion Go S", hc=0.82, gw=66, r_top=24, r_bot=34, fy=(0.27, 0.6),
                        pads=[("Right", 0.885, 0.86, 10, 10)],
                        small=[("Guide", 0.2, 0.08, 2.6, "rect"), ("QuickAccess", 0.8, 0.08, 2.6, "rect")] + menu_pair(0.19, 0.81, 0.84),
                        paddles=[("LeftPaddle1", "Y1"), ("RightPaddle1", "Y2")]),
    "msi-claw-8": dict(title="MSI Claw 8 AI+ / Claw A8", hc=0.82, gw=64, r_top=24, r_bot=34, fy=(0.27, 0.6),
                       small=[("Guide", 0.2, 0.08, 2.6, "rect"), ("QuickAccess", 0.8, 0.08, 2.6, "rect")] + menu_pair(0.2, 0.8, 0.82),
                       paddles=P_CLAW),
    "msi-claw-8-ex": dict(title="MSI Claw 8 EX AI+", hc=0.78, gw=76, r_top=22, r_bot=38, fy=(0.27, 0.6),
                          small=[("Guide", 0.21, 0.08, 2.6, "rect"), ("QuickAccess", 0.79, 0.08, 2.6, "rect")] + menu_pair(0.215, 0.785, 0.8),
                          paddles=P_CLAW),
    "msi-claw-a1m": dict(title="MSI Claw A1M", hc=0.82, gw=64, r_top=24, r_bot=32, fy=(0.28, 0.62),
                         small=[("Guide", 0.2, 0.09, 2.6, "rect"), ("QuickAccess", 0.8, 0.09, 2.6, "rect")] + menu_pair(0.2, 0.8, 0.84),
                         paddles=P_CLAW),
    "msi-claw-7": dict(title="MSI Claw 7 AI+", hc=0.82, gw=62, r_top=24, r_bot=32, fy=(0.28, 0.62),
                       small=[("Guide", 0.2, 0.09, 2.6, "rect"), ("QuickAccess", 0.8, 0.09, 2.6, "rect")] + menu_pair(0.2, 0.8, 0.84),
                       paddles=P_CLAW),
    "onexfly-f1": dict(title="OneXFly F1 / F1 Pro", hc=1, r_top=30, r_bot=36, fy=(0.3, 0.66), k=0.9,
                       small=menu_pair(0.2, 0.8, 0.11, 2.3) + [("QuickAccess", 0.12, 0.9, 2.4, "rect"), ("Keyboard", 0.2, 0.9, 2.4, "rect"),
                                                               ("Guide", 0.86, 0.9, 3)],
                       paddles=[("RightPaddle1", "M2")]),
    "onexfly-apex": dict(title="OneXFly Apex", hc=0.84, gw=62, r_top=26, r_bot=32, fy=(0.28, 0.62),
                         small=menu_pair(0.2, 0.8, 0.09) + [("QuickAccess", 0.1, 0.86, 2.5, "rect"), ("Keyboard", 0.16, 0.92, 2.5, "rect"),
                                                            ("Guide", 0.85, 0.88, 3.2)],
                         paddles=P_M12),
    "onexplayer-x1": dict(title="OneXPlayer X1 (detachable controllers)", shape="detach", controller_mm=44, r_out=24, fy=(0.24, 0.48),
                          small=[("Keyboard", 0.06, 0.88, 2.6, "rect"), ("QuickAccess", 0.94, 0.88, 2.6, "rect"),
                                 ("Select", 0.08, 0.68, 2.2), ("Start", 0.92, 0.68, 2.2)],
                          paddles=P_M12),
    "onexplayer-x1-mini": dict(title="OneXPlayer X1 Mini (detachable controllers)", shape="detach", controller_mm=40, r_out=22, fy=(0.27, 0.55),
                               small=[("Keyboard", 0.07, 0.88, 2.5, "rect"), ("QuickAccess", 0.93, 0.88, 2.5, "rect"),
                                      ("Select", 0.09, 0.74, 2.1), ("Start", 0.91, 0.74, 2.1)],
                               paddles=P_M12),
    "onexplayer-2": dict(title="OneXPlayer 2 / 2 Pro (detachable controllers)", shape="detach", r_out=26, fy=(0.27, 0.6),
                         small=[("QuickAccess", 0.93, 0.88, 2.6, "rect"), ("Select", 0.1, 0.84, 2.2), ("Start", 0.9, 0.12, 2.2)]),
    "onexplayer-3": dict(title="OneXPlayer 3 (detachable controllers)", shape="detach", r_out=28, fy=(0.27, 0.6),
                         small=[("QuickAccess", 0.075, 0.88, 2.6), ("QuickAccess2", 0.925, 0.88, 2.6, "rect"),
                                ("Select", 0.11, 0.1, 2.2), ("Start", 0.89, 0.1, 2.2)],
                         paddles=P_M12),
    "onexplayer-super-x": dict(title="OneXPlayer Super X (tablet, detachable controllers)", shape="detach", controller_mm=44, r_out=24,
                               fy=(0.22, 0.44), small=[("Guide", 0.04, 0.86, 2.6), ("Select", 0.06, 0.66, 2.2), ("Start", 0.94, 0.66, 2.2)]),
    "onexplayer-g1": dict(title="OneXPlayer G1 (clamshell)", shape="clam", fy=(0.22, 0.52), k=0.85, mid_mm=118,
                          keyboard=(48, 16, 112, 58), small=[("Guide", 0.9, 0.9, 2.8), ("QuickAccess", 0.1, 0.9, 2.6, "rect")] + menu_pair(0.1, 0.9, 0.72, 2.2)),
    "aokzoe-a1": dict(title="AOKZOE A1 / A1 Pro / A1X", hc=0.84, gw=62, r_top=24, r_bot=32, fy=(0.28, 0.62), scr_cy=0.44,
                      grille=[(0.5, 0.9, 30)],
                      small=menu_pair(0.2, 0.8, 0.09) + [("QuickAccess", 0.1, 0.86, 2.5, "rect"), ("Keyboard", 0.155, 0.91, 2.5, "rect"),
                                                         ("Guide", 0.84, 0.86, 3.2)]),
    "ayaneo-2": dict(title="AYANEO 2 / 2S", hc=1, r_top=32, r_bot=38, fy=(0.3, 0.64), k=0.92,
                     small=[("LeftTop", 0.13, 0.035, 2.4, "rect"), ("RightTop", 0.87, 0.035, 2.4, "rect"),
                            ("Select", 0.12, 0.86, 2.2), ("Start", 0.2, 0.9, 2.2),
                            ("QuickAccess", 0.8, 0.9, 2.4, "rect"), ("Guide", 0.88, 0.86, 2.8)]),
    "ayaneo-kun": dict(title="AYANEO KUN", hc=0.84, gw=66, r_top=26, r_bot=34, fy=(0.24, 0.5),
                       pads=[("Left", 0.13, 0.78, 26, 22), ("Right", 0.87, 0.78, 26, 22)],
                       small=[("LeftTop", 0.12, 0.03, 2.4, "rect"), ("RightTop", 0.88, 0.03, 2.4, "rect"),
                              ("Select", 0.2, 0.08, 2.2), ("Start", 0.8, 0.08, 2.2),
                              ("QuickAccess", 0.17, 0.62, 2.4, "rect"), ("QuickAccess2", 0.83, 0.62, 2.8)]),
    "ayaneo-air-1s": dict(title="AYANEO AIR 1S", hc=1, r_top=28, r_bot=32, fy=(0.3, 0.66), k=0.8,
                          small=[("LeftTop", 0.13, 0.04, 2.2, "rect"), ("RightTop", 0.87, 0.04, 2.2, "rect"),
                                 ("Select", 0.2, 0.9, 2), ("Start", 0.8, 0.12, 2),
                                 ("QuickAccess", 0.09, 0.9, 2.2, "rect"), ("Guide", 0.91, 0.9, 2.6)]),
    "ayaneo-air-plus": dict(title="AYANEO AIR Plus", hc=1, r_top=28, r_bot=32, fy=(0.3, 0.66), k=0.8,
                            small=[("LeftTop", 0.13, 0.04, 2.2, "rect"), ("RightTop", 0.87, 0.04, 2.2, "rect"),
                                   ("Select", 0.2, 0.9, 2), ("Start", 0.8, 0.12, 2),
                                   ("QuickAccess", 0.09, 0.9, 2.2, "rect"), ("Guide", 0.91, 0.9, 2.6)]),
    "ayaneo-flip-ds": dict(title="AYANEO Flip DS (clamshell)", shape="clam", fy=(0.3, 0.68), k=0.78, mid_mm=84,
                           second_screen=(3.5, "3:2", 0.42),
                           small=[("LeftTop", 0.14, 0.05, 2.2, "rect"), ("RightTop", 0.86, 0.05, 2.2, "rect"),
                                  ("Select", 0.33, 0.85, 2), ("Start", 0.67, 0.85, 2),
                                  ("Keyboard", 0.42, 0.93, 2, "rect"), ("QuickAccess", 0.58, 0.93, 2, "rect"), ("Guide", 0.9, 0.92, 2.4)]),
    "ayaneo-flip-1s-ds": dict(title="AYANEO Flip 1S DS (clamshell)", shape="clam", fy=(0.3, 0.68), k=0.78, mid_mm=96,
                              second_screen=(4.5, "3:2", 0.44),
                              small=[("LeftTop", 0.14, 0.05, 2.2, "rect"), ("RightTop", 0.86, 0.05, 2.2, "rect"),
                                     ("Select", 0.12, 0.93, 2), ("Start", 0.88, 0.93, 2), ("QuickAccess", 0.62, 0.95, 2.2)],
                              paddles=[("LeftPaddle2", "L"), ("RightPaddle2", "R")]),
    "ayaneo-3": dict(title="AYANEO 3", hc=0.86, gw=60, r_top=26, r_bot=32, fy=(0.27, 0.58),
                     pads=[("Left", 0.2, 0.84, 16, 12), ("Right", 0.8, 0.84, 16, 12)],
                     small=[("LeftTop", 0.12, 0.035, 2.4, "rect"), ("RightTop", 0.88, 0.035, 2.4, "rect"),
                            ("Select", 0.2, 0.09, 2.2), ("Start", 0.8, 0.09, 2.2),
                            ("QuickAccess", 0.07, 0.84, 2.4, "rect"), ("Guide", 0.93, 0.84, 2.8)],
                     paddles=[]),
    "ayaneo-slide": dict(title="AYANEO Slide (slide-out keyboard)", hc=1, r_top=26, r_bot=30, fy=(0.3, 0.66), k=0.8, slider=0.93,
                         small=[("LeftTop", 0.13, 0.04, 2.2, "rect"), ("RightTop", 0.87, 0.04, 2.2, "rect"),
                                ("Select", 0.2, 0.9, 2), ("Start", 0.8, 0.12, 2),
                                ("QuickAccess", 0.09, 0.9, 2.2, "rect"), ("Guide", 0.97, 0.5, 2.8)]),
    "gpd-win-4": dict(title="GPD WIN 4 (slide-out keyboard)", hc=1, r_top=20, r_bot=24, fy=(0.3, 0.68), k=0.82, slider=0.94,
                      small=menu_pair(0.2, 0.8, 0.9, 2), paddles=[("LeftPaddle1", "L4"), ("QuickAccess", "R4")]),
    "gpd-win-mini": dict(title="GPD WIN Mini (clamshell)", shape="clam", fy=(0.2, 0.46), k=0.72, mid_mm=96,
                         keyboard=(36, 6, 96, 42), pads=[("Touch", 0.5, 0.78, 46, 26)],
                         small=menu_pair(0.1, 0.9, 0.72, 1.9), paddles=[("LeftPaddle1", "L4"), ("QuickAccess", "R4")]),
    "gpd-win-max": dict(title="GPD WIN Max 2 (laptop)", shape="clam", fy=(0.11, 0.28), k=0.7, mid_mm=130,
                        keyboard=(22, 62, 183, 52), pads=[("Touch", 0.5, 0.875, 60, 28)],
                        small=menu_pair(0.2, 0.8, 0.06, 2), paddles=[("LeftPaddle1", "L4"), ("RightPaddle1", "R4")]),
    "gpd-win-5": dict(title="GPD WIN 5", hc=0.86, gw=58, r_top=24, r_bot=30, fy=(0.28, 0.62),
                      small=[("QuickAccess", 0.93, 0.08, 2.4, "rect"), ("Select", 0.12, 0.88, 2.2), ("Start", 0.86, 0.86, 2.2),
                             ("Guide", 0.2, 0.9, 2.6), ("Keyboard", 0.8, 0.9, 2.4, "rect")],
                      paddles=[("LeftPaddle1", "L4"), ("RightPaddle1", "R4")]),
    "zotac-zone": dict(title="ZOTAC Gaming Zone", layout="inboard", hc=0.84, gw=66, r_top=26, r_bot=34, fy=(0.27, 0.6),
                       spread_mm=17, dials=True, k=0.9,
                       pads=[("Left", 0.18, 0.66, 24, 22), ("Right", 0.82, 0.66, 24, 22)],
                       small=[("Guide", 0.25, 0.9, 2.6), ("QuickAccess", 0.75, 0.9, 2.6), ("QuickAccess2", 0.5, 0.92, 2.6, "rect")] +
                             menu_pair(0.25, 0.75, 0.08, 2.2),
                       paddles=P_M12),
    "acer-atlas-8": dict(title="Acer Predator Atlas 8", hc=0.8, gw=68, r_top=24, r_bot=36, fy=(0.27, 0.6),
                         small=[("Guide", 0.2, 0.08, 2.6), ("QuickAccess", 0.8, 0.08, 2.6, "rect")] + menu_pair(0.2, 0.8, 0.82),
                         paddles=P_CLAW),
    "acer-nitro-blaze-7": dict(title="Acer Nitro Blaze 7", hc=0.86, gw=58, r_top=24, r_bot=30, fy=(0.28, 0.62),
                               small=[("Guide", 0.2, 0.08, 2.6), ("QuickAccess", 0.8, 0.08, 2.6, "rect")] + menu_pair(0.2, 0.8, 0.84)),
    "acer-nitro-blaze-8": dict(title="Acer Nitro Blaze 8", hc=0.86, gw=64, r_top=24, r_bot=32, fy=(0.27, 0.6),
                               small=[("Guide", 0.2, 0.08, 2.6), ("QuickAccess", 0.8, 0.08, 2.6, "rect")] + menu_pair(0.2, 0.8, 0.84)),
    "acer-nitro-blaze-11": dict(title="Acer Nitro Blaze 11 (detachable controllers)", shape="detach", r_out=26, fy=(0.24, 0.48),
                                small=[("Guide", 0.07, 0.86, 2.6), ("QuickAccess", 0.93, 0.86, 2.6, "rect")] + menu_pair(0.07, 0.93, 0.7, 2.2)),
    "orangepi-neo": dict(title="Orange Pi Neo", hc=0.86, gw=58, r_top=26, r_bot=30, fy=(0.26, 0.5), k=0.9, scr_cy=0.44,
                         pads=[("Left", 0.14, 0.76, 24, 22), ("Right", 0.86, 0.76, 24, 22)],
                         small=[("LeftTop", 0.12, 0.035, 2.2, "rect"), ("RightTop", 0.88, 0.035, 2.2, "rect"),
                                ("Guide", 0.25, 0.92, 2.6), ("QuickAccess", 0.75, 0.92, 2.6, "rect")] + menu_pair(0.24, 0.76, 0.08, 2.1)),
}

ARTS = {"generic": art_generic()}
for name, spec in SPECS.items():
    ARTS[name] = draw(name, spec)
missing = sorted(set(BODIES) - set(SPECS))
if missing:
    sys.exit("bodies without a drawing: %s" % missing)
for f in os.listdir(os.path.join(OUT, "art")):
    if f.endswith(".svg") and f[:-4] not in ARTS:
        os.remove(os.path.join(OUT, "art", f))
        if os.path.exists(os.path.join(OUT, "art", f + ".import")):
            os.remove(os.path.join(OUT, "art", f + ".import"))
for name, content in ARTS.items():
    write("art/%s.svg" % name, content)
print(len(GLYPHS), "glyphs,", len(ARTS), "pictures")
