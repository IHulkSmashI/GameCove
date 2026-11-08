import datetime as dt
import gzip
import json
from pathlib import Path

from gamedb import net, upcoming
from gamedb.sources import ecb, igdb, releases

FIX = Path(__file__).parent / "fixtures"
TODAY = dt.date(2026, 11, 8)


def steam_fixture():
    return json.loads((FIX / "steam_coming_soon.json").read_text())


def test_steam_items_become_releases_with_precision_and_art():
    recs = {r["ids"]["steam"]: r for r in releases.parse_steam(steam_fixture())}
    fm = recs["4530370"]
    assert fm["title"] == "Football Manager 27"
    assert (fm["date"], fm["precision"]) == ("2026-11-10", "day")
    assert fm["art"]["cover"].startswith("https://shared.akamai.steamstatic.com/store_item_assets/steam/apps/4530370/")
    assert fm["art"]["cover"].split("?")[0].endswith("/library_capsule.jpg")  # newer, hashed asset paths
    gc = recs["1675880"]["art"]
    assert gc["cover"].split("?")[0].endswith("/1675880/library_600x900.jpg") and gc["hero"] and gc["header"]
    assert (recs["3463440"]["date"], recs["3463440"]["precision"]) == ("2026-Q4", "quarter")
    assert (recs["1676990"]["date"], recs["1676990"]["precision"]) == ("2028", "year")
    assert (recs["1675880"]["date"], recs["1675880"]["precision"]) == ("", "tba")  # "Coming soon"
    assert recs["1676280"]["precision"] == "tba"
    assert recs["1678830"]["precision"] == "tba"  # no release block at all
    assert "4442740" not in recs  # adult-only descriptors are left out


def test_steam_month_precision_and_query_url():
    item = {"success": 1, "appid": 5, "name": "X ", "release": {"steam_release_date": 1796025600,
                                                                "coming_soon_display": "date_month"}}
    rec = releases.from_steam_item(item)
    assert (rec["title"], rec["date"], rec["precision"]) == ("X", "2026-11", "month")
    url = releases.steam_query_url(150, 150)
    assert url.startswith(releases.STEAM_QUERY) and "coming_soon_only" in url and "key=" not in url
    assert releases.from_steam_item({"success": 15}) is None


def test_period_end_and_still_upcoming():
    assert releases.period_end("2026-02", "month") == dt.date(2026, 2, 28)
    assert releases.period_end("2026-12", "month") == dt.date(2026, 12, 31)
    assert releases.period_end("2026-Q4", "quarter") == dt.date(2026, 12, 31)
    assert releases.period_end("2027-Q1", "quarter") == dt.date(2027, 3, 31)
    assert releases.period_end("2027", "year") == dt.date(2027, 12, 31)
    assert releases.period_end("", "tba") is None
    assert releases.still_upcoming({"date": "2026-10-30", "precision": "day"}, TODAY)  # out 9 days ago
    assert not releases.still_upcoming({"date": "2026-10-01", "precision": "day"}, TODAY)
    assert releases.still_upcoming({"date": "2026-Q4", "precision": "quarter"}, TODAY)
    assert not releases.still_upcoming({"date": "2026-Q2", "precision": "quarter"}, TODAY)
    assert releases.still_upcoming({"date": "", "precision": "tba"}, TODAY)


def wd_row(qid, label, date, prec, pc=True, **ids):
    row = {"item": {"value": f"http://www.wikidata.org/entity/{qid}"}, "label": {"value": label},
           "date": {"value": date}, "prec": {"value": str(prec)}}
    if pc:
        row["plat"] = {"value": "http://www.wikidata.org/entity/Q1406"}
    for k, v in ids.items():
        row[k] = {"value": v}
    return row


def test_wikidata_parse_keeps_earliest_date_and_ids():
    data = {"results": {"bindings": [
        wd_row("Q1", "Game One", "2027-03-01T00:00:00Z", 10, steam="111"),
        wd_row("Q1", "Game One", "2027-02-14T00:00:00Z", 11, gog="9"),
        wd_row("Q2", "Game Two", "2028-01-01T00:00:00Z", 9),
        wd_row("Q3", "Bad", "2028-01-01T00:00:00Z", 7),  # decade precision: skipped
        wd_row("Q4", "Console Only", "2026-11-19T00:00:00Z", 11, pc=False),
        wd_row("Q5", "Store Id Only", "2026-12-01T00:00:00Z", 11, pc=False, epic="abc"),
    ]}}
    recs = {r["ids"]["wikidata"]: r for r in releases.parse_wikidata(data)}
    assert (recs["Q1"]["date"], recs["Q1"]["precision"]) == ("2027-02-14", "day")
    assert recs["Q1"]["ids"] == {"wikidata": "Q1", "steam": "111", "gog": "9"}
    assert (recs["Q2"]["date"], recs["Q2"]["precision"]) == ("2028", "year")
    assert "Q3" not in recs
    assert "Q4" not in recs  # not on PC
    assert "Q5" in recs  # a PC store id is enough
    q = releases.wikidata_query(dt.date(2026, 10, 25))
    assert '"2026-10-25T00:00:00Z"^^xsd:dateTime' in q and "wd:Q7889" in q and "wd:Q1406" in q
    assert "EXISTS" not in q  # those make the public endpoint time out
    e = releases.earlier_query(["Q1", "Q2"], dt.date(2026, 10, 25))
    assert "VALUES ?item { wd:Q1 wd:Q2 }" in e


