"""Titles, release years and cross-store IDs from Wikidata (CC0).

One small SPARQL query per store property keeps each request light enough for
the public endpoint; results are merged by Wikidata item id.
"""

from __future__ import annotations

import json
import time
import urllib.parse
import urllib.request

ENDPOINT = "https://query.wikidata.org/sparql"
USER_AGENT = "GameCove-gamedb/0.1 (https://github.com/IHulkSmashI/gamecove)"

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
PAGE = 25000


def query_for(prop: str, limit: int, offset: int) -> str:
    return f"""
SELECT ?item ?value ?label ?date WHERE {{
  ?item wdt:{prop} ?value .
  OPTIONAL {{ ?item rdfs:label ?label . FILTER(LANG(?label) = "en") }}
  OPTIONAL {{ ?item wdt:P577 ?date }}
}}
ORDER BY ?item
LIMIT {limit} OFFSET {offset}
"""


def run_query(sparql: str, retries: int = 3) -> dict:
    url = ENDPOINT + "?" + urllib.parse.urlencode({"query": sparql, "format": "json"})
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT, "Accept": "application/sparql-results+json"})
    for attempt in range(retries):
        try:
            with urllib.request.urlopen(req, timeout=120) as r:
                return json.load(r)
        except Exception:
            if attempt == retries - 1:
                raise
            time.sleep(10 * (attempt + 1))
    return {}


def parse_bindings(data: dict, key: str, items: dict[str, dict]) -> int:
    """Fold one result page into `items` (keyed by Q-id). Returns rows read."""
    rows = data.get("results", {}).get("bindings", [])
    for row in rows:
        qid = row["item"]["value"].rsplit("/", 1)[-1]
        rec = items.setdefault(qid, {"wikidata": qid, "title": "", "released": None, "ids": {}})
        value = row["value"]["value"]
        rec["ids"].setdefault(key, value)
        if not rec["title"] and "label" in row:
            rec["title"] = row["label"]["value"]
        if "date" in row:
            year = row["date"]["value"][:4]
            if year.isdigit():
                y = int(year)
                if rec["released"] is None or y < rec["released"]:
                    rec["released"] = y
    return len(rows)


def fetch(pause: float = 2.0) -> dict[str, dict]:
    items: dict[str, dict] = {}
    for prop, key in {**STORE_PROPERTIES, **EXTRA_PROPERTIES}.items():
        offset = 0
        while True:
            n = parse_bindings(run_query(query_for(prop, PAGE, offset)), key, items)
            if n < PAGE:
                break
            offset += PAGE
            time.sleep(pause)
    # Keep only items that are on at least one store we launch from.
    return {q: r for q, r in items.items() if any(k in r["ids"] for k in STORE_PROPERTIES.values())}
