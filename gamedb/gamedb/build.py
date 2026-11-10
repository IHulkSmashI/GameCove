"""Build GameCove's open game database.

    python -m gamedb.build --out dist/gamedb.json.gz

Sources: Wikidata (CC0), AreWeAntiCheatYet (MIT), IGDB time to beat, game
details and critic averages (when the nightly job has credentials), the Steam
store's appdetails (game details and Steam's official Metacritic score for the
popular games, a slice each night) and our own tiers summarised from ProtonDB's
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

from . import coverage, net
from . import ttb as ttb_rules
from .ids import steam_id
from .sources import awacy, igdb, protondb, steamstore, steamtop, wikidata, wikidata_meta

SCHEMA = 2  # game details and critic scores were added as optional fields: old readers ignore them
PREVIOUS_URL = "https://github.com/IHulkSmashI/GameCove/releases/download/gamedb/gamedb.json.gz"
CREDITS = (
    "Game data from IGDB (https://www.igdb.com): time to beat, summaries, genres, themes, game modes, companies, "
    "release dates, screenshots and critic averages; Wikidata (CC0); AreWeAntiCheatYet (MIT); "
    "Steam store data (Valve): descriptions, genres, companies, release dates, controller support; "
    "Metacritic scores as published by Valve on the Steam store, each linking to its Metacritic page "
    "(Metacritic is a trademark of Fandom, Inc.; not affiliated); "
    "compatibility tiers are GameCove's own summary of ProtonDB user reports "
    "(protondb.com, data from github.com/bdefore/protondb-data, ODbL 1.0) and "
    "are not ProtonDB's official ratings; this database's ProtonDB-derived "
    "data is shared under the ODbL 1.0"
)
# Seconds each source may take (also capped by --max-minutes overall).
LIMITS = {"previous": 180, "wikidata": 1800, "steam": 300, "areweanticheatyet": 180, "igdb": 1500, "protondb": 1200,
          "steamstore": 660, "wikidata_meta": 600}
# Fresh source data shorter than this share of last night's is treated as a failure.
MIN_KEEP = 0.9


# ---- merge -----------------------------------------------------------------

def steam_ids_of(rec: dict) -> list[str]:
    """Every Steam app id of a record, the main one first."""
    main = rec["ids"].get("steam")
    rest = [s for s in rec.get("steam_all") or [] if s != main]
    return ([main] if main else []) + rest


def _details_key(rec: dict, details: dict) -> str | None:
    """The key a record's IGDB details are under: a Steam id first, then GOG, then Epic."""
    for sid in steam_ids_of(rec):
        if f"steam:{sid}" in details:
            return f"steam:{sid}"
    for store in ("gog", "epic"):
        v = rec["ids"].get(store)
        if v and f"{store}:{v}" in details:
            return f"{store}:{v}"
    return None


def _game(rec: dict, anticheat: dict, ttb: dict, proton: dict, top: dict,
          details: dict | None = None, store_meta: dict | None = None, wd_meta: dict | None = None) -> dict | None:
    steams = steam_ids_of(rec)

    def first(m: dict):
        return next((m[s] for s in steams if s in m), None)

    ranks = [top[s]["rank"] for s in steams if s in top and isinstance(top[s].get("rank"), int)]
    rank = min(ranks) if ranks else None
    popular = first(top) or {}
    ac = first(anticheat)
    title = rec.get("title") or popular.get("title") or (ac or {}).get("name") or ""
    if not title:
        return None
    ids = {k: v for k, v in rec["ids"].items() if k != "steam_more"}
    if len(steams) > 1:
        ids["steam_more"] = steams[1:]
    g = {
        "title": title,
        "wikidata": rec.get("wikidata"),
        "released": rec.get("released") if rec.get("released") is not None else popular.get("released"),
        "ids": ids,
        "popular": rank,
    }
    if ac:
        g["anticheat"] = {k: ac[k] for k in ("status", "anticheats")}
    t = ttb_rules.pick([ttb.get(s) for s in steams], big=rank is not None)
    if t:
        g["time_to_beat"] = t
    tier = first(proton)
    if tier:
        g["protondb"] = tier
    details, store_meta, wd_meta = details or {}, store_meta or {}, wd_meta or {}
    dk = _details_key(rec, details)
    d = details.get(dk) if dk else None
    sm = first(store_meta)
    w = wd_meta.get(rec.get("wikidata") or "")
    block, critics = {}, {}
    if d and d.get("meta"):
        block["igdb"] = d["meta"]
    if sm:
        block["steam"] = {**(sm.get("meta") or {}), "at": sm.get("at")}
        if sm.get("metacritic"):
            critics["metacritic"] = sm["metacritic"]
    if w:
        block["wikidata"] = w
    if d and d.get("critic"):
        critics["igdb_critic"] = d["critic"]
    if block:
        g["meta"] = block
    if critics:
        g["critics"] = critics
    return g


