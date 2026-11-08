"""Build GameCove's open game database.

    python -m gamedb.build --out dist/gamedb.json.gz

Sources: Wikidata (CC0), AreWeAntiCheatYet (MIT), IGDB time to beat (when the
nightly job has credentials) and our own tiers summarised from ProtonDB's
report dumps (ODbL).

Every source runs inside its own time budget, all inside one overall cap. A
source that fails (or comes back clearly short) is replaced by the same fields
from the previously published gamedb, so one source being down never fails the
build and a nightly never publishes a worse file. What happened to each source
is written to the document's "sources" map.
"""

from __future__ import annotations

import argparse
import datetime as dt
import gzip
import json
import os
import sys
import time
import traceback
from typing import Callable

from . import net
from .sources import awacy, igdb, protondb, wikidata

SCHEMA = 2
PREVIOUS_URL = "https://github.com/IHulkSmashI/GameCove/releases/download/gamedb/gamedb.json.gz"
CREDITS = (
    "Wikidata (CC0); AreWeAntiCheatYet (MIT); time to beat from IGDB.com; "
    "compatibility tiers are GameCove's own summary of ProtonDB user reports "
    "(protondb.com, data from github.com/bdefore/protondb-data, ODbL 1.0) and "
    "are not ProtonDB's official ratings; this database's ProtonDB-derived "
    "data is shared under the ODbL 1.0"
)
# Seconds each source may take (also capped by --max-minutes overall).
LIMITS = {"previous": 180, "wikidata": 1800, "areweanticheatyet": 180, "igdb": 900, "protondb": 1200}
# Fresh source data shorter than this share of last night's is treated as a failure.
MIN_KEEP = 0.9


# ---- merge -----------------------------------------------------------------

def merge(items: dict[str, dict], anticheat: dict[str, dict], ttb: dict[str, dict],
          proton: dict[str, str] | None = None) -> list[dict]:
    proton = proton or {}
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
        if steam and steam in proton:
            g["protondb"] = proton[steam]
        if g["title"]:
            games.append(g)
    games.sort(key=lambda g: g["title"].casefold())
    return games


def compact(value):
    """Drop null fields (and the empty objects/lists that leaves) all the way down.
    Readers treat a missing field as null."""
    if isinstance(value, dict):
        out = {k: compact(v) for k, v in value.items() if v is not None}
        return {k: v for k, v in out.items() if v not in ({}, [])}
    if isinstance(value, list):
        return [compact(v) for v in value if v is not None]
    return value


def document(games: list[dict], sources: dict[str, dict]) -> dict:
    return {
        "schema": SCHEMA,
        "built": dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "sources": sources,
        "credits": CREDITS,
        "count": len(games),
        "games": games,
    }


# ---- the previous published file, as per-source fallbacks ------------------

def parse_previous(raw: bytes) -> dict | None:
    try:
        doc = json.loads(gzip.decompress(raw) if raw[:2] == b"\x1f\x8b" else raw)
    except (OSError, ValueError):
        return None
    if not isinstance(doc, dict) or not isinstance(doc.get("games"), list):
        return None
    return doc


def from_previous(prev: dict | None) -> dict[str, dict]:
    """Split a published document back into the per-source maps merge() takes."""
    out = {"items": {}, "anticheat": {}, "ttb": {}, "protondb": {}}
    if not prev:
        return out
    for g in prev.get("games", []):
        if not isinstance(g, dict) or not g.get("wikidata") or not isinstance(g.get("ids"), dict):
            continue
        out["items"][g["wikidata"]] = {"wikidata": g["wikidata"], "title": g.get("title", ""),
                                       "released": g.get("released"), "ids": g["ids"]}
        steam = g["ids"].get("steam")
        if not steam:
            continue
        ac = g.get("anticheat")
        if isinstance(ac, dict) and ac.get("status"):
            out["anticheat"][steam] = {"status": ac["status"], "anticheats": ac.get("anticheats", []),
                                       "name": g.get("title", "")}
        if isinstance(g.get("time_to_beat"), dict):
            out["ttb"][steam] = g["time_to_beat"]
        if g.get("protondb") in ("platinum", "gold", "silver", "bronze", "borked"):
            out["protondb"][steam] = g["protondb"]
    return out


