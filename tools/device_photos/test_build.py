"""python -m pytest -q tools/device_photos (no network)."""
import json
from pathlib import Path

import build

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
        assert dev not in src, f"{dev} already has a photo; drop it from _manual"
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
