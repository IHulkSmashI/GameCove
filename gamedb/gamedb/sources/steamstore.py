"""Game details and Metacritic scores from the Steam store's appdetails.

    https://store.steampowered.com/api/appdetails?appids=<id>&l=english&cc=us

Keyless store endpoint, used under the Steam Web API Terms of Use
(https://steamcommunity.com/dev/apiterms). It answers one app per request and
allows about 200 requests every 5 minutes per address, so the nightly job
refreshes a slice of the popular games each night (never-fetched first, then
the oldest) at one request every REQUEST_GAP seconds, and keeps last night's
values for the rest. The app fetches any other game on demand (cached a week).

Kept per game: the short description, genres, developers, publishers, release
date, full/partial controller support, and Steam's own "metacritic" block
({"score", "url"}): the official Metacritic score Valve shows on the store page,
with the link to the game's Metacritic page. Metacritic itself is never fetched.
"""

from __future__ import annotations

import datetime as dt
import json
import urllib.parse

from .. import meta
from ..ids import steam_id
from ..net import Client, GiveUp, NotFound

URL = "https://store.steampowered.com/api/appdetails"
REQUEST_GAP = 1.6     # 200 requests / 5 min is 1.5 s; a little slower to stay clear
PER_NIGHT = 350       # about 10 minutes
CONTROLLER_FULL, CONTROLLER_PARTIAL = 28, 18   # Steam category ids


def url_for(appid: str) -> str:
    return URL + "?" + urllib.parse.urlencode({"appids": appid, "l": "english", "cc": "us"})


def parse(appid: str, body) -> dict | None:
    """One appdetails answer -> {"meta": {...}, "metacritic": {...} or absent, "type"}.
    None when Steam says it has no such app (success false) or the answer is junk."""
    if isinstance(body, (bytes, str)):
        try:
            body = json.loads(body)
        except ValueError:
            return None
    entry = body.get(str(appid)) if isinstance(body, dict) else None
    if not isinstance(entry, dict) or not entry.get("success") or not isinstance(entry.get("data"), dict):
        return None
    d = entry["data"]
    cats = {c.get("id") for c in d.get("categories") or [] if isinstance(c, dict)}
    controller = d.get("controller_support")
    if controller not in ("full", "partial"):
        controller = "full" if CONTROLLER_FULL in cats else "partial" if CONTROLLER_PARTIAL in cats else None
    m = meta.compact({
        "summary": meta.summary(d.get("short_description")),
        "genres": meta.clean_list([g.get("description") for g in d.get("genres") or [] if isinstance(g, dict)]),
        "developers": meta.clean_list(d.get("developers")),
        "publishers": meta.clean_list(d.get("publishers")),
        "release_date": meta.steam_date((d.get("release_date") or {}).get("date")),
        "controller": controller,
    })
    out = {"meta": m, "type": str(d.get("type") or "")}
    mc = meta.metacritic(d.get("metacritic"))
    if mc:
        out["metacritic"] = mc
    return out


def pick(popular: dict[str, dict], previous: dict[str, dict], limit: int = PER_NIGHT) -> list[str]:
    """Which popular games to refresh tonight: never fetched first (most popular
    first), then the oldest fetch."""
    fresh = [s for s in popular if s not in previous]
    fresh.sort(key=lambda s: (popular[s].get("rank", 1 << 30), int(s)))
    old = [s for s in popular if s in previous]
    old.sort(key=lambda s: (previous[s].get("at") or "", popular[s].get("rank", 1 << 30)))
    return (fresh + old)[:limit]


def fetch(client: Client, appids: list[str], today: str | None = None) -> dict[str, dict]:
    """Steam app id -> {"meta", "metacritic"?, "at": YYYY-MM-DD} for each id that
    answered. The client paces the requests (min_interval=REQUEST_GAP). Stops
    quietly (keeping what it has) when the budget runs out or Steam starts
    refusing."""
    today = today or dt.date.today().isoformat()
    out: dict[str, dict] = {}
    for sid in (a for a in appids if steam_id(a)):
        try:
            rec = parse(sid, client.get(url_for(sid)))
        except NotFound:
            continue
        except GiveUp:
            break
        if rec is not None:
            rec["at"] = today
            rec.pop("type", None)
            out[sid] = rec
    return out
