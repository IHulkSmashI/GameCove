#!/usr/bin/env python3
"""gen_games.py - build GameCove's per-game upscaling knowledge base (packaging/helpers/gamecove_upscale/data/games.json).

Ported from ClawDeck's tools/gen_games.py (same author) and extended. Everything comes from open sources anyone can
check; nothing is copied from any tool's private game database:

  1. OptiScaler's GameConfigs.cpp and Config.cpp (GPL-3.0): the per-game settings its developers ship in code, with
     the [Section] Key each lives under. Settings wrapped in OnNvidia(...) are dropped, OnNonNvidia(...) kept,
     WithXeFG(...) / WithUpscalerFGInput(...) keep their condition ("when").
  2. OptiScaler's wiki: Compatibility-List.md (every tested game: works or not, upscaler inputs, OptiPatcher support,
     notes) and each game's own page (the file name OptiScaler loads as, known issues). Packed as "compat", keyed by
     the game's name with only letters and digits, so the helper finds a game offline by its title.
  3. tools/upscalers/games.extra.json: what we add by hand, by game id (Steam app ids, launch arguments, anti-cheat,
     notes from hardware tests). It wins over 1. Its "re_engine_exes" and "capcom" are copied as they are.

  python3 tools/upscalers/gen_games.py --optiscaler <OptiScaler checkout> --wiki <OptiScaler.wiki checkout> \\
      --ini <OptiScaler.ini of the pinned version> --ini-version 0.9.4 [--out FILE]

--ini is the OptiScaler.ini of the version GameCove pins: a setting that version doesn't have is listed under "later".
The nightly workflow runs this and ships the result in the signed data release, so new games reach devices without
an app update. OptiScaler is GPL-3.0; this list is data derived from it (GPL-3.0, as GameCove) and credited in CREDITS.md.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sys
import time

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")


def ini_keys(config_cpp: str) -> dict[str, tuple[str, str]]:
    """Config member -> (section, key), from Config.cpp's reads: X.set_from_config(readBool("Section", "Key"))."""
    out = {}
    for m in re.finditer(r'(\w+)\.set_from_config\(\s*read\w*\(\s*"(\w+)"\s*,\s*"(\w+)"', config_cpp):
        out.setdefault(m.group(1), (m.group(2), m.group(3)))
    return out


def _split_top(s: str) -> list[str]:
    parts, depth, cur = [], 0, ""
    for ch in s:
        if ch in "({":
            depth += 1
        elif ch in ")}":
            depth -= 1
        if ch == "," and depth == 0:
            parts.append(cur.strip())
            cur = ""
        else:
            cur += ch
    if cur.strip():
        parts.append(cur.strip())
    return parts


def _value(v: str):
    v = v.strip()
    if v in ("true", "false"):
        return v
    if re.fullmatch(r"-?\d+(\.\d+)?f?", v):
        return v.rstrip("f")
    return None                                    # an expression we don't translate (enum etc.): skipped


def _defaults(body: str, keys: dict) -> tuple[dict, list[str]]:
    ini, skipped = {}, []
    for item in _split_top(body):
        cond = None
        m = re.fullmatch(r"(\w+)\((.*)\)", item, re.S)
        if m:
            wrap, inner = m.group(1), m.group(2)
            if wrap == "OnNvidia":
                continue
            cond = None if wrap == "OnNonNvidia" else {"WithXeFG": "xefg", "WithUpscalerFGInput": "upscaler_fg_input"}.get(wrap, wrap)
            items = _split_top(inner)
        else:
            items = [item]
        for it in items:
            mm = re.fullmatch(r"(\w+)\s*=\s*(.+)", it, re.S)
            if not mm:
                continue
            member, val = mm.group(1), _value(mm.group(2))
            if member not in keys or val is None:
                skipped.append(it)
                continue
            sec, key = keys[member]
            name = f"{sec}_{key}"
            if cond:
                ini.setdefault("when", {}).setdefault(cond, {})[name] = val
            else:
                ini[name] = val
    return ini, skipped


