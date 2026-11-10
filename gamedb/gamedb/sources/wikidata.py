"""Titles, release years and cross-store IDs from Wikidata (CC0).

One small SPARQL query per store property keeps each request light enough for
the public endpoint; results are merged by Wikidata item id. Requests go through
`net.Client`, which honours the endpoint's 429 Retry-After (it has asked for
"1 req / min" during outages) and stops at the build's time budget. Any failed
query fails the whole source, so a half-fetched list is never published.
"""

from __future__ import annotations

import json

from ..ids import steam_id
from ..net import Client
from . import sparql

ENDPOINT = sparql.WDQS
# QLever answers a whole property in one go; WDQS needs small pages.
QLEVER_PAGE = 500000

# Wikidata property -> our id key
STORE_PROPERTIES = {
    "P1733": "steam",   # Steam application ID
    "P2725": "gog",     # GOG application ID
    "P6278": "epic",    # Epic Games Store ID
}
EXTRA_PROPERTIES = {
    "P5794": "igdb_slug",  # IGDB game ID (a slug)
    "P2816": "hltb",       # HowLongToBeat ID
}
# Titles: the English label, else the "mul" (default for all languages) label.
# Since 2024 many big games carry their name only as "mul" (Baldur's Gate 3,
# Hollow Knight, God of War...): an English-only query left them untitled, and
# untitled items were dropped from the database.
PAGE = 5000
MIN_PAGE = 500
# The public endpoint stops streaming at its 60 s limit and the JSON arrives
# cut off part-way; a cut-off page is asked again at half the size.


def query_for(prop: str, limit: int, offset: int) -> str:
    return f"""
SELECT ?item ?value ?label ?mul ?date WHERE {{
  ?item wdt:{prop} ?value .
  OPTIONAL {{ ?item rdfs:label ?label . FILTER(LANG(?label) = "en") }}
  OPTIONAL {{ ?item rdfs:label ?mul . FILTER(LANG(?mul) = "mul") }}
  OPTIONAL {{ ?item wdt:P577 ?date }}
}}
ORDER BY ?item
LIMIT {limit} OFFSET {offset}
"""


def run_query(client: Client, query: str, endpoint: str = ENDPOINT) -> dict:
    return sparql.run_at(client, endpoint, query)


def parse_bindings(data: dict, key: str, items: dict[str, dict]) -> int:
    """Fold one result page into `items` (keyed by Q-id). Returns rows read."""
    rows = data.get("results", {}).get("bindings", [])
    for row in rows:
        qid = row["item"]["value"].rsplit("/", 1)[-1]
        value = row["value"]["value"]
        if key == "steam":
            value = steam_id(value)  # it ends up in steam:// URIs: digits only
            if value is None:
                continue
        rec = items.setdefault(qid, {"wikidata": qid, "title": "", "released": None, "ids": {}})
        if key == "steam":
            # An item can list several Steam apps (49 do); keep them all and make
            # the lowest id the main one, so the choice doesn't depend on row order.
            alls = rec.setdefault("steam_all", [])
            if value not in alls:
                alls.append(value)
                alls.sort(key=int)
            rec["ids"]["steam"] = alls[0]
        else:
            rec["ids"].setdefault(key, value)
        if "label" in row:
            rec["title"] = row["label"]["value"]
            rec["title_lang"] = "en"
        elif "mul" in row and rec.get("title_lang") != "en":
            rec["title"] = row["mul"]["value"]
            rec["title_lang"] = "mul"
        if "date" in row:
            year = row["date"]["value"][:4]
            if year.isdigit():
                y = int(year)
                if rec["released"] is None or y < rec["released"]:
                    rec["released"] = y
    return len(rows)


def fetch_page(client: Client, prop: str, size: int, offset: int, endpoint: str = ENDPOINT) -> tuple[dict, int]:
    """One page; on a cut-off (unparseable) answer, retry with half the page
    size down to MIN_PAGE. Returns (data, page size used)."""
    while True:
        try:
            return run_query(client, query_for(prop, size, offset), endpoint), size
        except json.JSONDecodeError:
            if size <= MIN_PAGE:
                raise
            size = max(MIN_PAGE, size // 2)


def fetch(client: Client) -> dict[str, dict]:
    """QLever first (whole properties at once); WDQS in small pages if QLever fails."""
    try:
        return _fetch_from(client, sparql.QLEVER, QLEVER_PAGE)
    except Exception:  # noqa: BLE001
        return _fetch_from(client, sparql.WDQS, PAGE)


def _fetch_from(client: Client, endpoint: str, first_page: int) -> dict[str, dict]:
    items: dict[str, dict] = {}
    for prop, key in {**STORE_PROPERTIES, **EXTRA_PROPERTIES}.items():
        offset = 0
        size = first_page
        while True:
            data, size = fetch_page(client, prop, size, offset, endpoint)
            n = parse_bindings(data, key, items)
            if n < size:
                break
            offset += n
    # Keep only items that are on at least one store we launch from.
    return {q: r for q, r in items.items() if any(k in r["ids"] for k in STORE_PROPERTIES.values())}
