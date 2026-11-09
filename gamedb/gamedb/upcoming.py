"""Build the Discover release calendar and exchange rates.

    python -m gamedb.upcoming --out dist/upcoming.json.gz

Published next to gamedb.json.gz on the rolling "gamedb" release. Sources:
Steam's coming-soon list (Steam Web API, keyless), IGDB release dates (when the
job has Twitch credentials), Wikidata (CC0) and the ECB's euro reference rates.
See gamedb/sources/releases.py and ecb.py for each source's terms.

Like the main build, every source runs in its own time budget and a source that
fails is replaced by what it contributed to the previously published file, so
one source being down never empties the calendar.
"""

from __future__ import annotations

import argparse
import datetime as dt
import gzip
import json
import sys
from typing import Callable

from . import net
from .build import Run, compact, write
from .sources import ecb, igdb, releases

SCHEMA = 1
PREVIOUS_URL = "https://github.com/IHulkSmashI/GameCove/releases/download/gamedb/upcoming.json.gz"
CREDITS = (
    "Game data from IGDB (https://www.igdb.com); release dates also from Steam (store data via the Steam Web API) and Wikidata (CC0); "
    "exchange rates: Source: ECB statistics. Game art belongs to its publishers."
)
LIMITS = {"previous": 120, "steam": 300, "wikidata": 600, "igdb": 600, "ecb": 60}
# Fresh lists shorter than this share of last night's are treated as failures.
MIN_KEEP = 0.5


def parse_previous(raw: bytes) -> dict | None:
    try:
        doc = json.loads(gzip.decompress(raw) if raw[:2] == b"\x1f\x8b" else raw)
    except (OSError, ValueError):
        return None
    return doc if isinstance(doc, dict) and isinstance(doc.get("releases"), list) else None


def previous_for(prev: dict | None, source: str) -> list[dict]:
    """The releases a source contributed last night (with their merged fields)."""
    if not prev or not isinstance(prev.get("releases"), list):
        return []
    out = []
    for r in prev["releases"]:
        if isinstance(r, dict) and source in (r.get("sources") or []) and r.get("title"):
            out.append({"title": r["title"], "date": r.get("date", ""), "precision": r.get("precision", "tba"),
                        "ids": dict(r.get("ids") or {}), "art": dict(r.get("art") or {}), "sources": [source]})
    return out


def document(recs: list[dict], fx: dict | None, sources: dict) -> dict:
    return {
        "schema": SCHEMA,
        "built": dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "sources": sources,
        "credits": CREDITS,
        "fx": fx,
        "count": len(recs),
        "releases": recs,
    }


def build(budget: net.Budget, client_factory: Callable[..., net.Client] = net.Client,
          previous_url: str = PREVIOUS_URL, today: dt.date | None = None) -> dict | None:
    today = today or dt.datetime.now(dt.timezone.utc).date()
    run = Run(budget, client_factory)

    def client(name: str, **kw) -> net.Client:
        return client_factory(budget.child(LIMITS.get(name, 300)), **kw)

    raw = run.source("previous", lambda: client("previous", attempts=3, timeout=60).get(previous_url))
    prev = parse_previous(raw) if raw else None
    if raw and prev is None:
        run.status["previous"] = {"status": "failed", "error": "unreadable"}
    run.prev_built = prev.get("built") if prev else None

    def keep(name: str, fresh):
        old = previous_for(prev, name)
        if fresh is not None and old and len(fresh) < MIN_KEEP * len(old):
            run.status[name].update(status="failed", error=f"only {len(fresh)} entries vs {len(old)} last time")
            fresh = None
        return run.fall_back(name, fresh, old) or []

    steam = keep("steam", run.source("steam", lambda: releases.fetch_steam(client("steam", timeout=60))))
    wd = keep("wikidata", run.source("wikidata", lambda: releases.fetch_wikidata(
        client("wikidata", min_interval=2.0), today)))
    if igdb.credentials():
        ig = run.source("igdb", lambda: releases.fetch_igdb(client("igdb", timeout=60), today))
    else:
        run.status["igdb"] = {"status": "skipped", "error": "no TWITCH_CLIENT_ID / TWITCH_CLIENT_SECRET"}
        ig = None
    ig = keep("igdb", ig)

    fx = run.source("ecb", lambda: ecb.fetch(client("ecb", timeout=30)))
    if fx is None and prev and isinstance(prev.get("fx"), dict):
        fx = prev["fx"]
        run.status["ecb"].update(status="fallback", kept_previous=True, previous_built=run.prev_built)

    recs = releases.merge(steam, ig, wd, today=today)
    if not recs and fx is None:
        return None
    return document(recs, fx, run.status)


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default="dist/upcoming.json.gz")
    ap.add_argument("--max-minutes", type=float, default=15)
    ap.add_argument("--previous-url", default=PREVIOUS_URL)
    args = ap.parse_args(argv)
    doc = build(net.Budget(args.max_minutes * 60), previous_url=args.previous_url)
    if doc is None:
        print("no releases and no exchange rates; nothing written", file=sys.stderr)
        return 1
    size = write(compact(doc), args.out)
    summary = ", ".join(f"{k}={v['status']}" for k, v in doc["sources"].items())
    print(f"{doc['count']} releases -> {args.out} ({size / 1024:.0f} KiB gzipped) [{summary}]")
    return 0


if __name__ == "__main__":
    sys.exit(main())
