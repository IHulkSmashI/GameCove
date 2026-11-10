"""The games players open first are always in the database, with sane times.

End to end through build.build() with every API mocked:
- Wikidata: real QLever answers (recorded 2026-11-09) for the builder's query
  shape, limited to these games. Eight of them have only a "mul" label, which
  is why they used to be dropped.
- Steam: real IStoreQueryService/Query (sort 23) and GetMostPlayedGames
  answers (recorded 2026-11-09), trimmed to these games.
- IGDB: synthetic answers in the API's shape (fixtures/popular/igdb.json).
"""
import gzip
import json
import re
import urllib.parse
from pathlib import Path

import pytest

from gamedb import build, coverage, net, ttb
from gamedb.sources import awacy, igdb, protondb, steamtop, wikidata

FIX = Path(__file__).parent / "fixtures" / "popular"

# The showcase games that had no entry (and Forza Horizon 5's "1 h").
SHOWCASE = {
    "1086940": ("Baldur's Gate 3", 2023),
    "367520": ("Hollow Knight", 2017),
    "1593500": ("God of War", 2018),
    "2050650": ("Resident Evil 4", 2023),
    "990080": ("Hogwarts Legacy", 2023),
    "2358720": ("Black Myth: Wukong", 2024),
    "1903340": ("Clair Obscur: Expedition 33", 2025),
    "1030300": ("Hollow Knight: Silksong", 2025),
    "1551360": ("Forza Horizon 5", 2021),
}


def load(name):
    return json.loads((FIX / name).read_text())


IGDB = load("igdb.json")
TTB_ROWS = {r["game_id"]: r for r in IGDB["game_time_to_beats"]}


def ids_in(body, field):
    m = re.search(rf"{field} = \(([^)]*)\)", body)
    return [v.strip().strip('"') for v in m.group(1).split(",")] if m else []


def page(rows, body):
    limit = int(re.search(r"limit (\d+);", body).group(1))
    offset = int(re.search(r"offset (\d+);", body).group(1)) if "offset" in body else 0
    return rows[offset:offset + limit]


class FakeAPIs:
    """Stands in for net.Client and answers like each API would."""
    wikidata_drop: set = set()  # Q-ids to leave out of the Wikidata answers
    igdb_calls: list = []

    def __init__(self, budget, **kw):
        self.budget = budget

    def get(self, url, headers=None, data=None, method=None):
        if url.startswith("https://prev/"):
            raise net.NotFound("HTTP 404 from prev")
        if url.startswith(wikidata.sparql.QLEVER) or url.startswith(wikidata.sparql.WDQS):
            return json.dumps(self.wikidata(url)).encode()
        if url.startswith(steamtop.QUERY):
            q = json.loads(urllib.parse.parse_qs(urllib.parse.urlparse(url).query)["input_json"][0])["query"]
            if q["sort"] == steamtop.SORT_BEST_REVIEWED and q["start"] == 0:
                return (FIX / "steam_query_sort23.json").read_bytes()
            return b'{"response":{"store_items":[]}}'
        if url.startswith(steamtop.MOST_PLAYED):
            return (FIX / "steam_most_played.json").read_bytes()
        if url.startswith(igdb.TOKEN_URL):
            return b'{"access_token":"tok","expires_in":5000000}'
        if url.startswith(igdb.API):
            endpoint = url[len(igdb.API):]
            body = data.decode()
            FakeAPIs.igdb_calls.append((endpoint, body))
            return json.dumps(self.igdb(endpoint, body)).encode()
        raise net.GiveUp(f"unexpected {url}")

    def wikidata(self, url):
        q = urllib.parse.parse_qs(urllib.parse.urlparse(url).query)["query"][0]
        name = "wikidata_p1733.json" if "wdt:P1733 ?value" in q else (
            "wikidata_p5794.json" if "wdt:P5794 ?value" in q else None)
        if name is None:
            return {"results": {"bindings": []}}
        data = load(name)
        data["results"]["bindings"] = [b for b in data["results"]["bindings"]
                                       if b["item"]["value"].rsplit("/", 1)[-1] not in self.wikidata_drop]
        return data

    def igdb(self, endpoint, body):
        if endpoint == "external_games":
            assert "external_game_source = 1" in body
            rows = [{"id": i, "game": g, "uid": u}
                    for i, u in enumerate(ids_in(body, "uid")) for g in IGDB["external_games"].get(u, [])]
            return page(rows, body)
        if endpoint == "games" and body.startswith("search"):
            title = re.match(r'search "([^"]*)";', body).group(1)
            return IGDB["search"].get(title, [])
        if endpoint == "games":
            rows = [{"id": IGDB["games_by_slug"][s], "slug": s} for s in ids_in(body, "slug")
                    if s in IGDB["games_by_slug"]]
            return page(rows, body)
        if endpoint == "game_time_to_beats":
            rows = [TTB_ROWS[int(g)] for g in ids_in(body, "game_id") if int(g) in TTB_ROWS]
            return page(rows, body)
        raise AssertionError(endpoint)


