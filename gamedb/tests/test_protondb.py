import io
import json
import tarfile
from pathlib import Path

import pytest

from gamedb.sources import protondb as p

FIX = Path(__file__).parent / "fixtures"
REPORTS = json.loads((FIX / "protondb_reports.json").read_text())


def by_app(sid):
    return next(r for r in REPORTS if p.app_id(r) == sid)


@pytest.mark.parametrize("sid,bucket", [
    # v1 (pre-Oct 2019): rating word
    ("290970", "works"), ("525480", "tinkering"), ("578850", "borked"),
    # v2 (2019-2022 questionnaire): verdict + type
    ("219990", "works"), ("7760", "tinkering"), ("352620", "borked"),
    # v3 (2022+): verdict, triedOob/verdictOob, customizations, bugs
    ("460810", "works"), ("1594950", "works"),
    ("46500", "tinkering"), ("1761650", "tinkering"), ("306130", "tinkering"), ("1091500", "tinkering"),
    ("1240440", "borked"),
])
def test_classify_real_reports_from_each_format(sid, bucket):
    assert p.classify(by_app(sid)) == bucket


def test_classify_ignores_unreadable():
    assert p.classify({"responses": {}}) is None
    assert p.classify({"rating": "Sparkly"}) is None
    assert p.app_id({"app": {"steam": {"appId": "not-a-number"}}}) is None


@pytest.mark.parametrize("w,t,b,expected", [
    (2, 0, 0, None),             # below MIN_REPORTS
    (3, 0, 0, "platinum"),
    (9, 1, 0, "platinum"),       # 0.975
    (6, 4, 0, "platinum"),       # 0.90 exactly
    (5, 5, 0, "gold"),           # 0.875
    (0, 3, 0, "gold"),           # 0.75 exactly
    (3, 0, 1, "gold"),           # 0.75 exactly
    (2, 1, 1, "silver"),         # 0.6875
    (3, 0, 2, "silver"),         # 0.60 exactly
    (1, 1, 1, "bronze"),         # 0.583
    (2, 0, 2, "bronze"),         # 0.5, borked not a majority
    (1, 0, 2, "borked"),         # majority borked
    (0, 0, 3, "borked"),
])
def test_tier_boundaries(w, t, b, expected):
    assert p.tier({"works": w, "tinkering": t, "borked": b}) == expected


def test_summarise_uses_recent_window_anchored_to_newest_report():
    deck = by_app("460810")          # v3 works, Feb 2022
    borked_v3 = by_app("1240440")    # v3 borked, Feb 2022
    old = dict(by_app("352620"), app={"steam": {"appId": "460810"}})  # v2 borked, 2019, same game
    reports = [deck] * 3 + [old] * 5 + [borked_v3] * 3 + REPORTS
    tiers = p.summarise(reports)
    assert tiers["460810"] == "platinum"      # 2019 borked reports fall outside the window
    assert tiers["1240440"] == "borked"
    assert "290970" not in tiers               # single old report: too few
    assert p.summarise(reports, window_days=10_000)["460810"] == "borked"  # with them: 5 of 8 borked


def test_latest_dump_picks_newest_by_date():
    names = ["README.md", "reports_dec1_2025.tar.gz", "reports_nov1_2026.tar.gz",
             "reports_aug4_2026.tar.gz", "reports_jan2_2026.tar.gz"]
    assert p.latest_dump(names) == "reports_nov1_2026.tar.gz"
    assert p.latest_dump(["README.md"]) is None


def test_iter_reports_streams_tarball_across_chunk_boundaries():
    body = json.dumps(REPORTS, indent=2).encode()
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w:gz") as t:
        info = tarfile.TarInfo("reports_piiremoved.json")
        info.size = len(body)
        t.addfile(info, io.BytesIO(body))
    got = list(p.iter_reports(buf.getvalue()))
    assert got == REPORTS
    tiny = list(p.iter_array(io.StringIO(json.dumps(REPORTS)), chunk=37))
    assert tiny == REPORTS
    assert list(p.iter_array(io.StringIO("[]"))) == []


def test_recent_names_newest_first_and_not_in_future():
    import datetime as dt
    names = p.recent_names(dt.date(2026, 11, 3), months=2)
    assert names[:3] == ["reports_nov3_2026.tar.gz", "reports_nov2_2026.tar.gz", "reports_nov1_2026.tar.gz"]
    assert names[3] == "reports_oct6_2026.tar.gz" and names[-1] == "reports_oct1_2026.tar.gz"
    assert p.recent_names(dt.date(2027, 1, 1), months=2)[1] == "reports_dec6_2026.tar.gz"


def test_fetch_probes_names_when_listing_refused():
    import datetime as dt
    from gamedb import net

    body = json.dumps([by_app("460810")] * 3).encode()
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w:gz") as t:
        info = tarfile.TarInfo("reports_piiremoved.json")
        info.size = len(body)
        t.addfile(info, io.BytesIO(body))
    asked = []

    class C:
        def get(self, url, **kw):
            asked.append(url.rsplit("/", 1)[-1])
            if url == p.REPO_API:
                raise net.GiveUp("HTTP 403")
            if url.endswith("reports_nov1_2026.tar.gz"):
                return buf.getvalue()
            raise net.NotFound("HTTP 404")

    tiers, name = p.fetch(C(), today=dt.date(2026, 11, 2))
    assert name == "reports_nov1_2026.tar.gz" and tiers == {"460810": "platinum"}
    assert asked == ["reports", "reports_nov2_2026.tar.gz", "reports_nov1_2026.tar.gz"]
