"""A cut-off answer from the endpoint is retried at half the page size."""
import json

from gamedb.sources import wikidata


class FakeClient:
    def __init__(self, total, qlever_down=True):
        self.total = total
        self.calls = []
        self.qlever_down = qlever_down
        self.endpoints = []

    def get(self, url, headers=None):
        import urllib.parse
        self.endpoints.append(url.split("?")[0])
        if self.qlever_down and "qlever" in url:
            raise OSError("qlever unreachable")
        q = urllib.parse.parse_qs(urllib.parse.urlparse(url).query)["query"][0]
        limit = int(q.split("LIMIT ")[1].split()[0])
        offset = int(q.split("OFFSET ")[1].split()[0])
        self.calls.append((limit, offset))
        if limit > 2000:
            return '{"results": {"bindings": [{"item"'  # cut off mid-stream
        rows = [{"item": {"value": f"http://www.wikidata.org/entity/Q{i}"}, "value": {"value": str(i + 1)},
                 "label": {"value": f"Game {i}"}} for i in range(offset, min(offset + limit, self.total))]
        return json.dumps({"results": {"bindings": rows}})


def test_cut_off_page_is_retried_smaller(monkeypatch):
    monkeypatch.setattr(wikidata, "STORE_PROPERTIES", {"P1733": "steam"})
    monkeypatch.setattr(wikidata, "EXTRA_PROPERTIES", {})
    c = FakeClient(total=4500)
    items = wikidata.fetch(c)
    assert len(items) == 4500
    assert c.calls[0] == (5000, 0) and c.calls[1] == (2500, 0) and c.calls[2] == (1250, 0)
    assert all(limit == 1250 for limit, _ in c.calls[2:])


def test_gives_up_below_min_page(monkeypatch):
    monkeypatch.setattr(wikidata, "STORE_PROPERTIES", {"P1733": "steam"})
    monkeypatch.setattr(wikidata, "EXTRA_PROPERTIES", {})
    monkeypatch.setattr(wikidata, "MIN_PAGE", 4000)
    import pytest
    with pytest.raises(json.JSONDecodeError):
        wikidata.fetch(FakeClient(total=10))


def test_qlever_first_whole_property(monkeypatch):
    monkeypatch.setattr(wikidata, "STORE_PROPERTIES", {"P1733": "steam"})
    monkeypatch.setattr(wikidata, "EXTRA_PROPERTIES", {})

    class Big(FakeClient):
        def get(self, url, headers=None):
            import urllib.parse
            self.endpoints.append(url.split("?")[0])
            q = urllib.parse.parse_qs(urllib.parse.urlparse(url).query)["query"][0]
            assert "PREFIX wdt:" in q  # QLever needs explicit prefixes
            rows = [{"item": {"value": f"http://www.wikidata.org/entity/Q{i}"}, "value": {"value": str(i)}}
                    for i in range(self.total)]
            return json.dumps({"results": {"bindings": rows}})

    c = Big(total=30000, qlever_down=False)
    assert len(wikidata.fetch(c)) == 30000
    assert c.endpoints == ["https://qlever.dev/api/wikidata"]  # one request, no WDQS


def test_falls_back_to_wdqs(monkeypatch):
    monkeypatch.setattr(wikidata, "STORE_PROPERTIES", {"P1733": "steam"})
    monkeypatch.setattr(wikidata, "EXTRA_PROPERTIES", {})
    c = FakeClient(total=1200)
    assert len(wikidata.fetch(c)) == 1200
    assert c.endpoints[0].startswith("https://qlever.dev") and "query.wikidata.org" in c.endpoints[-1]
