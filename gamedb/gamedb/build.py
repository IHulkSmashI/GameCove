"""Build GameCove's open game database.

    python -m gamedb.build --out dist/gamedb.json.gz

Sources: Wikidata (CC0), AreWeAntiCheatYet (MIT), IGDB time to beat (when the
nightly job has credentials). ProtonDB ratings come next.
"""

from __future__ import annotations

import argparse
import datetime as dt
import gzip
import json
import os

from .sources import awacy, igdb, wikidata

SCHEMA = 1


def merge(items: dict[str, dict], anticheat: dict[str, dict], ttb: dict[str, dict]) -> list[dict]:
    games = []
    for rec in items.values():
        steam = rec["ids"].get("steam")
        g = {
            "title": rec["title"] or (anticheat.get(steam, {}).get("name") if steam else "") or "",
            "wikidata": rec["wikidata"],
            "released": rec["released"],
            "ids": rec["ids"],
        }
        if steam and steam in anticheat:
            g["anticheat"] = {k: anticheat[steam][k] for k in ("status", "anticheats")}
        if steam and steam in ttb:
            g["time_to_beat"] = ttb[steam]
        if g["title"]:
            games.append(g)
    games.sort(key=lambda g: g["title"].casefold())
    return games


def document(games: list[dict], sources: list[str]) -> dict:
    return {
        "schema": SCHEMA,
        "built": dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "sources": sources,
        "credits": "Wikidata (CC0); AreWeAntiCheatYet (MIT); time to beat from IGDB.com",
        "count": len(games),
        "games": games,
    }


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default="dist/gamedb.json.gz")
    args = ap.parse_args()

    items = wikidata.fetch()
    anticheat = awacy.by_steam_id(awacy.fetch())
    steam_ids = sorted({r["ids"]["steam"] for r in items.values() if "steam" in r["ids"]})
    ttb = igdb.fetch_for_steam(steam_ids)

    sources = ["wikidata", "areweanticheatyet"] + (["igdb"] if ttb else [])
    doc = document(merge(items, anticheat, ttb), sources)
    os.makedirs(os.path.dirname(args.out) or ".", exist_ok=True)
    with gzip.open(args.out, "wt", encoding="utf-8") as f:
        json.dump(doc, f, ensure_ascii=False, separators=(",", ":"))
    print(f"{doc['count']} games -> {args.out} ({', '.join(sources)})")


if __name__ == "__main__":
    main()
