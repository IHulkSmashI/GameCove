"""Upcoming game releases for GameCove's Discover calendar.

Three sources, each turned into the same "release" record:

    {"title": str, "date": "2026-12-04" | "2027-03" | "2027-Q2" | "2027" | "",
     "precision": "day" | "month" | "quarter" | "year" | "tba",
     "ids": {"steam": "...", "igdb": "...", "wikidata": "Q...", "gog": "...", "epic": "..."},
     "art": {"cover": url, "hero": url, "header": url}, "sources": ["steam"]}

- Steam (`steam`): the store's own "coming soon" list through the keyless Steam
  Web API method IStoreQueryService/Query (Steam Web API Terms of Use,
  https://steamcommunity.com/dev/apiterms). Sort 10 is the store's popularity
  order for coming-soon games (observed, not documented); the list gets long
  and obscure fast, so we keep the first STEAM_TOP games. Adult-only titles
  (content descriptors 3 and 4) are left out.
- IGDB (`igdb`): release_dates for PC, only when the nightly job has Twitch
  credentials. Free for non-commercial use under the Twitch Developer Service
  Agreement (https://api-docs.igdb.com/#getting-started); credit IGDB.com.
- Wikidata (`wikidata`): video games (P31 Q7889) with a publication date (P577)
  from two weeks ago on, with its precision. CC0.

Nothing here touches the network except through `net.Client`.
"""

from __future__ import annotations

import datetime as dt
import json
import re
import urllib.parse

from ..ids import steam_id
from ..net import Client
from . import igdb as igdb_auth

STEAM_QUERY = "https://api.steampowered.com/IStoreQueryService/Query/v1/"
STEAM_CDN = "https://shared.akamai.steamstatic.com/store_item_assets/"
STEAM_SORT_POPULAR = 10
STEAM_PAGE = 150
STEAM_TOP = 300
ADULT_DESCRIPTORS = {3, 4}  # Adult Only Sexual Content, Frequent Nudity or Sexual Content
STEAM_PRECISION = {
    "date_full": "day", "date_month": "month", "date_quarter": "quarter", "date_year": "year",
    "text_comingsoon": "tba", "text_tba": "tba",
}

WIKIDATA_ENDPOINT = "https://query.wikidata.org/sparql"
WIKIDATA_PRECISION = {9: "year", 10: "month", 11: "day"}

IGDB_API = "https://api.igdb.com/v4/"
IGDB_PC = 6
IGDB_STEAM_SOURCE = 1
IGDB_PAGES = 6
IGDB_PAGE = 500
IGDB_COVER = "https://images.igdb.com/igdb/image/upload/t_cover_big/{}.jpg"
IGDB_FORMATS = {  # date_format.format strings, and the older integer `category` enum
    "YYYYMMMMDD": "day", "YYYYMMMM": "month", "YYYY": "year",
    "YYYYQ1": "quarter", "YYYYQ2": "quarter", "YYYYQ3": "quarter", "YYYYQ4": "quarter", "TBD": "tba",
    0: "day", 1: "month", 2: "year", 3: "quarter", 4: "quarter", 5: "quarter", 6: "quarter", 7: "tba",
}

KEEP_PAST_DAYS = 14  # "Out now" entries stay on the calendar this long
PRECISION_ORDER = {"day": 0, "month": 1, "quarter": 2, "year": 3, "tba": 4}


# ---- dates -----------------------------------------------------------------

def date_label(when: dt.date | None, precision: str) -> str:
    """The calendar's date string for a date and precision ("" for tba)."""
    if when is None or precision == "tba":
        return ""
    if precision == "day":
        return when.isoformat()
    if precision == "month":
        return f"{when.year:04d}-{when.month:02d}"
    if precision == "quarter":
        return f"{when.year:04d}-Q{(when.month - 1) // 3 + 1}"
    return f"{when.year:04d}"


