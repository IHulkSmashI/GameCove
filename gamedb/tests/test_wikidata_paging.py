"""A cut-off answer from the endpoint is retried at half the page size."""
import json

from gamedb.sources import wikidata


class FakeClient:
    def __init__(self, total):
        self.total = total
        self.calls = []

    def get(self, url, headers=None):
        import urllib.parse
        q = urllib.parse.parse_qs(urllib.parse.urlparse(url).query)["query"][0]
        limit = int(q.split("LIMIT ")[1].split()[0])
        offset = int(q.split("OFFSET ")[1].split()[0])
        self.calls.append((limit, offset))
        if limit > 2000:
            return '{"results": {"bindings": [{"item"'  # cut off mid-stream
        rows = [{"item": {"value": f"http://www.wikidata.org/entity/Q{i}"}, "value": {"value": str(i)},
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
