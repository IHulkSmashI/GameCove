import json
from pathlib import Path

from gamedb.build import document, merge
from gamedb.sources import awacy, igdb, wikidata

FIX = Path(__file__).parent / "fixtures"


def wd_page(rows):
    """Shape a list of (qid, value, label, date) like a SPARQL JSON response."""
    bindings = []
    for qid, value, label, date in rows:
        b = {"item": {"value": f"http://www.wikidata.org/entity/{qid}"}, "value": {"value": value}}
        if label:
            b["label"] = {"value": label}
        if date:
            b["date"] = {"value": date}
        bindings.append(b)
    return {"results": {"bindings": bindings}}


def test_wikidata_merges_properties_and_keeps_earliest_year():
    items = {}
    wikidata.parse_bindings(wd_page([
        ("Q1", "976730", "Halo: The Master Chief Collection", "2019-12-03T00:00:00Z"),
        ("Q1", "976730", "Halo: The Master Chief Collection", "2014-11-11T00:00:00Z"),
        ("Q2", "1172470", "Apex Legends", None),
    ]), "steam", items)
    wikidata.parse_bindings(wd_page([("Q1", "1429660412", None, None)]), "gog", items)
    assert items["Q1"]["released"] == 2014
    assert items["Q1"]["ids"] == {"steam": "976730", "gog": "1429660412"}
    assert items["Q2"]["released"] is None


def test_awacy_maps_status_and_skips_entries_without_steam():
    entries = json.loads((FIX / "awacy_sample.json").read_text())
    out = awacy.by_steam_id(entries)
    assert out["976730"]["status"] == "works"
    assert out["1172470"]["status"] == "denied"
    assert "Easy Anti-Cheat" in out["976730"]["anticheats"]
    assert all(v["name"] != "Fortnite" for v in out.values())  # Epic-only entry skipped


def test_igdb_time_to_beat_converts_seconds_and_drops_empty_rows():
    t = igdb.to_time_to_beat({"hastily": 36000, "normally": 72000, "completely": 0, "count": 17})
    assert t == {"main_h": 10.0, "extra_h": 20.0, "complete_h": None, "count": 17, "source": "igdb"}
    assert igdb.to_time_to_beat({"hastily": 0, "normally": 0, "completely": 0}) is None


def test_igdb_skipped_without_credentials(monkeypatch):
    monkeypatch.delenv("TWITCH_CLIENT_ID", raising=False)
    monkeypatch.delenv("TWITCH_CLIENT_SECRET", raising=False)
    assert igdb.fetch_for_steam(["976730"]) == {}


def test_merge_attaches_badges_and_sorts_by_title():
    items = {
        "Q2": {"wikidata": "Q2", "title": "apex legends", "released": 2019, "ids": {"steam": "1172470"}},
        "Q1": {"wikidata": "Q1", "title": "Halo", "released": 2014, "ids": {"steam": "976730"}},
        "Q3": {"wikidata": "Q3", "title": "", "released": None, "ids": {"gog": "1"}},
    }
    ac = {"1172470": {"status": "denied", "anticheats": ["Easy Anti-Cheat"], "name": "Apex Legends"}}
    ttb = {"976730": {"main_h": 10.0, "extra_h": None, "complete_h": None, "count": 3, "source": "igdb"}}
    games = merge(items, ac, ttb)
    assert [g["title"] for g in games] == ["apex legends", "Halo"]  # untitled dropped
    assert games[0]["anticheat"]["status"] == "denied"
    assert games[1]["time_to_beat"]["main_h"] == 10.0
    doc = document(games, ["wikidata"])
    assert doc["count"] == 2 and doc["schema"] == 1
