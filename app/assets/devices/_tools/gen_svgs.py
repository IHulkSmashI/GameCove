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


def art_steam_deck():
    a = Art(500, 260)
    a.body("M60 60 H440 Q490 60 492 110 L494 170 Q494 222 450 222 L380 222 Q350 200 320 200 H180 Q150 200 120 222 L50 222 Q6 222 6 170 L8 110 Q10 60 60 60 Z")
    a.shoulders(30, 470, 60, 62)
    a.screen(150, 74, 200, 125)
    a.dpad(56, 104); a.stick(110, 100, "L")
    a.face(444, 104); a.stick(390, 100, "R")
    a.pad(66, 140, 64, 58, "Left"); a.pad(370, 140, 64, 58, "Right")
    a.small("Select", 132, 80, 4.5, "rect"); a.small("Start", 368, 80, 4.5, "rect")
    a.small("Guide", 132, 212, 6, "rect"); a.small("QuickAccess", 368, 212, 5, "rect")
    a.paddles([("LeftPaddle1", "L4"), ("LeftPaddle2", "L5"), ("RightPaddle1", "R4"), ("RightPaddle2", "R5")], 236)
    return a.render("Steam Deck layout")


def art_ally(xbox=False):
    a = Art()
    if xbox:
        classic(a, 46, 434, 52, 196, grip=40)
    else:
        a.rect_body(40, 52, 400, 150, 60)
    a.shoulders(52, 428, 52)
    lc, rc, cx = std_layout(a, 40, 440, 52, 200, 236)
    if xbox:
        a.small("Guide", lc - 24, 74, 7)
        a.small("Select", lc + 26, 74, 4.5, "rect"); a.small("Start", rc - 26, 74, 4.5, "rect")
        a.small("Keyboard", lc + 24, 186, 5, "rect"); a.small("QuickAccess", rc - 24, 186, 5, "rect")
    else:
        a.small("Guide", lc + 28, 68, 5, "rect"); a.small("QuickAccess", rc - 28, 68, 5, "rect")
        a.small("Select", lc + 26, 186, 4.5, "rect"); a.small("Start", rc - 26, 186, 4.5, "rect")
    a.paddles([("LeftPaddle1", "M1"), ("RightPaddle1", "M2")], 232)
    return a.render("ROG Xbox Ally layout" if xbox else "ROG Ally layout")


def art_legion_go(go2=False):
    a = Art(500, 260)
    a.rect_body(118, 48, 264, 168, 14, "part-body")
    a.screen(130, 58, 240, 148)
    # detachable halves
    a.add('<path id="part-controller-left" d="M112 48 H70 Q30 48 30 90 V196 Q30 222 58 222 H112 Z" fill="%s" stroke="%s" stroke-width="2.5"/>' % (BODY, EDGE))
    a.add('<path id="part-controller-right" d="M388 48 H430 Q470 48 470 90 V196 Q470 222 442 222 H388 Z" fill="%s" stroke="%s" stroke-width="2.5"/>' % (BODY, EDGE))
    a.shoulders(36, 464, 48, 58)
    a.stick(72, 88, "L"); a.dpad(72, 150)
    a.face(428, 88); a.stick(428, 166, "R")
    a.pad(410, 120, 36, 22, "Right")
    a.small("Guide", 96, 196, 5.5, "rect", None); a.small("QuickAccess", 404, 196, 5.5, "rect")
    a.small("Select", 52, 196, 4); a.small("Start", 448, 196, 4)
    if go2:
        a.small("Keyboard", 96, 62, 4); a.small("QuickAccess2", 404, 62, 4)
    a.paddles([("LeftPaddle1", "Y1"), ("LeftPaddle2", "Y2"), ("RightPaddle1", "Y3"), ("RightPaddle2", "M3")], 236)
    return a.render("Legion Go layout (detachable controllers)")


def art_legion_go_s():
    a = Art()
    classic(a, 40, 440, 50, 200, grip=34)
    a.shoulders(50, 430, 50)
    lc, rc, cx = std_layout(a, 40, 440, 50, 200, 236)
    a.pad(rc - 16, 150, 32, 22, "Right")
    a.small("Guide", lc - 20, 76, 5.5, "rect"); a.small("QuickAccess", rc + 20, 76, 5.5, "rect")
    a.small("Select", lc + 24, 188, 4); a.small("Start", rc - 24, 188, 4)
    a.paddles([("LeftPaddle1", "Y1"), ("RightPaddle1", "Y2")], 236)
    return a.render("Legion Go S layout")