def period_end(label: str, precision: str) -> dt.date | None:
    """Last day a date string can mean (None for tba)."""
    if precision == "tba" or not label:
        return None
    y = int(label[:4])
    if precision == "day":
        return dt.date.fromisoformat(label)
    if precision == "month":
        m = int(label[5:7])
        nxt = dt.date(y + (m == 12), m % 12 + 1, 1)
        return nxt - dt.timedelta(days=1)
    if precision == "quarter":
        q = int(label[-1])
        m = q * 3
        nxt = dt.date(y + (m == 12), m % 12 + 1, 1)
        return nxt - dt.timedelta(days=1)
    return dt.date(y, 12, 31)


def still_upcoming(rec: dict, today: dt.date) -> bool:
    """True while a release can still be ahead (or came out in the last two weeks)."""
    end = period_end(rec.get("date", ""), rec.get("precision", "tba"))
    return end is None or end >= today - dt.timedelta(days=KEEP_PAST_DAYS)


def sort_key(rec: dict):
    """Calendar order: by date, coarser periods after the exact days inside them, TBA last."""
    p = rec.get("precision", "tba")
    end = period_end(rec.get("date", ""), p)
    return (end is None, end or dt.date.max, PRECISION_ORDER.get(p, 4), rec.get("title", "").casefold())


def normalise(title: str) -> str:
    return re.sub(r"[\W_]+", "", title.casefold())


# ---- Steam -----------------------------------------------------------------

def steam_query_url(start: int, count: int, sort: int = STEAM_SORT_POPULAR) -> str:
    body = {
        "query": {"start": start, "count": count, "sort": sort,
                  "filters": {"coming_soon_only": True, "type_filters": {"include_games": True}}},
        "context": {"language": "english", "country_code": "US"},
        "data_request": {"include_release": True, "include_assets": True},
    }
    return STEAM_QUERY + "?" + urllib.parse.urlencode({"input_json": json.dumps(body, separators=(",", ":"))})


def steam_art(assets: dict | None) -> dict:
    """Cover / hero / header URLs from a store item's `assets` block."""
    if not isinstance(assets, dict) or "asset_url_format" not in assets:
        return {}
    fmt = assets["asset_url_format"]
    out = {}
    for kind, field in (("cover", "library_capsule"), ("hero", "library_hero"), ("header", "header")):
        if assets.get(field):
            out[kind] = STEAM_CDN + fmt.replace("${FILENAME}", assets[field])
    return out


def from_steam_item(item: dict) -> dict | None:
    if not isinstance(item, dict) or item.get("success") != 1 or not item.get("name"):
        return None
    if ADULT_DESCRIPTORS & set(item.get("content_descriptorids") or []):
        return None
    rel = item.get("release") or {}
    stamp = rel.get("steam_release_date")
    display = rel.get("coming_soon_display")
    precision = STEAM_PRECISION.get(display, "day" if stamp else "tba")
    when = dt.datetime.fromtimestamp(stamp, dt.timezone.utc).date() if stamp else None
    if when is None:
        precision = "tba"
    sid = steam_id(item.get("appid") or item.get("id"))
    if sid is None:
        return None
    rec = {"title": item["name"].strip(), "date": date_label(when, precision), "precision": precision,
           "ids": {"steam": sid}, "art": steam_art(item.get("assets")),
           "sources": ["steam"]}
    return rec


def parse_steam(data: dict) -> list[dict]:
    items = (data.get("response") or {}).get("store_items") or []
    return [r for r in (from_steam_item(i) for i in items) if r]


def fetch_steam(client: Client, top: int = STEAM_TOP) -> list[dict]:
    out: list[dict] = []
    for start in range(0, top, STEAM_PAGE):
        out.extend(parse_steam(json.loads(client.get(steam_query_url(start, STEAM_PAGE)))))
    if not out:
        raise ValueError("Steam returned no coming-soon games")
    return out


# ---- Wikidata --------------------------------------------------------------

