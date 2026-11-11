import gzip
import hashlib
import json
from pathlib import Path

from gamedb import net
from gamedb.firmware import build, models
from gamedb.firmware.sources import asus, common, lenovo, msi, software, valve

FIX = Path(__file__).parent / "fixtures" / "firmware"
ROWS = json.loads((Path(__file__).resolve().parents[2] / "app" / "data" / "devices.json").read_text())["devices"]


def j(name):
    return json.loads((FIX / name).read_text())


def test_asus_ez_flash_bios_and_newest_firmware_per_part():
    items = asus.parse(j("asus_RC71L.json"), "RC71L")
    bios = next(i for i in items if i["kind"] == "bios")
    assert bios["version"] == "343" and bios["date"] == "2026-10-14"
    assert bios["flash"] == "ez-flash" and bios["download_url"].endswith(".zip?model=RC71L")
    assert len(bios["sha256"]) == 64 and bios["sha256"] == bios["sha256"].lower()
    assert "<br" not in bios["notes"]
    mcu = next(i for i in items if i["kind"] == "controller")
    assert mcu["version"] == "V321" and mcu["scheme"] == "asus-mcu" and mcu["flash"] == "windows"
    assert not any(i["name"] == "Armoury Crate" for i in items), "utilities are not firmware"


def test_asus_touch_panel_firmware_is_its_own_item():
    items = asus.parse(j("asus_RC73YA.json"), "RC73YA")
    kinds = {i["kind"] for i in items}
    assert {"bios", "touch"} <= kinds


def test_asus_bad_answer_is_empty():
    assert asus.parse({"Result": None}, "X") == [] and asus.parse("junk", "X") == []


def test_lenovo_product_and_bios():
    assert lenovo.product_id(j("lenovo_products_83E1.json")).endswith("/83E1")
    items = lenovo.parse(j("lenovo_drivers_83E1.json"), "LAPTOPS-AND-NETBOOKS/LEGION-SERIES/LEGION-GO-8APU1/83E1")
    assert [i["version"] for i in items] == ["N3CN40WW"]
    assert items[0]["notes_url"].endswith(".txt") and items[0]["flash"] == "windows"
    assert items[0]["download_page"].startswith("https://pcsupport.lenovo.com/us/en/products/laptops-and-netbooks/")
    assert items[0]["date"].startswith("2026-")


def test_msi_newest_revision_per_board_skips_me():
    items = msi.parse(j("msi_claw8ex.json"), "Claw-8-EX-AI-Plus-CG3EMX")
    assert [(i["board"], i["version"]) for i in items] == [("E1T91IMS", "E1T91IMS.10E")]
    assert msi.rev("114") > msi.rev("10E") > msi.rev("10D")
    assert "Improved fan" in items[0]["notes"]


def test_valve_bios_map_and_controller():
    b = (FIX / "jupiter-biosupdate").read_text()
    c = (FIX / "jupiter-controller-update").read_text()
    assert valve.newest_bios(b, "Jupiter") == "F7A0133"
    assert valve.newest_bios(b, "Galileo") == "F7G0114"
    fw = valve.controller_fw(c)
    assert fw["RA4"]["ts"] == "6AA8483A" and fw["D21"]["date"].startswith("20")
    assert valve.latest_tag([{"name": "jupiter-20261028.1"}, {"name": "jupiter-20260901.2"}, {"name": "x"}]) == "jupiter-20261028.1"


def test_software_parsers():
    k = software.kernel({"latest_stable": {"version": "6.17.7"}, "releases": [
        {"version": "6.17.7", "released": {"isodate": "2026-11-02"}, "changelog": "https://cdn.kernel.org/x"}]})
    assert k == {"version": "6.17.7", "date": "2026-11-02", "notes_url": "https://cdn.kernel.org/x"}
    g = software.github({"tag_name": "v0.60.1", "published_at": "2026-10-01T00:00:00Z", "html_url": "u"}, "a/b")
    assert g["version"] == "0.60.1"
    t = software.gitlab_tags([{"name": "mesa-25.2.6", "commit": {"committed_date": "2026-10-29T00:00:00Z"}},
                              {"name": "mesa-25.3.0-rc2"}, {"name": "mesa-25.2.10"}], r"^mesa-(\d+\.\d+\.\d+)$", "n")
    assert t["version"] == "25.2.10"
    c = software.cgit_tags("<a href='/x/tag/?h=20261019'>20261019</a><a href='/x/tag/?h=20260916'>", models.SOFTWARE["linux-firmware"]["pattern"], "n")
    assert c["version"] == "20261019" and c["date"] == "2026-10-19"


def test_common_text_and_date():
    assert common.text("a<br/>b &amp; c") == "a\nb & c"
    assert common.date(1767691620000) == "2026-01-06" and common.date("2026/1/2") == "2026-01-02"


class Fake:
    def __init__(self, routes):
        self.routes = routes
        self.calls = []

    def get(self, url, **kw):
        self.calls.append(url)
        for prefix, ans in self.routes.items():
            if url.startswith(prefix):
                if isinstance(ans, Exception):
                    raise ans
                return ans
        raise net.GiveUp("HTTP 403 from " + url.split("?")[0])