def art_claw():
    a = Art()
    classic(a, 44, 436, 50, 196, grip=42)
    a.shoulders(54, 426, 50)
    lc, rc, cx = std_layout(a, 44, 436, 50, 196, 230)
    a.small("Guide", lc + 26, 70, 5, "rect"); a.small("QuickAccess", rc - 26, 70, 5, "rect")
    a.small("Select", lc + 26, 184, 4); a.small("Start", rc - 26, 184, 4)
    a.paddles([("LeftPaddle1", "M2"), ("RightPaddle1", "M1")], 236)
    return a.render("MSI Claw layout")


def art_onexfly():
    a = Art()
    a.rect_body(40, 56, 400, 144, 56)
    a.shoulders(52, 428, 56)
    lc, rc, cx = std_layout(a, 40, 440, 56, 200, 240)
    a.small("Guide", rc - 2, 184, 6)
    a.small("QuickAccess", lc - 2, 184, 5, "rect")
    a.small("Keyboard", rc + 22, 184, 4.5, "rect")
    a.small("Select", lc + 26, 70, 4); a.small("Start", rc - 26, 70, 4)
    return a.render("OneXFly layout")


def art_tablet_detachable(title, scr_w=290):
    a = Art(520, 260)
    a.rect_body(260 - scr_w / 2 - 10, 44, scr_w + 20, 176, 12)
    a.screen(260 - scr_w / 2, 54, scr_w, 156)
    lx0, rx1 = 260 - scr_w / 2 - 16, 260 + scr_w / 2 + 16
    a.add('<path id="part-controller-left" d="M%g 44 H%g Q%g 44 %g 84 V196 Q%g 220 %g 220 H%g Z" fill="%s" stroke="%s" stroke-width="2.5"/>' % (lx0, lx0 - 44, lx0 - 74, lx0 - 74, lx0 - 74, lx0 - 50, lx0, BODY, EDGE))
    a.add('<path id="part-controller-right" d="M%g 44 H%g Q%g 44 %g 84 V196 Q%g 220 %g 220 H%g Z" fill="%s" stroke="%s" stroke-width="2.5"/>' % (rx1, rx1 + 44, rx1 + 74, rx1 + 74, rx1 + 74, rx1 + 50, rx1, BODY, EDGE))
    a.shoulders(lx0 - 70, rx1 + 70, 44, 56)
    a.stick(lx0 - 36, 88, "L"); a.dpad(lx0 - 36, 150)
    a.face(rx1 + 36, 88); a.stick(rx1 + 36, 158, "R")
    a.small("Guide", lx0 - 36, 202, 5); a.small("QuickAccess", rx1 + 36, 202, 5, "rect")
    a.small("Select", lx0 - 14, 202, 3.5); a.small("Start", rx1 + 14, 202, 3.5)
    return a.render(title)


def art_clamshell(title, second_screen=False, keyboard=True, touchpad=False):
    a = Art(480, 300)
    a.rect_body(70, 10, 340, 130, 14, "part-lid")
    a.screen(90, 20, 300, 110)
    a.rect_body(40, 148, 400, 144, 30)
    a.shoulders(48, 432, 148, 50)
    a.stick(92, 182, "L"); a.dpad(92, 248)
    a.face(388, 182); a.stick(388, 248, "R")
    if second_screen:
        a.screen(180, 166, 120, 80, 4, "part-screen-2")
    if keyboard:
        for row in range(4):
            for col in range(10 - (row == 3) * 2):
                a.add('<rect x="%g" y="%g" width="13" height="10" rx="2" fill="%s"/>' % (162 + col * 16 + row * 4, 168 + row * 14, RAISED))
    if touchpad:
        a.pad(204, 228, 72, 40, "Touch")
    a.small("Guide", 136, 164, 5); a.small("QuickAccess", 344, 164, 5, "rect")
    a.small("Select", 136, 276, 3.5); a.small("Start", 344, 276, 3.5)
    return a.render(title)


