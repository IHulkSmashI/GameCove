"""Valve Steam Deck: the BIOS map inside jupiter-biosupdate, from jupiter-hw-support (the SteamOS
package that ships the BIOS images and flasher; mirrored with one tag per SteamOS build at
github.com/Jovian-Experiments/jupiter-hw-support).

jupiter-biosupdate holds BIOS_VERSION_MAP = {"<running>": {"default": "<target>", "auto": ..}}.
"F7A..." is the LCD (Jupiter), "F7G..." the OLED (Galileo). The newest target per prefix is the BIOS
the newest SteamOS brings. jupiter-controller-update names the controller firmware as hex build
timestamps (CURRENT_D21_FW_TS=69C6B03E). Installing is SteamOS's own job (at boot, or Steam asks).
"""
from __future__ import annotations

import datetime as dt
import json
import re

from .common import item, load_json

TAGS = "https://api.github.com/repos/Jovian-Experiments/jupiter-hw-support/tags?per_page=100"
RAW = "https://raw.githubusercontent.com/Jovian-Experiments/jupiter-hw-support/{tag}/usr/bin/{name}"
NOTES = "https://store.steampowered.com/news/app/1675200"
PREFIX = {"Jupiter": "F7A", "Galileo": "F7G"}


def bios_map(script: str) -> dict:
    m = re.search(r"BIOS_VERSION_MAP='(\{.*?\})'", script, re.S)
    if not m:
        return {}
    try:
        d = json.loads(m.group(1))
    except ValueError:
        return {}
    return d if isinstance(d, dict) else {}


def _num(v: str) -> tuple:
    m = re.match(r"F7[AG](\d{4})", v)
    return (int(m.group(1)) if m else -1, v)


def newest_bios(script: str, board: str) -> str:
    pre = PREFIX.get(board, "")
    targets = {str(e.get("default")) for k, e in bios_map(script).items()
               if k.startswith(pre) and isinstance(e, dict) and e.get("default")}
    return max(targets, key=_num) if targets else ""


def controller_fw(script: str) -> dict:
    out = {}
    for part, ts in re.findall(r"^CURRENT_(D21|D20|RA4)_FW_TS=([0-9A-Fa-f]{8})\s*$", script, re.M):
        out[part] = {"ts": ts.upper(), "date": dt.datetime.fromtimestamp(int(ts, 16), dt.timezone.utc).strftime("%Y-%m-%d")}
    return out


def latest_tag(doc: object) -> str:
    names = [str(t.get("name", "")) for t in doc if isinstance(t, dict)] if isinstance(doc, list) else []
    names = [n for n in names if re.match(r"^jupiter-\d{8}(\.\d+)?$", n)]
    return max(names, key=lambda n: [int(x) for x in re.findall(r"\d+", n)]) if names else ""


def items(bios_script: str, ctl_script: str, board: str, tag: str) -> list[dict]:
    out = []
    v = newest_bios(bios_script, board)
    if v:
        out.append(item("bios", "BIOS", v, notes=f"In SteamOS's jupiter-hw-support {tag}." if tag else "",
                        notes_url=NOTES, download_page=NOTES, flash="steamos", scheme="valve", severity="recommended"))
    fw = controller_fw(ctl_script)
    if fw:
        newest = max(fw.values(), key=lambda x: x["ts"])
        out.append(item("controller", "Controller firmware", newest["ts"], date=newest["date"], notes_url=NOTES,
                        download_page=NOTES, flash="steamos", scheme="hex-ts", severity="recommended"))
    return out


def fetch_scripts(client) -> tuple[str, str, str]:
    from .software import _gh_headers
    tag = latest_tag(load_json(client.get(TAGS, headers=_gh_headers())))
    if not tag:
        return "", "", ""
    bios = client.get(RAW.format(tag=tag, name="jupiter-biosupdate")).decode("utf-8", "replace")
    ctl = client.get(RAW.format(tag=tag, name="jupiter-controller-update")).decode("utf-8", "replace")
    return bios, ctl, tag