def routes():
    return {
        "https://www.asus.com/support/api/product.asmx/GetPDBIOS?website=global&model=RC71L": (FIX / "asus_RC71L.json").read_bytes(),
        "https://pcsupport.lenovo.com/us/en/api/v4/mse/getproducts?productId=83E1": (FIX / "lenovo_products_83E1.json").read_bytes(),
        "https://pcsupport.lenovo.com/us/en/api/v4/downloads/drivers": (FIX / "lenovo_drivers_83E1.json").read_bytes(),
        "https://www.msi.com/api/v1/product/support/panel?product=Claw-8-EX": (FIX / "msi_claw8ex.json").read_bytes(),
        valve.TAGS: b'[{"name": "jupiter-20261028.1"}]',
        "https://raw.githubusercontent.com/Jovian-Experiments/jupiter-hw-support/jupiter-20261028.1/usr/bin/jupiter-biosupdate": (FIX / "jupiter-biosupdate").read_bytes(),
        "https://raw.githubusercontent.com/Jovian-Experiments/jupiter-hw-support/jupiter-20261028.1/usr/bin/jupiter-controller-update": (FIX / "jupiter-controller-update").read_bytes(),
        "https://api.github.com/repos/ShadowBlip/InputPlumber/releases/latest": b'{"tag_name": "v0.62.0", "published_at": "2026-10-20T00:00:00Z"}',
    }


def test_build_covers_every_model_row_and_shares_deck_controller():
    doc = build.build(ROWS, Fake(routes()), built="2026-11-09T06:00:00Z")
    d = doc["devices"]
    assert d["asus-rog-ally"]["items"][0]["version"] == "343"
    assert d["lenovo-legion-go"]["items"][0]["version"] == "N3CN40WW"
    assert d["msi-claw-8-ex"]["items"][0]["version"] == "E1T91IMS.10E"
    assert d["steam-deck-lcd"]["items"][0]["version"] == "F7A0133"
    assert d["steam-deck-oled"]["items"][0]["version"] == "F7G0114"
    assert d["gpd-win-4"]["source"] == "link" and d["gpd-win-4"]["support_url"].startswith("https://gpd.hk/")
    assert d["ayaneo-2"]["items"][0]["flash"] == "link"
    assert doc["shared"] == [{"traits": {"family": "steam-deck"}, "items": [i for i in doc["shared"][0]["items"]]}]
    assert doc["shared"][0]["items"][0]["kind"] == "controller"
    assert doc["software"]["inputplumber"]["version"] == "0.62.0"
    # unreachable listing without previous data: kept with an error, not dropped
    assert d["asus-rog-ally-x"]["items"] == [] and "403" in d["asus-rog-ally-x"]["error"]
    # every non-family handheld row of devices.json has an entry (a box for the TV, "form": "console",
    # has no maker BIOS listing to read: SteamOS updates the Steam Machine itself)
    want = {r["id"] for r in ROWS if not r["id"].endswith("-family") and r.get("form", "handheld") == "handheld"}
    assert "valve-steam-machine" not in d
    assert want <= set(d), want - set(d)


def test_build_fetches_each_listing_once_and_falls_back_to_previous():
    prev = {"schema": 1, "devices": {"asus-rog-ally-x": {"maker": "ASUS", "source": "asus", "items": [
        {"kind": "bios", "name": "BIOS", "version": "312"}], "checked": "2026-11-01T06:00:00Z", "stale": False}},
        "software": {"hhd": {"version": "3.1"}}}
    f = Fake(routes())
    doc = build.build(ROWS, f, prev, built="2026-11-09T06:00:00Z")
    x = doc["devices"]["asus-rog-ally-x"]
    assert x["stale"] is True and x["items"][0]["version"] == "312" and x["checked"] == "2026-11-01T06:00:00Z"
    assert doc["software"]["hhd"] == {"version": "3.1", "stale": True}
    assert sum(1 for c in f.calls if "jupiter-biosupdate" in c) == 1


def test_write_gz_and_sha256(tmp_path):
    out = tmp_path / "firmware.json.gz"
    digest = build.write({"schema": 1, "devices": {}}, out)
    assert hashlib.sha256(out.read_bytes()).hexdigest() == digest
    assert (tmp_path / "firmware.json.gz.sha256").read_text() == f"{digest}  firmware.json.gz\n"
    assert json.loads(gzip.decompress(out.read_bytes()))["schema"] == 1


def test_models_reference_real_rows():
    ids = {r["id"] for r in ROWS}
    for table in (models.ASUS, models.LENOVO, models.MSI, models.VALVE, models.GPD_PAGES):
        assert set(table) <= ids, set(table) - ids


def test_previous_index_comes_from_the_data_repo():
    assert build.RELEASE == "https://github.com/IHulkSmashI/GameCove-data/releases/download/firmware/firmware.json.gz"
    prev = gzip.compress(json.dumps({"schema": 1, "devices": {"x": {}}}).encode())
    f = Fake({build.RELEASE: prev})
    assert build.fetch_previous(f) == {"schema": 1, "devices": {"x": {}}} and f.calls == [build.RELEASE]
    assert build.fetch_previous(Fake({})) == {}   # nothing there yet: start empty