@pytest.fixture
def apis(monkeypatch):
    monkeypatch.setenv("TWITCH_CLIENT_ID", "id")
    monkeypatch.setenv("TWITCH_CLIENT_SECRET", "secret")
    monkeypatch.setattr(igdb.time, "sleep", lambda s: None)
    monkeypatch.setattr(awacy, "fetch", lambda client: [])
    monkeypatch.setattr(protondb, "fetch", lambda client: ({}, "reports_nov1_2026.tar.gz"))
    FakeAPIs.wikidata_drop = set()
    FakeAPIs.igdb_calls = []
    return FakeAPIs


def built(apis):
    doc = build.build(net.Budget(600), apis, previous_url="https://prev/gamedb.json.gz")
    assert doc is not None
    by_steam = coverage.index(doc)
    return doc, by_steam


def test_every_showcase_game_has_an_entry(apis):
    doc, by_steam = built(apis)
    for sid, (title, year) in SHOWCASE.items():
        g = by_steam.get(sid)
        assert g, f"{title} ({sid}) missing"
        assert g["title"] == title and g["released"] == year
        assert isinstance(g["popular"], int)
        assert g.get("time_to_beat"), f"{title} has no time to beat"
    missing, no_ttb = coverage.check(doc, {s: t for s, (t, _) in SHOWCASE.items()})
    assert missing == [] and no_ttb == []
    assert doc["sources"]["steam"]["status"] == "ok" and doc["sources"]["igdb"]["status"] == "ok"


def test_time_to_beat_takes_every_mapping_route_and_the_best_candidate(apis):
    _, g = built(apis)
    assert g["1086940"]["time_to_beat"]["main_h"] == 75.0           # Steam uid
    assert g["367520"]["time_to_beat"]["main_h"] == 27.0            # two IGDB games: more submissions wins
    assert g["1593500"]["time_to_beat"]["main_h"] == 21.0           # Wikidata IGDB slug
    assert g["990080"]["time_to_beat"]["main_h"] == 26.0            # title + year (not the 2030 namesake)
    assert g["1030300"]["time_to_beat"]["main_h"] == 30.0           # out-of-order candidate rejected
    fh5 = g["1551360"]["time_to_beat"]                              # 1 h / 1 h / 132 h from 4 people
    assert fh5.get("main_h") is None and fh5.get("extra_h") is None and fh5["complete_h"] == 132.0
    searches = [b for e, b in apis.igdb_calls if b.startswith("search")]
    assert searches == ['search "Hogwarts Legacy"; fields id,name,first_release_date; limit 10;']


def test_remake_and_original_stay_apart_and_the_popular_one_wins_titles(apis):
    doc, g = built(apis)
    assert g["2050650"]["time_to_beat"]["main_h"] == 16.0 and g["2050650"]["released"] == 2023
    assert g["254700"]["time_to_beat"]["main_h"] == 15.5 and g["254700"]["released"] == 2005
    re4 = [x for x in doc["games"] if x["title"] == "Resident Evil 4"]
    assert [x["ids"]["steam"] for x in re4] == ["2050650", "254700"]  # the app's title index takes the first


def test_popular_game_missing_from_wikidata_still_gets_an_entry(apis):
    apis.wikidata_drop = {"Q126462072"}  # Clair Obscur: Expedition 33
    _, g = built(apis)
    e33 = g["1903340"]
    assert e33["title"] == "Clair Obscur: Expedition 33" and e33["released"] == 2025
    assert "wikidata" not in e33 or e33["wikidata"] is None
    assert e33["time_to_beat"]["main_h"] == 33.0


def test_igdb_pages_when_one_batch_has_more_rows_than_the_limit(apis, monkeypatch):
    monkeypatch.setattr(igdb, "BATCH", 2)
    _, g = built(apis)
    assert g["367520"]["time_to_beat"]["main_h"] == 27.0
    ext = [b for e, b in apis.igdb_calls if e == "external_games"]
    assert any("offset 2;" in b for b in ext)


