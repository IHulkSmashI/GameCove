"""python -m pytest -q tools/device_photos (no network)."""
import json
from pathlib import Path

import build
import makers

ROOT = Path(__file__).resolve().parents[2]


def test_license_allowlist():
    for ok in ["CC0", "CC BY 4.0", "CC BY-SA 4.0", "CC BY-SA 3.0 de", "CC BY 2.0", "Public domain", "PD"]:
        assert build.license_allowed(ok), ok
    for bad in ["CC BY-NC 4.0", "CC BY-ND 4.0", "CC BY-NC-SA 4.0", "GFDL", "Fair use", "", "All rights reserved"]:
        assert not build.license_allowed(bad), bad


def test_source_file_is_valid():
    src = json.loads((ROOT / "app/data/device_photos.json").read_text(encoding="utf-8"))
    ids = {d["id"] for d in json.loads((ROOT / "app/data/devices.json").read_text())["devices"]}
    for dev, e in src.items():
        if dev.startswith("_"):
            continue
        assert dev in ids, dev
        if not build.has_free_source(e):
            assert set(e) == {"maker_image"}, f"{dev}: a row without a free photo only carries maker_image"
            continue
        assert "maker_image" not in e, f"{dev}: has a free photo; the free photo wins, drop maker_image"
        assert e["author"], dev
        assert build.license_allowed(e["license"]), dev
        kind, key = build.source_key(e)
        assert kind in ("commons", "openverse") and key, dev
        if kind == "commons":
            assert e["page_url"] == build.commons_page(e["file"]), dev
        else:
            assert e["page_url"].startswith(build.FLICKR_PAGE), dev
        if "family_of" in e:
            assert build.source_key(src[e["family_of"]]) == (kind, key), dev
    for dev, cands in src.get("_manual", {}).items():
        if dev.startswith("_"):
            continue
        assert dev in ids, dev
        assert dev not in src or not build.has_free_source(src[dev]), f"{dev} already has a photo; drop it from _manual"
        for c in cands:
            assert c["source"] == "youtube" and c["url"].startswith("https://www.youtube.com/watch?v="), dev
            assert c["channel"], dev


def test_openverse_license_names():
    assert build.openverse_license_name("by", "2.0") == "CC BY 2.0"
    assert build.openverse_license_name("by-sa", "4.0") == "CC BY-SA 4.0"
    assert build.openverse_license_name("cc0", "1.0") == "CC0"
    assert build.openverse_license_name("pdm", "1.0") == "Public domain"
    for code in ("by", "by-sa", "cc0", "pdm"):
        assert build.license_allowed(build.openverse_license_name(code, "2.0")), code
    for code in ("by-nc", "by-nd", "by-nc-sa", "by-nc-nd"):
        assert not build.license_allowed(build.openverse_license_name(code, "2.0")), code


def test_openverse_info_uses_flickr_page_only(monkeypatch):
    doc = {"license": "by", "license_version": "2.0", "license_url": "https://creativecommons.org/licenses/by/2.0/",
           "creator": "someone", "url": "https://live.staticflickr.com/1/2_b.jpg",
           "foreign_landing_url": "https://www.flickr.com/photos/x/2"}
    monkeypatch.setattr(build, "get", lambda url, tries=4: json.dumps(doc).encode())
    uid = "0a1b2c3d-0000-4000-8000-000000000000"
    info = build.openverse_info(uid)
    assert info["license"] == "CC BY 2.0" and info["page_url"] == doc["foreign_landing_url"]
    doc["foreign_landing_url"] = "https://example.com/x"
    assert build.openverse_info(uid)["page_url"] == ""
    assert build.openverse_info("../etc") == {}


def test_unverifiable_sources_are_skipped(tmp_path, monkeypatch):
    src = {"steam-deck-lcd": {"source": "youtube", "url": "https://www.youtube.com/watch?v=x", "author": "a",
                              "license": "CC BY 3.0", "page_url": "https://www.youtube.com/watch?v=x"}}
    p = tmp_path / "src.json"
    p.write_text(json.dumps(src))
    monkeypatch.setattr(build, "get", lambda *a, **k: (_ for _ in ()).throw(AssertionError("no network")))
    assert build.main(["--src", str(p), "--out", str(tmp_path / "out")]) == 1
    man = json.loads((tmp_path / "out" / "manifest.json").read_text())
    assert man["devices"] == {}


