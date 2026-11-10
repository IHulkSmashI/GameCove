"""Time to beat from IGDB's game_time_to_beats endpoint.

Needs TWITCH_CLIENT_ID and TWITCH_CLIENT_SECRET (a GitHub Actions secret in the
nightly job; never shipped to players). Skipped cleanly when they're missing.
IGDB allows 4 requests a second and 500 rows per request.
"""

from __future__ import annotations

import datetime as dt
import json
import os
import re
import time
import urllib.parse

from ..ids import steam_id
from ..net import Client, GiveUp
from .. import ttb as ttb_rules

TOKEN_URL = "https://id.twitch.tv/oauth2/token"
API = "https://api.igdb.com/v4/"
STEAM_SOURCE = 1  # IGDB external game source id for Steam
BATCH = 500
SLUG = re.compile(r"[a-z0-9][a-z0-9-]{0,199}")  # slugs go into the query
MAX_TITLE_SEARCHES = 400  # one request each; only popular games still without a value


def credentials() -> tuple[str, str] | None:
    cid, secret = os.environ.get("TWITCH_CLIENT_ID"), os.environ.get("TWITCH_CLIENT_SECRET")
    return (cid, secret) if cid and secret else None


def token(client: Client, cid: str, secret: str) -> str:
    q = urllib.parse.urlencode({"client_id": cid, "client_secret": secret, "grant_type": "client_credentials"})
    return json.loads(client.get(f"{TOKEN_URL}?{q}", data=b"", method="POST"))["access_token"]


def post(client: Client, endpoint: str, body: str, cid: str, tok: str) -> list:
    out = json.loads(client.get(
        API + endpoint,
        data=body.encode(),
        headers={"Client-ID": cid, "Authorization": f"Bearer {tok}", "Accept": "application/json"},
        method="POST",
    ))
    time.sleep(0.3)
    return out


def hours(seconds) -> float | None:
    return round(seconds / 3600, 1) if isinstance(seconds, (int, float)) and seconds > 0 else None


def to_time_to_beat(row: dict) -> dict | None:
    t = {
        "main_h": hours(row.get("hastily")),
        "extra_h": hours(row.get("normally")),
        "complete_h": hours(row.get("completely")),
        "count": row.get("count", 0),
        "source": "igdb",
    }
    return t if any(t[k] for k in ("main_h", "extra_h", "complete_h")) else None


def query_all(client: Client, endpoint: str, body: str, cid: str, tok: str, limit: int | None = None) -> list:
    """Every row for `body` (a query without limit/offset), page by page: a
    full page means there may be more (a Steam id can map to several IGDB
    games, so 500 ids can give more than 500 rows)."""
    limit = limit or BATCH
    out: list = []
    offset = 0
    while True:
        rows = post(client, endpoint, f"{body} limit {limit}; offset {offset};", cid, tok)
        if not isinstance(rows, list):
            break
        out.extend(rows)
        if len(rows) < limit:
            break
        offset += limit
    return out


def _quoted(values) -> str:
    return ",".join(f'"{v}"' for v in values)


def _safe_text(s: str) -> str:
    """A title for an IGDB query string: no quotes, backslashes or semicolons."""
    return re.sub(r'[\\";]+', " ", s).strip()


def normalise(title: str) -> str:
    """Lowercase letters and digits only (like the app's GameDB.normalise)."""
    return re.sub(r"[\W_]+", "", (title or "").casefold())


def _year(stamp) -> int | None:
    if isinstance(stamp, (int, float)) and not isinstance(stamp, bool) and stamp > 0:
        return dt.datetime.fromtimestamp(stamp, dt.timezone.utc).year
    return None


def title_match(rows: list, title: str, year: int | None) -> list[int]:
    """IGDB game ids from a search whose normalised name equals `title` and
    whose first release is within a year of `year` (when both are known)."""
    want = normalise(title)
    out = []
    for r in rows if isinstance(rows, list) else []:
        if not isinstance(r, dict) or not isinstance(r.get("id"), int) or normalise(r.get("name", "")) != want:
            continue
        y = _year(r.get("first_release_date"))
        if year is not None and y is not None and abs(y - year) > 1:
            continue
        out.append(r["id"])
    return out


def map_by_steam_uid(client: Client, steam_ids: list[str], cid: str, tok: str) -> dict[str, set[int]]:
    """Route 1: IGDB external_games rows for Steam (source 1) with these uids."""
    out: dict[str, set[int]] = {}
    for i in range(0, len(steam_ids), BATCH):
        rows = query_all(client, "external_games",
                         f"fields game,uid; where external_game_source = {STEAM_SOURCE} & "
                         f"uid = ({_quoted(steam_ids[i:i + BATCH])});", cid, tok)
        for r in rows:
            sid = steam_id(r.get("uid")) if isinstance(r, dict) else None
            if sid is not None and isinstance(r.get("game"), int):
                out.setdefault(sid, set()).add(r["game"])
    return out