def games(gameconfigs_cpp: str, keys: dict) -> tuple[list[dict], list[str]]:
    start = gameconfigs_cpp.index("gameConfigs = {")
    text = gameconfigs_cpp[start:]
    out, skipped = [], []
    # each entry: comment lines (name, then why), then { .exes / .ueExes / .defaults / .quirks }
    for m in re.finditer(r"((?:[ \t]*//[^\n]*\n)+)[ \t]*\{(.*?)\n[ \t]*\},", text, re.S):
        comments = [c.strip()[2:].strip() for c in m.group(1).strip().splitlines()]
        while len(comments) > 1 and comments[0].endswith(","):      # a name list wrapped over two comment lines
            comments[0:2] = [comments[0] + " " + comments[1]]
        body = m.group(2)
        def field(name):
            f = re.search(r"\." + name + r"\s*=\s*\{(.*?)\}\s*,", body, re.S)
            return f.group(1) if f else None
        exes = re.findall(r'"([^"]+)"', field("exes") or "")
        ue = re.findall(r'"([^"]+)"', field("ueExes") or "")
        if not exes and not ue:
            continue
        ini, sk = _defaults(field("defaults") or "", keys)
        skipped += [f"{comments[0]}: {s}" for s in sk]
        quirks = [q.strip() for q in (field("quirks") or "").split(",") if q.strip()]
        out.append({"name": comments[0], "why": " ".join(comments[1:]) or None, "exes": exes, "ue_exes": ue,
                    "ini": {k: v for k, v in ini.items() if k != "when"}, "when": ini.get("when", {}),
                    "quirks": quirks})
    return out, skipped


def slug(name: str) -> str:
    return re.sub(r"[^a-z0-9]+", "-", name.lower()).strip("-")


HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, os.path.join(REPO, "packaging", "helpers"))
SCHEMA = 2