def merge(items: dict[str, dict], anticheat: dict[str, dict], ttb: dict[str, dict],
          proton: dict[str, str] | None = None, top: dict[str, dict] | None = None,
          details: dict[str, dict] | None = None, store_meta: dict[str, dict] | None = None,
          wd_meta: dict[str, dict] | None = None) -> list[dict]:
    """One record per Wikidata item, plus one per popular Steam game (`top`)
    that no item covers. Time to beat goes through gamedb.ttb's checks.
    Sorted by title; on equal titles the more popular game comes first, so
    the app's title fallback finds it (Resident Evil 4 (2023) before 2005)."""
    proton = proton or {}
    top = top or {}
    games = []
    covered: set[str] = set()
    for rec in items.values():
        covered.update(steam_ids_of(rec))
        g = _game(rec, anticheat, ttb, proton, top, details, store_meta, wd_meta)
        if g:
            games.append(g)
    for sid in sorted(set(top) - covered, key=int):
        rec = {"wikidata": None, "title": top[sid].get("title", ""), "released": top[sid].get("released"),
               "ids": {"steam": sid}}
        g = _game(rec, anticheat, ttb, proton, top, details, store_meta, wd_meta)
        if g:
            games.append(g)
    games.sort(key=lambda g: (g["title"].casefold(), g["popular"] if g["popular"] is not None else 1 << 30,
                              g["wikidata"] or "", g["ids"].get("steam", "")))
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
    out = {"items": {}, "anticheat": {}, "ttb": {}, "protondb": {}, "top": {},
           "details": {}, "store_meta": {}, "wd_meta": {}}
    if not prev:
        return out
    for g in prev.get("games", []):
        if not isinstance(g, dict) or not isinstance(g.get("ids"), dict):
            continue
        steam = steam_id(g["ids"].get("steam"))
        more = [s for s in (steam_id(x) for x in g["ids"].get("steam_more") or []) if s]
        block = g.get("meta") if isinstance(g.get("meta"), dict) else {}
        critics = g.get("critics") if isinstance(g.get("critics"), dict) else {}
        dkey = f"steam:{steam}" if steam else next(
            (f"{s}:{g['ids'][s]}" for s in ("gog", "epic") if g["ids"].get(s)), None)
        if dkey and (isinstance(block.get("igdb"), dict) or isinstance(critics.get("igdb_critic"), dict)):
            d = {"meta": block.get("igdb") or {}}
            if isinstance(critics.get("igdb_critic"), dict):
                d["critic"] = critics["igdb_critic"]
            out["details"][dkey] = d
        if steam and isinstance(block.get("steam"), dict):
            sm = {"meta": {k: v for k, v in block["steam"].items() if k != "at"}, "at": block["steam"].get("at")}
            if isinstance(critics.get("metacritic"), dict):
                sm["metacritic"] = critics["metacritic"]
            out["store_meta"][steam] = sm
        if g.get("wikidata") and isinstance(block.get("wikidata"), dict):
            out["wd_meta"][g["wikidata"]] = block["wikidata"]
        if g.get("wikidata"):
            ids = {k: v for k, v in g["ids"].items() if k != "steam_more"}
            out["items"][g["wikidata"]] = {"wikidata": g["wikidata"], "title": g.get("title", ""),
                                           "released": g.get("released"), "ids": ids,
                                           "steam_all": ([steam] if steam else []) + more}
        if not steam:
            continue
        if isinstance(g.get("popular"), int) and not isinstance(g.get("popular"), bool):
            out["top"][steam] = {"title": g.get("title", ""), "released": g.get("released"), "rank": g["popular"]}
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