def test_wikidata_fetch_drops_games_already_out():
    class C:
        def __init__(self):
            self.urls = []

        def get(self, url, headers=None):
            self.urls.append(url)
            if "VALUES+%3Fitem" in url:
                return json.dumps({"results": {"bindings": [
                    {"item": {"value": "http://www.wikidata.org/entity/Q1"}}]}}).encode()
            return json.dumps({"results": {"bindings": [
                wd_row("Q1", "Console First", "2027-02-01T00:00:00Z", 11),
                wd_row("Q2", "New Game", "2027-03-01T00:00:00Z", 10),
            ]}}).encode()

    c = C()
    recs = releases.fetch_wikidata(c, TODAY)
    assert [r["title"] for r in recs] == ["New Game"]
    assert len(c.urls) == 2


def test_igdb_rows_use_date_format_and_steam_ids():
    rows = [
        {"date": 1798675200, "date_format": {"format": "YYYYQ4"},
         "game": {"id": 7, "name": "Quarter Game", "cover": {"image_id": "abc"},
                  "external_games": [{"uid": "222", "external_game_source": 1},
                                     {"uid": "x", "external_game_source": 5}]}},
        {"date": 1794268800, "category": 0, "game": {"id": 8, "name": "Day Game"}},
        {"game": {"id": 9, "name": "No Date"}},
        {"date": 1, "game": 5},
    ]
    recs = [releases.from_igdb_row(r) for r in rows]
    assert recs[0]["precision"] == "quarter" and recs[0]["date"] == "2026-Q4"
    assert recs[0]["ids"] == {"igdb": "7", "steam": "222"}
    assert recs[0]["art"]["cover"] == "https://images.igdb.com/igdb/image/upload/t_cover_big/abc.jpg"
    assert (recs[1]["date"], recs[1]["precision"]) == ("2026-11-10", "day")
    assert recs[2]["precision"] == "tba" and recs[3] is None
    body = releases.igdb_body(100, 500)
    assert "platform = (6)" in body and "offset 500" in body


def test_merge_prefers_steam_dates_joins_by_id_and_title_and_sorts():
    steam = [
        {"title": "Alpha", "date": "", "precision": "tba", "ids": {"steam": "1"}, "art": {"cover": "s"}, "sources": ["steam"]},
        {"title": "Beta", "date": "2026-12-01", "precision": "day", "ids": {"steam": "2"}, "art": {}, "sources": ["steam"]},
        {"title": "Old", "date": "2026-09-01", "precision": "day", "ids": {"steam": "3"}, "art": {}, "sources": ["steam"]},
    ]
    igdb_recs = [
        {"title": "Alpha", "date": "2027-Q1", "precision": "quarter", "ids": {"igdb": "10", "steam": "1"},
         "art": {"cover": "i"}, "sources": ["igdb"]},
        {"title": "Gamma: Rise", "date": "2026-12", "precision": "month", "ids": {"igdb": "11"}, "art": {}, "sources": ["igdb"]},
    ]
    wd = [
        {"title": "Beta", "date": "2027", "precision": "year", "ids": {"wikidata": "Q2"}, "art": {}, "sources": ["wikidata"]},
        {"title": "GAMMA - Rise", "date": "2026-12-05", "precision": "day", "ids": {"wikidata": "Q3"}, "art": {}, "sources": ["wikidata"]},
        {"title": "Delta", "date": "2026-12-15", "precision": "day", "ids": {"wikidata": "Q4"}, "art": {}, "sources": ["wikidata"]},
    ]
    out = releases.merge(steam, igdb_recs, wd, today=TODAY)
    by = {r["title"]: r for r in out}
    assert "Old" not in by
    assert (by["Alpha"]["date"], by["Alpha"]["precision"]) == ("2027-Q1", "quarter")  # steam TBA -> igdb date
    assert by["Alpha"]["art"]["cover"] == "s" and by["Alpha"]["ids"] == {"steam": "1", "igdb": "10"}
    assert by["Beta"]["date"] == "2026-12-01" and by["Beta"]["ids"]["wikidata"] == "Q2"  # title join
    assert by["Gamma: Rise"]["date"] == "2026-12"  # igdb outranks wikidata
    assert by["Gamma: Rise"]["sources"] == ["igdb", "wikidata"]
    # day 2026-12-01, day 2026-12-15, month 2026-12 (ends 12-31), quarter 2027-Q1, tba last
    assert [r["title"] for r in out] == ["Beta", "Delta", "Gamma: Rise", "Alpha"]


