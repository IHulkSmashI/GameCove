"""Time to beat and game details from IGDB.

Time to beat comes from game_time_to_beats; game details (summary, genres,
themes, game modes, developers, publishers, first release date, screenshots
for popular games) and the critic average (aggregated_rating and its count)
from games. Games are matched by Steam app id, and games only on GOG or Epic by
IGDB's external_games for those stores. Every field is credited "Game data from
IGDB" wherever it is shown.

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
from .. import meta as meta_rules
from .. import ttb as ttb_rules

TOKEN_URL = "https://id.twitch.tv/oauth2/token"
API = "https://api.igdb.com/v4/"
STEAM_SOURCE = 1  # IGDB external game source id for Steam
STORE_SOURCES = {"gog": 5, "epic": 26}  # IGDB external game sources for GOG and the Epic Games Store
GAME_FIELDS = ("fields id,slug,summary,first_release_date,aggregated_rating,aggregated_rating_count,"
               "total_rating_count,genres.name,themes.name,game_modes.name,involved_companies.developer,"
               "involved_companies.publisher,involved_companies.company.name,screenshots.image_id;")
SCREEN_URL = "https://images.igdb.com/igdb/image/upload/t_screenshot_med/{}.jpg"
_IMAGE_ID = re.compile(r"[a-z0-9]{1,40}")
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
                    big: set[str] | None = None, cands_out: dict | None = None) -> dict[str, dict]:
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
    if cands_out is not None:
        cands_out.update(cands)
    return out


# ---- game details ----------------------------------------------------------

def _names(rows) -> list:
    return [r.get("name") for r in rows if isinstance(r, dict)] if isinstance(rows, list) else []


def to_meta(row: dict, screens: bool = False) -> dict:
    """An IGDB games row -> {"meta": {...}, "critic": {"score", "count"}?, "igdb": slug}."""
    comps = [c for c in row.get("involved_companies") or [] if isinstance(c, dict)]

    def companies(flag: str) -> list:
        return [(c.get("company") or {}).get("name") for c in comps if c.get(flag) and isinstance(c.get("company"), dict)]

    shots = []
    if screens:
        for s in row.get("screenshots") or []:
            iid = s.get("image_id") if isinstance(s, dict) else None
            if isinstance(iid, str) and _IMAGE_ID.fullmatch(iid):
                shots.append(SCREEN_URL.format(iid))
            if len(shots) >= meta_rules.SCREENS_MAX:
                break
    m = meta_rules.compact({
        "summary": meta_rules.summary(row.get("summary")),
        "genres": meta_rules.clean_list(_names(row.get("genres"))),
        "themes": meta_rules.clean_list(_names(row.get("themes"))),
        "modes": meta_rules.clean_list(_names(row.get("game_modes"))),
        "developers": meta_rules.clean_list(companies("developer")),
        "publishers": meta_rules.clean_list(companies("publisher")),
        "release_date": meta_rules.iso_date(row.get("first_release_date")),
        "screens": shots,
    })
    out: dict = {"meta": m}
    c = meta_rules.score(row.get("aggregated_rating"), row.get("aggregated_rating_count"))
    if c:
        out["critic"] = c
    if isinstance(row.get("slug"), str) and SLUG.fullmatch(row["slug"]):
        out["igdb"] = row["slug"]
    return out


def _richness(row: dict) -> tuple:
    return (bool(row.get("summary")), row.get("aggregated_rating_count") or 0, row.get("total_rating_count") or 0)


def game_details(client: Client, games: set[int], cid: str, tok: str) -> dict[int, dict]:
    out: dict[int, dict] = {}
    ids = sorted(games)
    for i in range(0, len(ids), BATCH):
        rows = query_all(client, "games",
                         f"{GAME_FIELDS} where id = ({','.join(str(g) for g in ids[i:i + BATCH])});", cid, tok)
        for r in rows:
            if isinstance(r, dict) and isinstance(r.get("id"), int):
                out[r["id"]] = r
    return out


def best_details(cands: dict[str, set[int]], rows: dict[int, dict], prefix: str,
                 screens_for: set[str] | None = None) -> dict[str, dict]:
    """For each store id, the richest of its IGDB games (a summary first, then
    the most critic reviews) -> "<prefix>:<id>" -> to_meta(row)."""
    out = {}
    screens_for = screens_for or set()
    for sid, games in cands.items():
        found = [rows[g] for g in sorted(games) if g in rows]
        if not found:
            continue
        row = max(found, key=_richness)
        d = to_meta(row, screens=sid in screens_for)
        if d["meta"] or d.get("critic"):
            out[f"{prefix}:{sid}"] = d
    return out


def map_by_store(client: Client, store: str, uids: list[str], cid: str, tok: str) -> dict[str, set[int]]:
    """IGDB external_games rows for GOG or Epic with these store ids."""
    src = STORE_SOURCES[store]
    safe = [u for u in uids if isinstance(u, str) and re.fullmatch(r"[A-Za-z0-9._:-]{1,120}", u)]
    out: dict[str, set[int]] = {}
    for i in range(0, len(safe), BATCH):
        rows = query_all(client, "external_games",
                         f"fields game,uid; where external_game_source = {src} & uid = ({_quoted(safe[i:i + BATCH])});",
                         cid, tok)
        for r in rows:
            if isinstance(r, dict) and isinstance(r.get("game"), int) and isinstance(r.get("uid"), str):
                out.setdefault(r["uid"], set()).add(r["game"])
    return out


def fetch_all(client: Client, steam_ids: list[str], slugs: dict[str, str] | None = None,
              titles: dict[str, tuple[str, int | None]] | None = None, big: set[str] | None = None,
              stores: dict[str, list[str]] | None = None) -> tuple[dict[str, dict], dict[str, dict]]:
    """(time to beat by Steam id, details by "steam:<id>" / "gog:<id>" / "epic:<id>").
    Details for GOG/Epic ids only cover games no Steam id already gave. Call
    only when `credentials()` is set."""
    cands: dict[str, set[int]] = {}
    ttb = fetch_for_steam(client, steam_ids, slugs, titles, big, cands_out=cands)
    cid, secret = credentials()  # type: ignore[misc]
    tok = token(client, cid, secret)
    try:
        rows = game_details(client, set().union(*cands.values()) if cands else set(), cid, tok)
        details = best_details(cands, rows, "steam", big)
        for store, uids in (stores or {}).items():
            if store not in STORE_SOURCES or not uids:
                continue
            sc = map_by_store(client, store, sorted(set(uids)), cid, tok)
            new = set().union(*sc.values()) - set(rows) if sc else set()
            rows.update(game_details(client, new, cid, tok))
            details.update(best_details(sc, rows, store))
    except GiveUp:
        # out of time: time to beat is still good; details fall back to last night's
        raise PartialDetails(ttb)
    return ttb, details


class PartialDetails(GiveUp):
    """Time to beat finished but the details didn't; `ttb` holds it."""

    def __init__(self, ttb: dict):
        super().__init__("IGDB details ran out of time")
        self.ttb = ttb