def test_asset_name_is_safe():
    assert build.asset_name("msi-claw-8-ex") == "msi-claw-8-ex.webp"
    assert build.asset_name("../x y") == "x-y.webp"


def _src():
    return json.loads((ROOT / "app/data/device_photos.json").read_text(encoding="utf-8"))


def test_maker_images_are_well_formed():
    rules, entries = makers.load()
    assert entries, "maker images listed"
    for dev, m in entries.items():
        assert makers.entry_problems(dev, m, rules) == [], dev
    assert makers.main(["--src", str(makers.SRC)]) == 0


def test_every_known_model_has_a_picture_source():
    """Free photo or maker link for every exact model; the 'unknown model' rows keep the drawing."""
    src = _src()
    devices = json.loads((ROOT / "app/data/devices.json").read_text())["devices"]
    # Rows whose maker site could not be read when the links were collected (see docs/DEVICES.md).
    no_link_yet = {"gpd-win-4", "gpd-win-mini", "gpd-win-max-2", "gpd-win-5", "zotac-zone", "orangepi-neo"}
    for d in devices:
        dev = d["id"]
        if dev.endswith("-family"):
            assert dev not in src, f"{dev}: unknown-model rows keep the drawing"
            continue
        if dev in no_link_yet:
            continue
        assert dev in src, f"{dev}: no free photo and no maker image"


def test_maker_entry_rules():
    rules = {"MSI": {"image_prefixes": ["https://asset-us-store.msi.com/"], "page_domains": ["msi.com"]}}
    good = {"url": "https://asset-us-store.msi.com/a.png", "page_url": "https://us-store.msi.com/x",
            "maker": "MSI", "checked": "2026-11-09"}
    assert makers.entry_problems("d", good, rules) == []
    for k, v in [("url", "https://retailer.example/a.png"), ("url", "http://asset-us-store.msi.com/a.png"),
                 ("page_url", "https://evilmsi.com/x"), ("page_url", "https://reviews.example/msi"),
                 ("maker", "Nobody"), ("checked", "yesterday")]:
        assert makers.entry_problems("d", dict(good, **{k: v}), rules), (k, v)


def test_sniff():
    assert makers.sniff(b"\x89PNG\r\n\x1a\n....") == "png"
    assert makers.sniff(b"\xff\xd8\xff\xe0") == "jpg"
    assert makers.sniff(b"RIFF\x00\x00\x00\x00WEBPVP8 ") == "webp"
    assert makers.sniff(b"<!doctype html>") == ""


def test_link_check_reports_broken_without_storing(tmp_path, monkeypatch):
    src = {"_makers": {"MSI": {"image_prefixes": ["https://asset-us-store.msi.com/"], "page_domains": ["msi.com"]}},
           "a": {"maker_image": {"url": "https://asset-us-store.msi.com/a.png", "page_url": "https://www.msi.com/a",
                                 "maker": "MSI", "checked": "2026-11-09"}},
           "b": {"maker_image": {"url": "https://asset-us-store.msi.com/b.png", "page_url": "https://www.msi.com/b",
                                 "maker": "MSI", "checked": "2026-11-09"}}}
    p = tmp_path / "src.json"
    p.write_text(json.dumps(src))
    monkeypatch.setattr(makers, "check_url", lambda url, timeout=20.0: "" if url.endswith("a.png") else "http 404")
    rep = tmp_path / "broken.md"
    assert makers.main(["--src", str(p), "--check", "--report", str(rep)]) == 2
    text = rep.read_text()
    assert "`b`" in text and "`a`" not in text
    assert sorted(x.name for x in tmp_path.iterdir()) == ["broken.md", "src.json"], "no image stored"


def test_build_never_fetches_maker_images(tmp_path, monkeypatch):
    src = {"msi-claw-8-ex": {"maker_image": {"url": "https://asset-us-store.msi.com/a.png",
                                             "page_url": "https://www.msi.com/a", "maker": "MSI", "checked": "2026-11-09"}}}
    p = tmp_path / "src.json"
    p.write_text(json.dumps(src))
    monkeypatch.setattr(build, "get", lambda *a, **k: (_ for _ in ()).throw(AssertionError("no network")))
    build.main(["--src", str(p), "--out", str(tmp_path / "out")])
    out = sorted(x.name for x in (tmp_path / "out").iterdir())
    assert out == ["manifest.json"], out
    assert json.loads((tmp_path / "out" / "manifest.json").read_text())["devices"] == {}
