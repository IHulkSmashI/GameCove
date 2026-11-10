"""The most popular Steam games, so the database always covers them.

These are the games players open first, so every one of them gets an entry
even when Wikidata has no item for it (or an item without an English label).
Three keyless Steam Web API lists (Steam Web API Terms of Use,
https://steamcommunity.com/dev/apiterms):

- IStoreQueryService/Query, released games, sort 23: the store's best-reviewed
  order (observed, not documented: Baldur's Gate 3, Elden Ring, Clair Obscur,
  Black Myth: Wukong... at the top), first TOP_PER_LIST games.
- The same, sort 11: the store's popularity order (top sellers / most played,
  observed), first TOP_PER_LIST games.
- ISteamChartsService/GetMostPlayedGames: the top 100 by players right now
  (app ids only).

Result: Steam app id -> {"title", "released" (year or None), "rank"}, where
rank is the best position on any list (0 = most popular). Only the app id,
store name and release year are kept.
"""

from __future__ import annotations

import datetime as dt
import json
import urllib.parse

from ..ids import steam_id
from ..net import Client

QUERY = "https://api.steampowered.com/IStoreQueryService/Query/v1/"
MOST_PLAYED = "https://api.steampowered.com/ISteamChartsService/GetMostPlayedGames/v1/"
SORT_BEST_REVIEWED = 23
SORT_POPULAR = 11
PAGE = 500
TOP_PER_LIST = 1000


def query_url(sort: int, start: int, count: int) -> str:
    body = {
        "query": {"start": start, "count": count, "sort": sort,
                  "filters": {"released_only": True, "type_filters": {"include_games": True}}},
        "context": {"language": "english", "country_code": "US"},
        "data_request": {"include_release": True},
    }
    return QUERY + "?" + urllib.parse.urlencode({"input_json": json.dumps(body, separators=(",", ":"))})


def parse_query(data: dict) -> list[dict]:
    """Store items -> [{"steam", "title", "released"}] in list order."""
    out = []
    for item in (data.get("response") or {}).get("store_items") or []:
        if not isinstance(item, dict) or item.get("success", 1) != 1:
            continue
        sid = steam_id(item.get("appid") or item.get("id"))
        if sid is None:
            continue
        stamp = (item.get("release") or {}).get("steam_release_date")
        year = dt.datetime.fromtimestamp(stamp, dt.timezone.utc).year if isinstance(stamp, int) and stamp > 0 else None
        out.append({"steam": sid, "title": str(item.get("name") or "").strip(), "released": year})
    return out


def parse_most_played(data: dict) -> list[dict]:
    ranks = (data.get("response") or {}).get("ranks") or []
    ranks = sorted((r for r in ranks if isinstance(r, dict)), key=lambda r: r.get("rank", 1 << 30))
    return [{"steam": s, "title": "", "released": None}
            for s in (steam_id(r.get("appid")) for r in ranks) if s is not None]


def combine(lists: list[list[dict]]) -> dict[str, dict]:
    out: dict[str, dict] = {}
    for lst in lists:
        for pos, rec in enumerate(lst):
            cur = out.setdefault(rec["steam"], {"title": "", "released": None, "rank": pos})
            cur["rank"] = min(cur["rank"], pos)
            if not cur["title"] and rec["title"]:
                cur["title"] = rec["title"]
            if cur["released"] is None and rec["released"] is not None:
                cur["released"] = rec["released"]
    return out


def fetch(client: Client, top: int = TOP_PER_LIST) -> dict[str, dict]:
    lists = []
    for sort in (SORT_BEST_REVIEWED, SORT_POPULAR):
        lst: list[dict] = []
        for start in range(0, top, PAGE):
            page = parse_query(json.loads(client.get(query_url(sort, start, min(PAGE, top - start)))))
            lst.extend(page)
            if not page:
                break
        lists.append(lst)
    try:
        lists.append(parse_most_played(json.loads(client.get(MOST_PLAYED))))
    except Exception:  # noqa: BLE001 - the two store lists are enough on their own
        pass
    out = combine(lists)
    if not out:
        raise ValueError("Steam returned no popular games")
    return out