def map_by_slug(client: Client, slugs: dict[str, str], cid: str, tok: str) -> dict[str, set[int]]:
    """Route 2: Wikidata's IGDB id (P5794, an IGDB slug) -> IGDB game."""
    by_slug: dict[str, list[str]] = {}
    for sid, slug in slugs.items():
        if isinstance(slug, str) and SLUG.fullmatch(slug):
            by_slug.setdefault(slug, []).append(sid)
    out: dict[str, set[int]] = {}
    keys = sorted(by_slug)
    for i in range(0, len(keys), BATCH):
        rows = query_all(client, "games", f"fields id,slug; where slug = ({_quoted(keys[i:i + BATCH])});", cid, tok)
        for r in rows:
            if isinstance(r, dict) and isinstance(r.get("id"), int) and r.get("slug") in by_slug:
                for sid in by_slug[r["slug"]]:
                    out.setdefault(sid, set()).add(r["id"])
    return out


def map_by_title(client: Client, titles: dict[str, tuple[str, int | None]], cid: str, tok: str,
                 max_searches: int = MAX_TITLE_SEARCHES) -> dict[str, set[int]]:
    """Route 3 (last resort, popular games only): IGDB search by title, kept
    only on an exact normalised-title match within a year of the release."""
    out: dict[str, set[int]] = {}
    for sid, (title, year) in list(titles.items())[:max_searches]:
        q = _safe_text(title)
        if not normalise(q):
            continue
        try:
            rows = post(client, "games", f'search "{q}"; fields id,name,first_release_date; limit 10;', cid, tok)
        except GiveUp:  # out of time or IGDB refusing: keep what the other routes found
            break
        ids = title_match(rows, title, year)
        if ids:
            out[sid] = set(ids)
    return out


def time_to_beats(client: Client, games: set[int], cid: str, tok: str) -> dict[int, dict]:
    out: dict[int, dict] = {}
    ids = sorted(games)
    for i in range(0, len(ids), BATCH):
        rows = query_all(client, "game_time_to_beats",
                         f"fields game_id,hastily,normally,completely,count; "
                         f"where game_id = ({','.join(str(g) for g in ids[i:i + BATCH])});", cid, tok)
        for r in rows:
            t = to_time_to_beat(r) if isinstance(r, dict) else None
            if t and isinstance(r.get("game_id"), int):
                out[r["game_id"]] = t
    return out


def fetch_for_steam(client: Client, steam_ids: list[str], slugs: dict[str, str] | None = None,
                    titles: dict[str, tuple[str, int | None]] | None = None,
                    big: set[str] | None = None) -> dict[str, dict]:
    """Steam app id -> time to beat. Call only when `credentials()` is set.

    Each Steam id is mapped to IGDB games by every route that applies: the
    external_games Steam uid, then Wikidata's IGDB slug for ids that found
    nothing, then (for `titles`, the popular games still without a sane value)
    a title + year search. A Steam id can end up with several IGDB games (an
    original and its edition, a bad duplicate): the sane time to beat with the
    most submissions wins (gamedb.ttb). `big` = popular games, which get the
    stricter checks."""
    creds = credentials()
    if not creds:
        raise RuntimeError("TWITCH_CLIENT_ID / TWITCH_CLIENT_SECRET not set")
    cid, secret = creds
    tok = token(client, cid, secret)
    big = big or set()
    steam_ids = sorted({s for s in steam_ids if steam_id(s) is not None}, key=int)  # they go into the query
    cands = map_by_steam_uid(client, steam_ids, cid, tok)
    if slugs:
        missing = {s: g for s, g in slugs.items() if s not in cands and steam_id(s) is not None}
        for s, games in map_by_slug(client, missing, cid, tok).items():
            cands.setdefault(s, set()).update(games)
    ttbs = time_to_beats(client, set().union(*cands.values()) if cands else set(), cid, tok)

    def best(sid: str) -> dict | None:
        return ttb_rules.pick([ttbs.get(g) for g in sorted(cands.get(sid, ()))], sid in big)

    out = {s: t for s in cands if (t := best(s))}
    if titles:
        todo = {s: v for s, v in titles.items() if s not in out and steam_id(s) is not None and v and v[0]}
        extra = map_by_title(client, todo, cid, tok)
        new_games = set().union(*extra.values()) - set(ttbs) if extra else set()
        ttbs.update(time_to_beats(client, new_games, cid, tok))
        for s, games in extra.items():
            cands.setdefault(s, set()).update(games)
            if t := best(s):
                out[s] = t
    return out
