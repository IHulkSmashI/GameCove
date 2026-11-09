"""Builds firmware.json.gz: python -m gamedb.firmware.build --out dist/firmware.json.gz

Schema 1:
  {"schema": 1, "built": ISO time,
   "devices": {"<devices.json id>": {"maker", "source": "asus|lenovo|msi|valve|link", "support_url",
               "items": [{kind, name, version, date, notes, notes_url, download_page, download_url, sha256,
                          flash, scheme, severity, board, match_name}], "checked": ISO, "stale": bool}},
   "shared": [{"traits": {"family": "steam-deck"}, "items": [...]}],
   "software": {"kernel": {"version", "date", "notes_url"}, "mesa": ..., ...}}

Every source falls back to the entry in the previously published file when it fails, marked
"stale": true with its old "checked" time, so one maker's outage never empties the index.
Writes <out>.sha256 ("<hex>  firmware.json.gz") next to it.
"""
from __future__ import annotations

import argparse
import datetime as dt
import gzip
import hashlib
import json
import logging
import sys
from pathlib import Path

from .. import net
from . import models
from .sources import asus, lenovo, msi, software, valve

log = logging.getLogger("firmware")
RELEASE = "https://github.com/IHulkSmashI/GameCove/releases/download/firmware/firmware.json.gz"
DEVICES = Path(__file__).resolve().parents[3] / "app" / "data" / "devices.json"


def now_iso() -> str:
    return dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def plan(rows: list[dict]) -> dict:
    """device id -> (source, key, maker, support_url). Siblings with the same key share one fetch."""
    out = {}
    for r in rows:
        rid, maker = str(r.get("id", "")), str(r.get("maker", ""))
        if rid.endswith("-family") or not rid:
            continue
        if rid in models.ASUS:
            out[rid] = ("asus", models.ASUS[rid], maker, asus.PAGE.format(model=models.ASUS[rid]))
        elif rid in models.LENOVO:
            out[rid] = ("lenovo", models.LENOVO[rid], maker, "https://pcsupport.lenovo.com/us/en/products/")
        elif rid in models.MSI:
            out[rid] = ("msi", models.MSI[rid], maker, msi.PAGE.format(page=models.MSI[rid]))
        elif rid in models.VALVE:
            out[rid] = ("valve", models.VALVE[rid], maker, valve.NOTES)
        else:
            link = models.GPD_PAGES.get(rid) or (models.MAKER_LINKS.get(maker) or {}).get("url", "")
            if link:
                out[rid] = ("link", link, maker, link)
    return out


def fetch_previous(client) -> dict:
    try:
        doc = json.loads(gzip.decompress(client.get(RELEASE)))
        return doc if isinstance(doc, dict) and doc.get("schema") == 1 else {}
    except Exception as e:  # noqa: BLE001 - first run, offline: start empty
        log.info("no previous index: %s", e)
        return {}


def build(rows: list[dict], client, previous: dict | None = None, built: str | None = None) -> dict:
    built = built or now_iso()
    previous = previous or {}
    prev_dev = previous.get("devices") or {}
    doc = {"schema": 1, "built": built, "devices": {}, "shared": [], "software": {}}
    cache: dict[tuple, object] = {}
    valve_scripts = None
    for rid, (source, key, maker, support) in sorted(plan(rows).items()):
        entry = {"maker": maker, "source": source, "support_url": support, "items": [], "checked": built, "stale": False}
        try:
            if source == "link":
                entry["items"] = [{"kind": "bios", "name": "BIOS", "version": "", "download_page": key,
                                   "notes_url": key, "flash": "link"}]
            else:
                ck = (source, key)
                if ck not in cache:
                    if source == "asus":
                        cache[ck] = asus.fetch(client, key)
                    elif source == "lenovo":
                        cache[ck] = lenovo.fetch(client, key)
                    elif source == "msi":
                        cache[ck] = msi.fetch(client, key)
                    elif source == "valve":
                        if valve_scripts is None:
                            valve_scripts = valve.fetch_scripts(client)
                        b, c, tag = valve_scripts
                        cache[ck] = [i for i in valve.items(b, c, key, tag) if i["kind"] == "bios"]
                if isinstance(cache[ck], Exception):
                    raise cache[ck]
                entry["items"] = cache[ck]
                if not entry["items"]:
                    raise net.GiveUp("listing had no firmware entries")
        except Exception as e:  # noqa: BLE001 - one maker failing keeps last night's data
            cache[(source, key)] = e if isinstance(e, Exception) else net.GiveUp(str(e))
            old = prev_dev.get(rid)
            log.warning("%s (%s %s): %s", rid, source, key, e)
            if old and old.get("items"):
                entry = dict(old, stale=True)
            else:
                entry["error"] = str(e)[:200]
        doc["devices"][rid] = entry
    # Steam Deck controller firmware is the same for both models: one shared entry by family.
    if valve_scripts and valve_scripts[1]:
        ctl = [i for i in valve.items(valve_scripts[0], valve_scripts[1], "Jupiter", valve_scripts[2]) if i["kind"] == "controller"]
        if ctl:
            doc["shared"].append({"traits": {"family": "steam-deck"}, "items": ctl})
    elif previous.get("shared"):
        doc["shared"] = previous["shared"]
    prev_sw = previous.get("software") or {}
    for name, spec in models.SOFTWARE.items():
        try:
            got = software.fetch(client, name, spec)
            if not got:
                raise net.GiveUp("no version found")
            doc["software"][name] = got
        except Exception as e:  # noqa: BLE001
            log.warning("software %s: %s", name, e)
            if name in prev_sw:
                doc["software"][name] = dict(prev_sw[name], stale=True)
    return doc


def write(doc: dict, out: Path) -> str:
    out.parent.mkdir(parents=True, exist_ok=True)
    data = gzip.compress(json.dumps(doc, separators=(",", ":"), sort_keys=True).encode(), mtime=0)
    out.write_bytes(data)
    digest = hashlib.sha256(data).hexdigest()
    (out.parent / (out.name + ".sha256")).write_text(f"{digest}  {out.name}\n")
    return digest


def main(argv: list[str] | None = None) -> int:
    logging.basicConfig(level=logging.INFO, format="%(levelname)s %(name)s: %(message)s")
    p = argparse.ArgumentParser(prog="gamedb.firmware.build")
    p.add_argument("--out", type=Path, required=True)
    p.add_argument("--devices", type=Path, default=DEVICES)
    p.add_argument("--max-minutes", type=float, default=10)
    a = p.parse_args(argv)
    rows = json.loads(a.devices.read_text()).get("devices", [])
    client = net.Client(net.Budget(a.max_minutes * 60))
    doc = build(rows, client, fetch_previous(client))
    have = sum(1 for d in doc["devices"].values() if d.get("items") and d.get("source") != "link")
    if have == 0 and not doc["software"]:
        log.error("nothing fetched and no previous data: not publishing")
        return 1
    log.info("devices %d (%d from a maker listing), software %d, sha256 %s",
             len(doc["devices"]), have, len(doc["software"]), write(doc, a.out))
    return 0


if __name__ == "__main__":
    sys.exit(main())
