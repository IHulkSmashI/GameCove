"""Genres, developers and publishers from Wikidata (CC0), the last fallback
for game details when neither IGDB nor the Steam store has them.

One query per property over every item that has a Steam, GOG or Epic id,
with the value's English label (else its "mul" label). Same endpoints and
retry rules as gamedb.sources.wikidata: QLever first, the public WDQS if it
fails.
"""

from __future__ import annotations

from .. import meta
from ..net import Client
from . import sparql

PROPERTIES = {"P136": "genres", "P178": "developers", "P123": "publishers"}
# Wikidata's genre items are named for the encyclopaedia ("role-playing video game");
# shorten the common suffixes so a badge reads like a store's ("Role-playing").
_SUFFIXES = (" video game genre", " video game", " game")


def query_for(prop: str) -> str:
    return f"""
SELECT ?item ?label ?mul WHERE {{
  VALUES ?store {{ wdt:P1733 wdt:P2725 wdt:P6278 }}
  ?item ?store [] .
  ?item wdt:{prop} ?v .
  OPTIONAL {{ ?v rdfs:label ?label . FILTER(LANG(?label) = "en") }}
  OPTIONAL {{ ?v rdfs:label ?mul . FILTER(LANG(?mul) = "mul") }}
}}
"""


def tidy(field: str, name: str) -> str:
    if field != "genres":
        return name
    low = name.casefold()
    for suf in _SUFFIXES:
        if low.endswith(suf) and len(name) > len(suf):
            name = name[: -len(suf)]
            break
    return name[:1].upper() + name[1:]


def parse(data: dict, field: str, out: dict[str, dict]) -> None:
    for row in data.get("results", {}).get("bindings", []):
        qid = row.get("item", {}).get("value", "").rsplit("/", 1)[-1]
        name = (row.get("label") or row.get("mul") or {}).get("value", "")
        if not qid.startswith("Q") or not name or name.startswith("Q") and name[1:].isdigit():
            continue
        rec = out.setdefault(qid, {})
        vals = rec.setdefault(field, [])
        name = tidy(field, meta.clean_text(name))
        if name and name not in vals and len(vals) < meta.LIST_MAX:
            vals.append(name)


def fetch(client: Client) -> dict[str, dict]:
    """Wikidata item id -> {"genres": [...], "developers": [...], "publishers": [...]}."""
    out: dict[str, dict] = {}
    for prop, field in PROPERTIES.items():
        parse(sparql.run(client, query_for(prop)), field, out)
    return {q: meta.compact(m) for q, m in out.items() if meta.compact(m)}