def wikidata_query(cutoff: dt.date) -> str:
    """Video games with a publication date from `cutoff` on. Kept simple on
    purpose: EXISTS / NOT EXISTS clauses make the public endpoint time out, so
    the PC check happens in parse_wikidata and the "already out earlier" check
    in a second, small query (earlier_query)."""
    c = f'"{cutoff.isoformat()}T00:00:00Z"^^xsd:dateTime'
    return f"""
SELECT ?item ?label ?date ?prec ?steam ?gog ?epic ?plat WHERE {{
  ?item wdt:P31 wd:Q7889 ; p:P577 ?st .
  ?st psv:P577 ?tv .
  ?tv wikibase:timeValue ?date ; wikibase:timePrecision ?prec .
  FILTER(?date >= {c})
  ?item rdfs:label ?label . FILTER(LANG(?label) = "en")
  OPTIONAL {{ ?item wdt:P1733 ?steam }}
  OPTIONAL {{ ?item wdt:P2725 ?gog }}
  OPTIONAL {{ ?item wdt:P6278 ?epic }}
  OPTIONAL {{ ?item wdt:P400 ?plat . VALUES ?plat {{ wd:Q1406 wd:Q388 }} }}
}}
LIMIT 5000
"""


def earlier_query(qids: list[str], cutoff: dt.date) -> str:
    """Which of these items already have a publication date before `cutoff`
    (out somewhere already, e.g. a console release before a PC port)."""
    c = f'"{cutoff.isoformat()}T00:00:00Z"^^xsd:dateTime'
    values = " ".join(f"wd:{q}" for q in qids)
    return f"""
SELECT DISTINCT ?item WHERE {{
  VALUES ?item {{ {values} }}
  ?item wdt:P577 ?d . FILTER(?d < {c})
}}
"""


def parse_wikidata(data: dict) -> list[dict]:
    """One record per item; with several dates, the earliest at its own precision.
    Only PC games: a Steam / GOG / Epic id, or Windows (Q1406) / Linux (Q388) as a platform."""
    items: dict[str, dict] = {}
    pc: set[str] = set()
    for row in data.get("results", {}).get("bindings", []):
        qid = row["item"]["value"].rsplit("/", 1)[-1]
        try:
            when = dt.date.fromisoformat(row["date"]["value"][:10])
            prec = int(row["prec"]["value"])
        except (KeyError, ValueError):
            continue
        precision = WIKIDATA_PRECISION.get(prec)
        if precision is None:
            continue
        rec = items.setdefault(qid, {"title": row["label"]["value"], "date": "", "precision": "tba",
                                     "ids": {"wikidata": qid}, "art": {}, "sources": ["wikidata"],
                                     "_when": None})
        for key in ("steam", "gog", "epic"):
            if key in row:
                value = row[key]["value"]
                if key == "steam":
                    value = steam_id(value)
                    if value is None:
                        continue
                rec["ids"].setdefault(key, value)
                pc.add(qid)
        if "plat" in row:
            pc.add(qid)
        if rec["_when"] is None or when < rec["_when"]:
            rec["_when"] = when
            rec["date"] = date_label(when, precision)
            rec["precision"] = precision
    out = []
    for qid, rec in items.items():
        rec.pop("_when", None)
        if qid in pc:
            out.append(rec)
    return out


def parse_earlier(data: dict) -> set[str]:
    return {row["item"]["value"].rsplit("/", 1)[-1] for row in data.get("results", {}).get("bindings", [])
            if "item" in row}


def _sparql(client: Client, query: str) -> dict:
    from . import sparql
    return sparql.run(client, query)


def fetch_wikidata(client: Client, today: dt.date) -> list[dict]:
    cutoff = today - dt.timedelta(days=KEEP_PAST_DAYS)
    recs = parse_wikidata(_sparql(client, wikidata_query(cutoff)))
    out_already: set[str] = set()
    qids = [r["ids"]["wikidata"] for r in recs]
    for i in range(0, len(qids), 200):
        out_already |= parse_earlier(_sparql(client, earlier_query(qids[i:i + 200], cutoff)))
    return [r for r in recs if r["ids"]["wikidata"] not in out_already]


# ---- IGDB ------------------------------------------------------------------

def igdb_body(since: int, offset: int) -> str:
    return ("fields date,date_format.format,category,human,y,m,game.name,game.cover.image_id,"
            "game.external_games.uid,game.external_games.external_game_source;"
            f" where platform = ({IGDB_PC}) & date > {since} & game.hypes > 0;"
            f" sort date asc; limit {IGDB_PAGE}; offset {offset};")


