"""Game details and critic scores in the nightly file.

- Steam: real appdetails answers (recorded 2026-11-09) for Hades, Baldur's
  Gate 3 and Resident Evil 4 (2023).
- IGDB: synthetic answers in the API's shape (fixtures/meta/igdb_*.json).
- Wikidata: a SPARQL answer in the endpoint's shape.
No test touches the network.
"""
import gzip
import json
import re
from pathlib import Path

import pytest

from gamedb import build, meta, net
from gamedb.sources import awacy, igdb, protondb, steamstore, steamtop, wikidata, wikidata_meta

FIX = Path(__file__).parent / "fixtures" / "meta"


def appdetails(appid):
    return (FIX / f"appdetails_{appid}.json").read_bytes()


# ---- units -----------------------------------------------------------------

def test_steam_appdetails_gives_details_and_metacritic():
    hades = steamstore.parse("1145360", appdetails("1145360"))
    assert hades["metacritic"] == {"score": 93, "url": "https://www.metacritic.com/game/pc/hades"}
    m = hades["meta"]
    assert m["genres"] == ["Action", "Indie", "RPG"]
    assert m["developers"] == ["Supergiant Games"] and m["publishers"] == ["Supergiant Games"]
    assert m["release_date"] == "2020-09-17"
    assert m["controller"] == "full"
    assert m["summary"].startswith("Defy the god of the dead") and "<" not in m["summary"]
    bg3 = steamstore.parse("1086940", appdetails("1086940"))
    assert bg3["metacritic"]["score"] == 96 and bg3["meta"]["developers"] == ["Larian Studios"]
    assert steamstore.parse("999999999", appdetails("missing")) is None
    assert steamstore.parse("1", b"<html>") is None


def test_metacritic_block_is_checked():
    assert meta.metacritic({"score": 75, "url": "http://www.metacritic.com/game/pc/x?ftag=1"}) == \
        {"score": 75, "url": "https://www.metacritic.com/game/pc/x"}
    assert meta.metacritic({"score": 75, "url": "https://evil.example/metacritic.com"}) == {"score": 75}
    assert meta.metacritic({"score": 0}) is None and meta.metacritic({"score": 101}) is None
    assert meta.metacritic("93") is None


def test_dates_and_text():
    assert meta.steam_date("3 Aug, 2023") == "2023-08-03"
    assert meta.steam_date("Sep 17, 2020") == "2020-09-17"
    assert meta.steam_date("Q4 2026") is None and meta.steam_date("Coming soon") is None
    assert meta.iso_date(1600300800) == "2020-09-17"
    long = "A sentence. " * 80
    s = meta.summary(long)
    assert len(s) <= meta.SUMMARY_MAX and s.endswith(".")
    assert meta.clean_list(["A", "a", " B ", "", None, "C"], 2) == ["A", "B"]


def test_igdb_details_pick_the_richest_game_and_credit_screens_only_for_popular():
    rows = {r["id"]: r for r in json.loads((FIX / "igdb_games.json").read_text())}
    out = igdb.best_details({"1145360": {113112, 5000}, "292030": {1942}}, rows, "steam", {"1145360"})
    h = out["steam:1145360"]
    assert h["critic"] == {"score": 93, "count": 37}
    assert h["meta"]["genres"][:2] == ["Role-playing (RPG)", "Hack and slash/Beat 'em up"]
    assert h["meta"]["themes"] == ["Action", "Fantasy"] and h["meta"]["modes"] == ["Single player"]
    assert h["meta"]["release_date"] == "2020-09-17"
    assert h["meta"]["screens"] == ["https://images.igdb.com/igdb/image/upload/t_screenshot_med/sc8ivc.jpg",
                                    "https://images.igdb.com/igdb/image/upload/t_screenshot_med/sc8ivd.jpg"]
    w = out["steam:292030"]
    assert w["meta"]["summary"] == "RPG & open world."
    assert w["meta"]["developers"] == ["CD Projekt RED"]
    assert w["meta"]["publishers"] == ["CD Projekt", "Warner Bros. Interactive"]
    assert "screens" not in w["meta"]


def test_wikidata_genres_are_tidied():
    out = {}
    wikidata_meta.parse(json.loads((FIX / "wikidata_genres.json").read_text()), "genres", out)
    assert out["Q107393"]["genres"] == ["Action role-playing", "Open world"]   # bare Q-id label dropped
    assert out["Q900"]["genres"] == ["Roguelike"]
    assert "wdt:P1733 wdt:P2725 wdt:P6278" in wikidata_meta.query_for("P136")


def test_steam_slice_prefers_new_then_oldest():
    popular = {"1": {"rank": 2}, "2": {"rank": 0}, "3": {"rank": 1}, "4": {"rank": 3}}
    prev = {"3": {"at": "2026-11-01"}, "4": {"at": "2026-10-01"}}
    assert steamstore.pick(popular, prev, 3) == ["2", "1", "4"]


# ---- end to end through build.build() --------------------------------------