def compat_rows(wiki: str) -> dict:
    """OptiScaler's Compatibility List with each game's page folded in."""
    from gamecove_upscale import gamedb, livedb
    with open(os.path.join(wiki, "Compatibility-List.md"), encoding="utf-8") as f:
        text = f.read()
    rows = livedb.parse_compat(text)
    patcher = set()
    for line in text.splitlines():
        cells = [c.strip() for c in line.strip().strip("|").split("|")]
        if len(cells) >= 5 and "\u2728" in cells[3]:
            patcher.add(livedb._norm(re.sub(r"\[([^\]]*)\]\([^)]*\)", r"\1", cells[0])))
    out = {}
    for key, r in sorted(rows.items()):
        row = {"name": r["name"], "status": r["status"], "inputs": [x.strip() for x in re.split(r"[,/]", r["inputs"]) if x.strip()],
               "notes": r["notes"][:300]}
        if key in patcher:
            row["optipatcher"] = True
        if r.get("reframework"):
            row["reframework"] = True
        # a note naming an anti-cheat ("EAC active", "disable BattlEye", "anti-cheat will block it") counts as
        # anti-cheat whatever the status (review H2): a game that only runs with it off is still an anti-cheat game
        if gamedb.anticheat_note(r["notes"]):
            row["anticheat"] = True
        if r.get("slug"):
            row["slug"] = r["slug"]
            page = os.path.join(wiki, r["slug"] + ".asciidoc")
            if os.path.isfile(page):
                with open(page, encoding="utf-8", errors="replace") as f:
                    pg = livedb.parse_page(f.read())
                if pg.get("proxies"):
                    row["proxies"] = pg["proxies"]
                if pg.get("issues"):
                    row["issues"] = [i[:200] for i in pg["issues"][:3]]
        # "Online game, use at your own risk!", or an anti-cheat that has to be switched off: never set up by
        # itself, the player opts in per game (gamedb.online_risk, review H5)
        if not row.get("anticheat") and gamedb.anticheat_note(row["notes"], row.get("issues")):
            row["anticheat"] = True
        if not row.get("anticheat") and gamedb.online_risk(row["notes"], row.get("issues")):
            row["online"] = True
        out[key] = row
    return out


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--optiscaler", required=True, help="a checkout of optiscaler/OptiScaler")
    ap.add_argument("--wiki", required=True, help="a checkout of OptiScaler.wiki")
    ap.add_argument("--commit", default=None)
    ap.add_argument("--ini", required=True)
    ap.add_argument("--ini-version", default=None)
    ap.add_argument("--extra", default=os.path.join(HERE, "games.extra.json"))
    ap.add_argument("--out", default=os.path.join(REPO, "packaging", "helpers", "gamecove_upscale", "data", "games.json"))
    ap.add_argument("--generated", default=None, help="timestamp to write (tests; default now)")
    a = ap.parse_args()
    src = os.path.join(a.optiscaler, "OptiScaler")
    keys = ini_keys(open(os.path.join(src, "Config.cpp"), encoding="utf-8").read())
    gs, skipped = games(open(os.path.join(src, "misc", "GameConfigs.cpp"), encoding="utf-8").read(), keys)
    have, sec = set(), None
    for line in open(a.ini, encoding="utf-8", errors="replace"):
        line = line.strip()
        if line.startswith("[") and line.endswith("]"):
            sec = line[1:-1].replace("-", "").replace(".", "")
        elif sec and "=" in line and not line.startswith(";"):
            have.add(f"{sec}_{line.split('=', 1)[0].strip()}")
    for g in gs:
        later = sorted(k for k in g["ini"] if k not in have)
        g["later"] = {k: g["ini"].pop(k) for k in later}
        for cond, vals in g["when"].items():
            for k in [k for k in vals if k not in have]:
                g["later"][k] = vals.pop(k)
    extra = json.load(open(a.extra, encoding="utf-8")) if os.path.exists(a.extra) else {"games": {}}
    by_id = {}
    for g in gs:
        gid = slug(g["name"])
        by_id[gid] = {"id": gid, **g, "source": "optiscaler"}
    for gid, more in extra.get("games", {}).items():
        base = by_id.get(gid, {"id": gid, "name": more.get("name", gid), "exes": [], "ue_exes": [], "ini": {}, "when": {}, "quirks": [], "later": {}, "source": "gamecove"})
        base = {**base, **{k: v for k, v in more.items() if k != "ini"}, "ini": {**base.get("ini", {}), **more.get("ini", {})}}
        by_id[gid] = base
    compat = compat_rows(a.wiki)
    doc = {"_comment": "Generated by tools/upscalers/gen_games.py from OptiScaler's GameConfigs.cpp, Config.cpp and wiki (GPL-3.0) "
                       "plus tools/upscalers/games.extra.json. Do not edit by hand. Derived from OptiScaler: GPL-3.0, "
                       "https://github.com/optiscaler/OptiScaler/blob/master/LICENSE",
           "schema": SCHEMA, "generated": a.generated or time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
           "optiscaler_commit": a.commit, "ini_version": a.ini_version,
           "re_engine_exes": sorted(extra.get("re_engine_exes", [])), "capcom": extra.get("capcom") or {},
           "games": sorted(by_id.values(), key=lambda g: g["name"].lower()), "compat": compat}
    with open(a.out, "w", encoding="utf-8") as f:
        json.dump(doc, f, indent=1, ensure_ascii=False)
        f.write("\n")
    counts = {s: sum(1 for r in compat.values() if r["status"] == s) for s in ("works", "broken", "mixed")}
    print(f"{len(doc['games'])} games with settings; {len(compat)} games on the compatibility list {counts}; "
          f"{len(skipped)} settings not translated", file=sys.stderr)
    for s in skipped:
        print("  skipped:", s, file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
