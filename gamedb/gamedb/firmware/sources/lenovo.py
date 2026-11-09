"""Lenovo: PC Support's download list for a machine type (the JSON its own driver page loads).

  1. https://pcsupport.lenovo.com/us/en/api/v4/mse/getproducts?productId=<MTM>  -> [{Id: "LAPTOPS-.../83E1"}]
  2. https://pcsupport.lenovo.com/us/en/api/v4/downloads/drivers?productId=<Id>  (needs a Referer from
     pcsupport.lenovo.com, else "deny access")
     -> body.DownloadItems[]: {Title, Category.Name "BIOS/UEFI", Files: [{Version "N3CN40WW", Date.Unix (ms),
        TypeString "EXE" | "TXT README", URL}]}

Lenovo's consumer BIOS packages are Windows .exe flashers; the README .txt is the change log. DMI
bios_version on a Legion Go reads the same "N3CN40WW".
"""
from __future__ import annotations

import urllib.parse

from .common import date, item, load_json

PRODUCTS = "https://pcsupport.lenovo.com/us/en/api/v4/mse/getproducts?productId={mtm}"
DRIVERS = "https://pcsupport.lenovo.com/us/en/api/v4/downloads/drivers?productId={pid}"
PAGE = "https://pcsupport.lenovo.com/us/en/products/{path}/downloads/driver-list"


def product_id(doc: object) -> str:
    if isinstance(doc, list) and doc and isinstance(doc[0], dict):
        return str(doc[0].get("Id") or "")
    return ""


def parse(doc: object, pid: str) -> list[dict]:
    items = (((doc or {}).get("body") or {}).get("DownloadItems") or []) if isinstance(doc, dict) else []
    page = PAGE.format(path=pid.lower())
    out = []
    for it in items:
        cat = str(((it.get("Category") or {}).get("Name")) or "")
        if cat != "BIOS/UEFI":
            continue
        files = it.get("Files") or []
        exe = next((f for f in files if str(f.get("TypeString", "")).upper() == "EXE"), None)
        readme = next((f for f in files if "README" in str(f.get("TypeString", "")).upper()), None)
        if not exe or not exe.get("Version"):
            continue
        out.append(item("bios", "BIOS", str(exe["Version"]).strip(), date=date((exe.get("Date") or {}).get("Unix")),
                        notes_url=(readme or {}).get("URL", ""), download_page=page, download_url=exe.get("URL", ""),
                        flash="windows", scheme="lenovo", severity="recommended"))
    return out


def fetch(client, mtm: str) -> list[dict]:
    pid = product_id(load_json(client.get(PRODUCTS.format(mtm=mtm), headers={"Accept": "application/json"})))
    if not pid:
        return []
    referer = "https://pcsupport.lenovo.com/us/en/products/" + pid.lower() + "/downloads/driver-list"
    doc = load_json(client.get(DRIVERS.format(pid=urllib.parse.quote(pid, safe="")),
                               headers={"Accept": "application/json", "Referer": referer}))
    return parse(doc, pid)