def test_published_file_round_trips_and_passes_the_coverage_check(apis, tmp_path, monkeypatch):
    doc, _ = built(apis)
    out = tmp_path / "gamedb.json.gz"
    build.write(doc, str(out))
    monkeypatch.setattr(coverage, "MUST_HAVE", {s: t for s, (t, _) in SHOWCASE.items()})
    assert coverage.main([str(out)]) == 0
    # and the next night, with every source down, keeps all of them
    prev = build.from_previous(json.loads(gzip.decompress(out.read_bytes())))
    games = build.merge(prev["items"], prev["anticheat"], prev["ttb"], prev["protondb"], prev["top"])
    assert set(SHOWCASE) <= set(coverage.index({"games": games}))


# ---- units ------------------------------------------------------------------

def test_coverage_check_fails_loudly(tmp_path, capsys):
    out = tmp_path / "g.json.gz"
    out.write_bytes(gzip.compress(json.dumps({"games": [
        {"title": "Portal", "ids": {"steam": "400"}, "time_to_beat": {"main_h": 1.9}}]}).encode()))
    assert coverage.main([str(out)]) == 1
    err = capsys.readouterr().err
    assert "::error::" in err and "Baldur's Gate 3 (Steam 1086940)" in err and "(Steam 400)" not in err


def test_must_have_list_is_big_and_holds_the_showcase():
    assert len(coverage.MUST_HAVE) >= 50
    assert set(SHOWCASE) <= set(coverage.MUST_HAVE)
    assert all(s.isdigit() for s in coverage.MUST_HAVE)


def test_ttb_rules():
    fh5 = {"main_h": 1.0, "extra_h": 1.0, "complete_h": 132.0, "count": 4}
    assert ttb.clean(fh5, big=True) == {"main_h": None, "extra_h": None, "complete_h": 132.0, "count": 4}
    portal = {"main_h": 1.9, "extra_h": 4.1, "complete_h": 7.4, "count": 49}
    assert ttb.clean(portal, big=True) == portal                          # really that short
    assert ttb.clean({"main_h": 3.2, "extra_h": 3.8, "complete_h": 2.3, "count": 11}) is None  # out of order
    assert ttb.clean({"main_h": 35.0, "complete_h": 3206.0, "count": 9})["complete_h"] is None  # live service
    assert ttb.clean({"main_h": 0.1, "count": 1}) is None
    small = {"main_h": 1.5, "count": 2}
    assert ttb.clean(small) == small and ttb.clean(small, big=True) is None
    a = {"main_h": 10.0, "count": 3}
    b = {"main_h": 12.0, "count": 30}
    assert ttb.pick([a, b, None])["main_h"] == 12.0
    assert ttb.pick([{"main_h": 9.0, "extra_h": 1.0, "count": 99}, a])["main_h"] == 10.0


def test_wikidata_mul_label_and_every_steam_id():
    items = {}
    rows = {"results": {"bindings": [
        {"item": {"value": "http://www.wikidata.org/entity/Q1"}, "value": {"value": "500"},
         "mul": {"value": "Mul Name"}},
        {"item": {"value": "http://www.wikidata.org/entity/Q1"}, "value": {"value": "20"},
         "mul": {"value": "Mul Name"}, "label": {"value": "English Name"}},
        {"item": {"value": "http://www.wikidata.org/entity/Q2"}, "value": {"value": "7"},
         "mul": {"value": "Only Mul"}},
    ]}}
    wikidata.parse_bindings(rows, "steam", items)
    assert items["Q1"]["title"] == "English Name"           # English wins
    assert items["Q1"]["ids"]["steam"] == "20" and items["Q1"]["steam_all"] == ["20", "500"]
    assert items["Q2"]["title"] == "Only Mul"               # used to be "" and dropped
    games = build.merge(items, {}, {}, {}, {"500": {"title": "x", "released": None, "rank": 3}})
    q1 = next(g for g in games if g["wikidata"] == "Q1")
    assert q1["ids"]["steam_more"] == ["500"] and q1["popular"] == 3
    assert 'LANG(?mul) = "mul"' in wikidata.query_for("P1733", 10, 0)


def test_steam_lists_combine_best_rank():
    a = steamtop.parse_query(load("steam_query_sort23.json"))
    assert a[0]["steam"] == "1086940" and a[0]["title"] == "Baldur's Gate 3" and a[0]["released"] == 2023
    top = steamtop.combine([a, [{"steam": "367520", "title": "", "released": None}]])
    assert top["367520"]["rank"] == 0 and top["367520"]["title"] == "Hollow Knight"