def from_igdb_row(row: dict) -> dict | None:
    game = row.get("game")
    if not isinstance(game, dict) or not game.get("name"):
        return None
    fmt = row.get("date_format")
    fmt = fmt.get("format") if isinstance(fmt, dict) else None
    precision = IGDB_FORMATS.get(fmt) or IGDB_FORMATS.get(row.get("category"), "day")
    stamp = row.get("date")
    when = dt.datetime.fromtimestamp(stamp, dt.timezone.utc).date() if isinstance(stamp, int) else None
    if when is None:
        precision = "tba"
    ids = {"igdb": str(game.get("id", ""))} if game.get("id") else {}
    for ext in game.get("external_games") or []:
        if isinstance(ext, dict) and ext.get("external_game_source") == IGDB_STEAM_SOURCE and steam_id(ext.get("uid")):
            ids.setdefault("steam", steam_id(ext["uid"]))
    art = {}
    cover = game.get("cover")
    if isinstance(cover, dict) and cover.get("image_id"):
        art["cover"] = IGDB_COVER.format(cover["image_id"])
    return {"title": game["name"].strip(), "date": date_label(when, precision), "precision": precision,
            "ids": ids, "art": art, "sources": ["igdb"]}


def fetch_igdb(client: Client, today: dt.date) -> list[dict]:
    creds = igdb_auth.credentials()
    if not creds:
        raise RuntimeError("TWITCH_CLIENT_ID / TWITCH_CLIENT_SECRET not set")
    cid, secret = creds
    tok = igdb_auth.token(client, cid, secret)
    since = int(dt.datetime.combine(today - dt.timedelta(days=KEEP_PAST_DAYS), dt.time(),
                                    dt.timezone.utc).timestamp())
    out: list[dict] = []
    for page in range(IGDB_PAGES):
        rows = igdb_auth.post(client, "release_dates", igdb_body(since, page * IGDB_PAGE), cid, tok)
        out.extend(r for r in (from_igdb_row(x) for x in rows) if r)
        if len(rows) < IGDB_PAGE:
            break
    return out


# ---- merge -----------------------------------------------------------------

SOURCE_PRIORITY = ["steam", "igdb", "wikidata"]  # whose date wins, when it isn't TBA


def merge(*lists: list[dict], today: dt.date, limit: int = 3000) -> list[dict]:
    """One record per game (Steam id, else normalised title) across sources,
    still upcoming, in calendar order."""
    groups: dict[str, list[dict]] = {}
    title_to_key: dict[str, str] = {}
    for recs in lists:
        for r in recs:
            if "steam" in r["ids"] and steam_id(r["ids"]["steam"]) is None:
                r["ids"] = {k: v for k, v in r["ids"].items() if k != "steam"}  # e.g. last build's file
            steam = r["ids"].get("steam")
            t = normalise(r["title"])
            key = f"steam:{steam}" if steam else title_to_key.get(t, f"title:{t}")
            if steam and t and t not in title_to_key:
                title_to_key[t] = key
                if f"title:{t}" in groups:  # a title-only record seen earlier joins this game
                    groups.setdefault(key, []).extend(groups.pop(f"title:{t}"))
            groups.setdefault(key, []).append(r)
    out = []
    for recs in groups.values():
        recs.sort(key=lambda r: min(SOURCE_PRIORITY.index(s) for s in r["sources"]))
        dated = [r for r in recs if r["precision"] != "tba"] or recs
        best = dated[0]
        rec = {"title": recs[0]["title"], "date": best["date"], "precision": best["precision"],
               "ids": {}, "art": {}, "sources": []}
        for r in recs:
            for k, v in r["ids"].items():
                rec["ids"].setdefault(k, v)
            for k, v in r.get("art", {}).items():
                rec["art"].setdefault(k, v)
            for s in r["sources"]:
                if s not in rec["sources"]:
                    rec["sources"].append(s)
        if still_upcoming(rec, today):
            out.append(rec)
    out.sort(key=sort_key)
    return out[:limit]