def art_ayaneo():
    a = Art()
    a.rect_body(44, 56, 392, 144, 50)
    a.shoulders(54, 426, 56)
    lc, rc, cx = std_layout(a, 44, 436, 56, 200, 236)
    a.small("LeftTop", 92, 62, 4.5, "rect"); a.small("RightTop", 388, 62, 4.5, "rect")
    a.small("Guide", rc - 24, 186, 5.5); a.small("QuickAccess", lc + 24, 186, 4.5, "rect")
    a.small("Select", lc - 18, 186, 3.5); a.small("Start", rc + 18, 186, 3.5)
    return a.render("AYANEO layout")


def art_gpd_win():
    a = Art()
    a.rect_body(70, 46, 340, 160, 28)
    a.shoulders(80, 400, 46, 50)
    a.screen(150, 58, 180, 112)
    a.stick(112, 88, "L"); a.dpad(112, 148)
    a.face(368, 88); a.stick(368, 148, "R")
    a.small("Select", 112, 190, 3.5); a.small("Start", 368, 190, 3.5)
    a.add('<path d="M150 186 H330" stroke="%s" stroke-width="2" stroke-dasharray="6 4"/>' % QUIET)
    a.paddles([("LeftPaddle1", "L4"), ("RightPaddle1", "R4")], 228)
    return a.render("GPD WIN layout (slide-out keyboard)")


def art_zone():
    a = Art(500, 260)
    classic(a, 44, 456, 50, 200, grip=34)
    a.shoulders(54, 446, 50)
    a.screen(150, 64, 200, 124)
    a.dial(112, 92, "Left"); a.stick(112, 92, "L"); a.dpad(70, 92, 9)
    a.dial(388, 92, "Right"); a.stick(388, 92, "R"); a.face(432, 92, 12, 6)
    a.pad(72, 132, 64, 50, "Left"); a.pad(364, 132, 64, 50, "Right")
    a.small("Guide", 132, 196, 5); a.small("QuickAccess", 368, 196, 5)
    a.small("QuickAccess2", 250, 204, 5, "rect")
    a.paddles([("LeftPaddle1", "M1"), ("RightPaddle1", "M2")], 236)
    return a.render("ZOTAC Zone layout")


def art_neo():
    a = Art(500, 260)
    a.rect_body(30, 56, 440, 150, 50)
    a.shoulders(40, 460, 56)
    a.screen(150, 68, 200, 126)
    a.stick(96, 90, "L"); a.dpad(60, 140, 9)
    a.face(404, 96, 13, 6.5); a.stick(440, 140, "R", 14)
    a.pad(84, 130, 52, 50, "Left"); a.pad(364, 130, 52, 50, "Right")
    a.small("Guide", 132, 196, 5); a.small("QuickAccess", 368, 196, 5)
    a.small("LeftTop", 66, 64, 4, "rect"); a.small("RightTop", 434, 64, 4, "rect")
    return a.render("Orange Pi Neo layout")


ARTS = {
    "generic": art_generic(),
    "steam-deck": art_steam_deck(),
    "rog-ally": art_ally(False),
    "rog-xbox-ally": art_ally(True),
    "legion-go": art_legion_go(False),
    "legion-go-2": art_legion_go(True),
    "legion-go-s": art_legion_go_s(),
    "msi-claw": art_claw(),
    "onexfly": art_onexfly(),
    "onexplayer-x1": art_tablet_detachable("OneXPlayer tablet layout (detachable controllers)"),
    "onexplayer-2": art_tablet_detachable("OneXPlayer 2 layout (detachable controllers)", 260),
    "onexplayer-g1": art_clamshell("OneXPlayer G1 layout (clamshell)"),
    "aokzoe": art_onexfly(),
    "ayaneo": art_ayaneo(),
    "ayaneo-flip": art_clamshell("AYANEO Flip layout (clamshell)", second_screen=True, keyboard=False),
    "gpd-win-4": art_gpd_win(),
    "gpd-win-mini": art_clamshell("GPD WIN Mini layout (clamshell)", touchpad=True),
    "gpd-win-max": art_clamshell("GPD WIN Max layout (laptop)", touchpad=True),
    "zotac-zone": art_zone(),
    "acer": art_generic(),
    "orangepi-neo": art_neo(),
}
for name, content in ARTS.items():
    write("art/%s.svg" % name, content)
print(len(GLYPHS), "glyphs,", len(ARTS), "pictures")