class Run:
    """Runs sources inside budgets and records what happened to each."""

    def __init__(self, budget: net.Budget, client_factory: Callable[..., net.Client], prev_built: str | None = None):
        self.budget = budget
        self.client_factory = client_factory
        self.prev_built = prev_built
        self.status: dict[str, dict] = {}

    def client(self, name: str, **kw) -> net.Client:
        return self.client_factory(self.budget.child(LIMITS.get(name, 600)), **kw)

    def source(self, name: str, fn: Callable[[], object]):
        """fn() -> data; returns data, or None after recording the failure."""
        t0 = time.monotonic()
        try:
            data = fn()
        except Exception as e:  # one source must never take the build down
            msg = f"{type(e).__name__}: {e}"[:300]
            print(f"[{name}] failed: {msg}", file=sys.stderr)
            if not isinstance(e, (net.GiveUp, ValueError)):
                traceback.print_exc(file=sys.stderr)
            self.status[name] = {"status": "failed", "error": msg}
            return None
        self.status[name] = {"status": "ok", "seconds": round(time.monotonic() - t0)}
        return data

    def fall_back(self, name: str, fresh, previous: dict):
        """What to merge for a source: fresh data, unless it failed or came back
        clearly short of last night's, in which case last night's data."""
        st = self.status.setdefault(name, {"status": "failed"})
        if fresh is not None and previous and len(fresh) < MIN_KEEP * len(previous):
            st.update(status="failed", error=f"only {len(fresh)} entries vs {len(previous)} last time")
            fresh = None
        if fresh is not None:
            st["count"] = len(fresh)
            return fresh
        if previous:
            if st["status"] == "failed":
                st["status"] = "fallback"
            st.update(kept_previous=True, previous_built=self.prev_built, count=len(previous))
            return previous
        return {}


def build(budget: net.Budget, client_factory: Callable[..., net.Client] = net.Client,
          previous_url: str = PREVIOUS_URL) -> dict | None:
    run = Run(budget, client_factory)

    raw = run.source("previous", lambda: run.client("previous", attempts=3, timeout=60).get(previous_url))
    prev_doc = parse_previous(raw) if raw else None
    if raw and prev_doc is None:
        run.status["previous"] = {"status": "failed", "error": "unreadable"}
    run.prev_built = prev_doc.get("built") if prev_doc else None
    if prev_doc:
        run.status["previous"]["count"] = len(prev_doc["games"])
    prev = from_previous(prev_doc)

    items = run.source("wikidata", lambda: wikidata.fetch(run.client("wikidata", min_interval=2.0)))
    items = run.fall_back("wikidata", items, prev["items"])

    ac_raw = run.source("areweanticheatyet", lambda: awacy.fetch(run.client("areweanticheatyet", timeout=60)))
    anticheat = run.fall_back("areweanticheatyet", awacy.by_steam_id(ac_raw) if ac_raw is not None else None,
                              prev["anticheat"])

    steam_ids = sorted({r["ids"]["steam"] for r in items.values() if "steam" in r["ids"]})
    if igdb.credentials():
        ttb = run.source("igdb", lambda: igdb.fetch_for_steam(run.client("igdb", timeout=60), steam_ids))
    else:
        run.status["igdb"] = {"status": "skipped", "error": "no TWITCH_CLIENT_ID / TWITCH_CLIENT_SECRET"}
        ttb = None
    ttb = run.fall_back("igdb", ttb, prev["ttb"])

    pdb = {}

    def get_proton():
        tiers, name = protondb.fetch(run.client("protondb", timeout=300))
        pdb["dump"] = name
        return tiers

    proton = run.source("protondb", get_proton)
    proton = run.fall_back("protondb", proton, prev["protondb"])
    if "dump" in pdb:
        run.status["protondb"]["dump"] = pdb["dump"]

    games = merge(items, anticheat, ttb, proton)
    if not games:
        return None
    return document(games, run.status)


def write(doc: dict, path: str) -> int:
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    body = json.dumps(compact(doc), ensure_ascii=False, separators=(",", ":")).encode()
    with open(path, "wb") as f:
        f.write(gzip.compress(body, compresslevel=9, mtime=0))
    return os.path.getsize(path)


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default="dist/gamedb.json.gz")
    ap.add_argument("--max-minutes", type=float, default=50, help="cap on the whole build")
    ap.add_argument("--previous-url", default=PREVIOUS_URL)
    args = ap.parse_args(argv)

    doc = build(net.Budget(args.max_minutes * 60), previous_url=args.previous_url)
    if doc is None:
        print("no games from any source or the previous file; nothing written", file=sys.stderr)
        return 1
    size = write(doc, args.out)
    summary = ", ".join(f"{k}={v['status']}" for k, v in doc["sources"].items())
    print(f"{doc['count']} games -> {args.out} ({size / 1024:.0f} KiB gzipped) [{summary}]")
    return 0


if __name__ == "__main__":
    sys.exit(main())
