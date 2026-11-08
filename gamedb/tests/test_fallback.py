import gzip
import json
from pathlib import Path

from gamedb import build, net
from gamedb.sources import awacy, igdb, protondb, wikidata

FIX = Path(__file__).parent / "fixtures"

PREVIOUS = {
    "schema": 2,
    "built": "2026-11-07T06:30:00Z",
    "games": [
        {"title": "Halo", "wikidata": "Q1", "released": 2014, "ids": {"steam": "976730"},
         "anticheat": {"status": "works", "anticheats": ["Easy Anti-Cheat"]},
         "time_to_beat": {"main_h": 10.0, "count": 3, "source": "igdb"}, "protondb": "gold"},
        {"title": "Apex Legends", "wikidata": "Q2", "ids": {"steam": "1172470"}, "protondb": "borked"},
        {"title": "GOG thing", "wikidata": "Q3", "ids": {"gog": "1"}},
    ],
}


def gz(doc):
    return gzip.compress(json.dumps(doc).encode())


class FakeClient:
    """Stands in for net.Client; answers by URL prefix, raising GiveUp for anything unknown."""
    routes: dict = {}

    def __init__(self, budget, **kw):
        self.budget = budget

    def get(self, url, **kw):
        for prefix, answer in self.routes.items():
            if url.startswith(prefix):
                if isinstance(answer, Exception):
                    raise answer
                return answer
        raise net.GiveUp(f"HTTP 429 from {url}")


def run(monkeypatch, routes, wd_items=None, awacy_list=None, tiers=None):
    monkeypatch.delenv("TWITCH_CLIENT_ID", raising=False)
    monkeypatch.delenv("TWITCH_CLIENT_SECRET", raising=False)
    FakeClient.routes = routes

    def fake_wd(client):
        if wd_items is None:
            client.get(wikidata.ENDPOINT)  # -> GiveUp, like the 1 req/min outage
        return wd_items

    def fake_ac(client):
        if awacy_list is None:
            client.get(awacy.URL)
        return awacy_list

    def fake_pdb(client):
        if tiers is None:
            client.get(protondb.REPO_API)
        return tiers, "reports_nov1_2026.tar.gz"

    monkeypatch.setattr(wikidata, "fetch", fake_wd)
    monkeypatch.setattr(awacy, "fetch", fake_ac)
    monkeypatch.setattr(protondb, "fetch", fake_pdb)
    return build.build(net.Budget(60), FakeClient, previous_url="https://prev/gamedb.json.gz")


def games_by_title(doc):
    return {g["title"]: g for g in doc["games"]}


def test_every_source_down_republishes_previous_data(monkeypatch):
    doc = run(monkeypatch, {"https://prev/": gz(PREVIOUS)})
    g = games_by_title(doc)
    assert set(g) == {"Halo", "Apex Legends", "GOG thing"}
    assert g["Halo"]["anticheat"]["status"] == "works"
    assert g["Halo"]["time_to_beat"]["main_h"] == 10.0
    assert g["Halo"]["protondb"] == "gold" and g["Apex Legends"]["protondb"] == "borked"
    s = doc["sources"]
    assert s["wikidata"]["status"] == "fallback" and "429" in s["wikidata"]["error"]
    assert s["wikidata"]["previous_built"] == "2026-11-07T06:30:00Z"
    assert s["protondb"]["status"] == "fallback"
    assert s["igdb"]["status"] == "skipped" and s["igdb"]["kept_previous"]


def test_fresh_sources_win_and_only_failed_one_falls_back(monkeypatch):
    items = {q: dict(r) for q, r in build.from_previous(PREVIOUS)["items"].items()}
    ac = json.loads((FIX / "awacy_sample.json").read_text())
    doc = run(monkeypatch, {"https://prev/": gz(PREVIOUS)}, wd_items=items, awacy_list=ac, tiers=None)
    g = games_by_title(doc)
    assert doc["sources"]["wikidata"]["status"] == "ok"
    assert doc["sources"]["areweanticheatyet"]["status"] == "ok"
    assert g["Apex Legends"]["anticheat"]["status"] == "denied"  # fresh, wasn't in previous
    assert g["Halo"]["protondb"] == "gold"                     # ProtonDB fell back
    assert doc["sources"]["protondb"]["status"] == "fallback"


def test_fresh_protondb_replaces_previous(monkeypatch):
    doc = run(monkeypatch, {"https://prev/": gz(PREVIOUS)},
              tiers={"976730": "platinum", "1172470": "silver"})
    g = games_by_title(doc)
    assert g["Halo"]["protondb"] == "platinum"
    assert doc["sources"]["protondb"] == {"status": "ok", "seconds": 0, "count": 2,
                                          "dump": "reports_nov1_2026.tar.gz"}


def test_shrunken_source_is_treated_as_failure(monkeypatch):
    doc = run(monkeypatch, {"https://prev/": gz(PREVIOUS)}, tiers={"976730": "platinum"})
    assert doc["sources"]["protondb"]["status"] == "fallback"
    assert "only 1" in doc["sources"]["protondb"]["error"]
    assert games_by_title(doc)["Apex Legends"]["protondb"] == "borked"


def test_no_previous_and_wikidata_down_builds_nothing(monkeypatch):
    assert run(monkeypatch, {}) is None


def test_no_previous_still_builds_from_fresh_sources(monkeypatch):
    items = {"Q9": {"wikidata": "Q9", "title": "Brotato", "released": 2023, "ids": {"steam": "1942280"}}}
    doc = run(monkeypatch, {}, wd_items=items, tiers={"1942280": "platinum"})
    assert doc["sources"]["previous"]["status"] == "failed"
    assert doc["sources"]["areweanticheatyet"]["status"] == "failed"
    assert doc["games"][0]["protondb"] == "platinum"


def test_write_drops_nulls_and_gzips(tmp_path):
    games = build.merge({"Q1": {"wikidata": "Q1", "title": "Halo", "released": None, "ids": {"steam": "1"}}},
                        {}, {"1": {"main_h": 1.0, "extra_h": None, "complete_h": None, "count": 2, "source": "igdb"}})
    out = tmp_path / "g.json.gz"
    size = build.write(build.document(games, {"wikidata": {"status": "ok"}}), str(out))
    assert size == out.stat().st_size > 0
    doc = json.loads(gzip.decompress(out.read_bytes()))
    g = doc["games"][0]
    assert "released" not in g
    assert g["time_to_beat"] == {"main_h": 1.0, "count": 2, "source": "igdb"}


def test_previous_parser_rejects_junk():
    assert build.parse_previous(b"not json") is None
    assert build.parse_previous(gz({"games": "nope"})) is None
    assert build.parse_previous(gz(PREVIOUS))["built"] == PREVIOUS["built"]