class Fake:
    """Answers like each API; everything not listed is an empty answer."""
    steam_down = False
    previous: bytes | None = None   # last night's published file

    def __init__(self, budget, **kw):
        self.budget = budget

    def get(self, url, headers=None, data=None, method=None):
        if url.startswith("https://prev/"):
            if Fake.previous is None:
                raise net.NotFound("no previous")
            return Fake.previous
        if url.startswith(wikidata.sparql.QLEVER) or url.startswith(wikidata.sparql.WDQS):
            if "wdt:P1733 ?value" in url or "wdt%3AP1733+%3Fvalue" in url:
                return json.dumps({"results": {"bindings": [
                    {"item": {"value": "http://www.wikidata.org/entity/Q1"}, "value": {"value": "1145360"},
                     "label": {"value": "Hades"}, "date": {"value": "2020-09-17T00:00:00Z"}},
                ]}}).encode()
            if "wdt%3AP2725+%3Fvalue" in url:
                return json.dumps({"results": {"bindings": [
                    {"item": {"value": "http://www.wikidata.org/entity/Q2"}, "value": {"value": "1207664663"},
                     "label": {"value": "The Witcher 3: Wild Hunt"}},
                ]}}).encode()
            if "wdt%3AP136" in url:
                return json.dumps({"results": {"bindings": [
                    {"item": {"value": "http://www.wikidata.org/entity/Q2"}, "label": {"value": "action role-playing video game"}},
                ]}}).encode()
            return b'{"results":{"bindings":[]}}'
        if url.startswith(steamtop.QUERY):
            return json.dumps({"response": {"store_items": [
                {"appid": 1145360, "name": "Hades", "success": 1}]}}).encode()
        if url.startswith(steamtop.MOST_PLAYED):
            return b'{"response":{"ranks":[]}}'
        if url.startswith(steamstore.URL):
            if Fake.steam_down:
                raise net.GiveUp("HTTP 429")
            appid = re.search(r"appids=(\d+)", url).group(1)
            p = FIX / f"appdetails_{appid}.json"
            return p.read_bytes() if p.exists() else json.dumps({appid: {"success": False}}).encode()
        if url.startswith(igdb.TOKEN_URL):
            return b'{"access_token":"tok"}'
        if url.startswith(igdb.API):
            return json.dumps(self.igdb(url[len(igdb.API):], data.decode())).encode()
        raise net.GiveUp(f"unexpected {url}")

    def igdb(self, endpoint, body):
        if endpoint == "external_games" and "external_game_source = 1 " in body:
            return [{"id": 1, "game": 113112, "uid": "1145360"}] if '"1145360"' in body and "offset 0" in body else []
        if endpoint == "external_games" and "external_game_source = 5 " in body:
            return json.loads((FIX / "igdb_external_gog.json").read_text()) if "offset 0" in body else []
        if endpoint == "games" and body.startswith("fields id,slug,summary"):
            want = {int(x) for x in re.search(r"id = \(([^)]*)\)", body).group(1).split(",")}
            return [r for r in json.loads((FIX / "igdb_games.json").read_text()) if r["id"] in want] \
                if "offset 0" in body else []
        return []


@pytest.fixture
def fake(monkeypatch):
    monkeypatch.setenv("TWITCH_CLIENT_ID", "id")
    monkeypatch.setenv("TWITCH_CLIENT_SECRET", "secret")
    monkeypatch.setattr(igdb.time, "sleep", lambda s: None)
    monkeypatch.setattr(awacy, "fetch", lambda client: [])
    monkeypatch.setattr(protondb, "fetch", lambda client: ({}, "d"))
    monkeypatch.setattr(net.time, "sleep", lambda s: None)
    Fake.steam_down = False
    Fake.previous = None
    return Fake


def by_title(doc):
    return {g["title"]: g for g in doc["games"]}


def test_build_adds_details_and_critic_scores(fake):
    doc = build.build(net.Budget(600), fake, previous_url="https://prev/x")
    g = by_title(doc)
    hades = g["Hades"]
    assert hades["critics"]["metacritic"] == {"score": 93, "url": "https://www.metacritic.com/game/pc/hades"}
    assert hades["critics"]["igdb_critic"] == {"score": 93, "count": 37}
    assert hades["meta"]["steam"]["genres"] == ["Action", "Indie", "RPG"] and hades["meta"]["steam"]["at"]
    assert hades["meta"]["igdb"]["themes"] == ["Action", "Fantasy"]
    assert hades["meta"]["igdb"]["screens"]       # popular: screenshots kept
    w3 = g["The Witcher 3: Wild Hunt"]           # GOG only: details by IGDB's GOG id, Wikidata genres
    assert w3["meta"]["igdb"]["developers"] == ["CD Projekt RED"]
    assert w3["critics"]["igdb_critic"]["score"] == 92
    assert w3["meta"]["wikidata"]["genres"] == ["Action role-playing"]
    assert "metacritic" not in w3.get("critics", {})
    for s in ("igdb_details", "steamstore", "wikidata_meta"):
        assert doc["sources"][s]["status"] == "ok", (s, doc["sources"][s])
    assert "Metacritic" in doc["credits"] and "Game data from IGDB" in doc["credits"]
    assert "OpenCritic" not in json.dumps(doc), "OpenCritic data is never redistributed (CREDITS.md)"


def test_next_night_keeps_details_when_sources_are_down(fake, tmp_path, monkeypatch):
    doc = build.build(net.Budget(600), fake, previous_url="https://prev/x")
    out = tmp_path / "g.json.gz"
    build.write(doc, str(out))
    prev = build.from_previous(json.loads(gzip.decompress(out.read_bytes())))
    assert prev["store_meta"]["1145360"]["metacritic"]["score"] == 93
    assert prev["details"]["steam:1145360"]["critic"]["count"] == 37
    assert prev["details"]["gog:1207664663"]["meta"]["developers"] == ["CD Projekt RED"]
    # with IGDB gone and Steam refusing, the previous file's values are published again
    monkeypatch.delenv("TWITCH_CLIENT_ID")
    fake.steam_down = True
    fake.previous = out.read_bytes()
    doc2 = build.build(net.Budget(600), fake, previous_url="https://prev/x")
    h = by_title(doc2)["Hades"]
    assert h["critics"]["metacritic"]["score"] == 93 and h["critics"]["igdb_critic"]["score"] == 93
    assert doc2["sources"]["igdb_details"]["status"] in ("skipped", "fallback")