def igdb_titles(items: dict[str, dict], top: dict[str, dict]) -> dict[str, tuple[str, int | None]]:
    """Popular games -> (title, release year) for IGDB's last-resort title search,
    most popular first."""
    by_steam = {s: r for r in items.values() for s in steam_ids_of(r)}
    out = {}
    for sid in sorted(top, key=lambda s: (top[s].get("rank", 1 << 30), int(s))):
        rec = by_steam.get(sid, {})
        title = rec.get("title") or top[sid].get("title")
        if title:
            out[sid] = (title, rec.get("released") or top[sid].get("released"))
    return out


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

    top = run.source("steam", lambda: steamtop.fetch(run.client("steam", timeout=60)))
    top = run.fall_back("steam", top, prev["top"])
    for sid in coverage.MUST_HAVE:  # never left out, even with Steam's lists down
        top.setdefault(sid, {"title": "", "released": None, "rank": len(top)})

    ac_raw = run.source("areweanticheatyet", lambda: awacy.fetch(run.client("areweanticheatyet", timeout=60)))
    anticheat = run.fall_back("areweanticheatyet", awacy.by_steam_id(ac_raw) if ac_raw is not None else None,
                              prev["anticheat"])

    steam_ids = {s for r in items.values() for s in steam_ids_of(r)} | set(top)
    slugs = {s: r["ids"]["igdb_slug"] for r in items.values() if r["ids"].get("igdb_slug") for s in steam_ids_of(r)}
    titles = igdb_titles(items, top)
    # GOG / Epic ids of games with no Steam id: IGDB details by those stores' ids
    stores = {s: sorted({r["ids"][s] for r in items.values() if r["ids"].get(s) and not steam_ids_of(r)})
              for s in ("gog", "epic")}
    details = None
    if igdb.credentials():
        def get_igdb():
            try:
                return igdb.fetch_all(run.client("igdb", timeout=60), sorted(steam_ids, key=int), slugs, titles,
                                      set(top), stores)
            except igdb.PartialDetails as e:
                return e.ttb, None

        both = run.source("igdb", get_igdb)
        ttb, details = both if both is not None else (None, None)
        run.status["igdb_details"] = {"status": "ok"} if details is not None else {"status": "failed"}
    else:
        run.status["igdb"] = {"status": "skipped", "error": "no TWITCH_CLIENT_ID / TWITCH_CLIENT_SECRET"}
        run.status["igdb_details"] = {"status": "skipped", "error": "no TWITCH_CLIENT_ID / TWITCH_CLIENT_SECRET"}
        ttb = None
    details = run.fall_back("igdb_details", details, prev["details"])
    # Compare against (and fall back to) only last night's values that pass the
    # same checks, so a fresh run isn't judged "short" for dropping bogus ones.
    prev_ttb = {s: c for s, t in prev["ttb"].items() if (c := ttb_rules.clean(t, big=s in top))}
    ttb = run.fall_back("igdb", ttb, prev_ttb)

    pdb = {}

    def get_proton():
        tiers, name = protondb.fetch(run.client("protondb", timeout=300))
        pdb["dump"] = name
        return tiers

    proton = run.source("protondb", get_proton)
    proton = run.fall_back("protondb", proton, prev["protondb"])
    if "dump" in pdb:
        run.status["protondb"]["dump"] = pdb["dump"]

    # Steam store details: tonight's slice of the popular games, last night's for the rest.
    tonight = steamstore.pick(top, prev["store_meta"])
    fresh_store = run.source("steamstore", lambda: steamstore.fetch(
        run.client("steamstore", timeout=30, attempts=3, min_interval=steamstore.REQUEST_GAP), tonight))
    store_meta = {**prev["store_meta"], **(fresh_store or {})}
    run.status["steamstore"].update(count=len(store_meta), refreshed=len(fresh_store or {}), asked=len(tonight))

    wd_meta = run.source("wikidata_meta", lambda: wikidata_meta.fetch(run.client("wikidata_meta", min_interval=2.0)))
    wd_meta = run.fall_back("wikidata_meta", wd_meta, prev["wd_meta"])

    games = merge(items, anticheat, ttb, proton, top, details, store_meta, wd_meta)
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
