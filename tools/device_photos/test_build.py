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
        assert e["file"] and e["author"], dev
        assert build.license_allowed(e["license"]), dev
        assert e["page_url"].startswith(build.PAGE), dev
        if "family_of" in e:
            assert src[e["family_of"]]["file"] == e["file"], dev


def test_asset_name_is_safe():
    assert build.asset_name("msi-claw-8-ex") == "msi-claw-8-ex.webp"
    assert build.asset_name("../x y") == "x-y.webp"