def test_ecb_parse():
    fx = ecb.parse((FIX / "ecb_daily.xml").read_text())
    assert fx["base"] == "EUR" and fx["date"] == "2026-11-06"
    assert fx["rates"]["USD"] == 1.1165 and fx["rates"]["CAD"] == 1.5705
    assert fx["source"] == "ECB statistics"
    assert ecb.parse("<html>nope</html>") is None


class FakeClient:
    routes: dict = {}

    def __init__(self, budget, **kw):
        self.budget = budget

    def get(self, url, **kw):
        for prefix, answer in self.routes.items():
            if url.startswith(prefix):
                if isinstance(answer, Exception):
                    raise answer
                return answer
        raise net.GiveUp(f"HTTP 503 from {url}")


def test_build_with_sources_up(monkeypatch):
    monkeypatch.delenv("TWITCH_CLIENT_ID", raising=False)
    wd = {"results": {"bindings": [wd_row("Q9", "Wiki Game", "2027-05-01T00:00:00Z", 10)]}}
    monkeypatch.setattr(releases, "parse_earlier", lambda data: set())  # both queries share a URL prefix here
    FakeClient.routes = {
        releases.STEAM_QUERY: json.dumps(steam_fixture()).encode(),
        releases.WIKIDATA_ENDPOINT: json.dumps(wd).encode(),
        ecb.URL: (FIX / "ecb_daily.xml").read_bytes(),
    }
    doc = upcoming.build(net.Budget(60), FakeClient, previous_url="https://prev/x", today=TODAY)
    titles = [r["title"] for r in doc["releases"]]
    assert "Football Manager 27" in titles and "Wiki Game" in titles
    assert doc["fx"]["rates"]["CAD"] == 1.5705
    assert doc["sources"]["steam"]["status"] == "ok"
    assert doc["sources"]["igdb"]["status"] == "skipped"
    assert doc["schema"] == 1 and doc["count"] == len(titles)


def test_build_falls_back_to_previous_per_source(monkeypatch, tmp_path):
    monkeypatch.delenv("TWITCH_CLIENT_ID", raising=False)
    prev = {"schema": 1, "built": "2026-11-07T06:00:00Z",
            "fx": {"base": "EUR", "date": "2026-11-05", "rates": {"USD": 1.1}, "source": "ECB statistics"},
            "releases": [
                {"title": "Kept", "date": "2027-01-10", "precision": "day", "ids": {"steam": "5"}, "sources": ["steam"]},
                {"title": "Gone", "date": "2026-01-10", "precision": "day", "ids": {"steam": "6"}, "sources": ["steam"]},
                {"title": "Wiki", "date": "2027", "precision": "year", "ids": {"wikidata": "Q1"}, "sources": ["wikidata"]},
            ]}
    FakeClient.routes = {"https://prev/": gzip.compress(json.dumps(prev).encode())}
    doc = upcoming.build(net.Budget(60), FakeClient, previous_url="https://prev/x", today=TODAY)
    assert [r["title"] for r in doc["releases"]] == ["Kept", "Wiki"]  # past entry dropped
    assert doc["fx"]["rates"] == {"USD": 1.1}
    assert doc["sources"]["steam"]["status"] == "fallback"
    assert doc["sources"]["ecb"]["status"] == "fallback"
    path = tmp_path / "u.json.gz"
    upcoming.write(upcoming.compact(doc), str(path))
    back = json.loads(gzip.decompress(path.read_bytes()))
    assert back["count"] == 2


def test_build_with_nothing_returns_none(monkeypatch):
    monkeypatch.delenv("TWITCH_CLIENT_ID", raising=False)
    FakeClient.routes = {}
    assert upcoming.build(net.Budget(60), FakeClient, previous_url="https://prev/x", today=TODAY) is None


def test_igdb_fetch_pages(monkeypatch):
    monkeypatch.setenv("TWITCH_CLIENT_ID", "id")
    monkeypatch.setenv("TWITCH_CLIENT_SECRET", "s")
    monkeypatch.setattr(igdb, "token", lambda c, a, b: "tok")
    calls = []

    def fake_post(client, endpoint, body, cid, tok):
        calls.append(body)
        return [{"date": 1798675200, "game": {"id": 1, "name": "G"}}]

    monkeypatch.setattr(igdb, "post", fake_post)
    out = releases.fetch_igdb(object(), TODAY)
    assert len(out) == 1 and len(calls) == 1 and "release_dates" not in calls[0]
