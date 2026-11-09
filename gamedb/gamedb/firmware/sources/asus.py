"""ASUS / ROG: the support web API the ASUS support page itself loads.

  https://www.asus.com/support/api/product.asmx/GetPDBIOS?website=global&model=<board>&cpu=
  -> Result.Obj[]: {Name: "BIOS" | "BIOS Update(Windows)" | "Firmware" | ..., Files: [{Version, Title,
     ReleaseDate "2026/10/14", Description (HTML), FileSize, DownloadUrl.Global, sha256, Severity}]}

"BIOS" holds the file for ASUS EZ Flash (a zip with the .CAP; the UEFI's own flasher reads it from a
FAT32 USB drive), newest first. "Firmware" mixes several parts (ROG MCU = controller, touch panel):
the newest file per Title. The running BIOS reads "RC71L.343" in DMI bios_version.
"""
from __future__ import annotations

import re

from .common import date, item, load_json, text

API = "https://www.asus.com/support/api/product.asmx/GetPDBIOS?website=global&model={model}&cpu="
PAGE = "https://www.asus.com/supportonly/{model}/helpdesk_bios/"


def _ver_key(v: str) -> tuple:
    return tuple(int(x) for x in re.findall(r"\d+", v)) or (-1,)


def _kind(title: str) -> tuple[str, str, str]:
    t = title.lower()
    if "mcu" in t:
        return "controller", "Controller (MCU) firmware", "asus-mcu"
    if "touch" in t:
        return "touch", "Touch panel firmware", "natural"
    if "ec" in t.split() or "embedded controller" in t:
        return "ec", "EC firmware", "natural"
    return "firmware", title.strip() or "Firmware", "natural"


def _severity(f: dict) -> str:
    s = str(f.get("Severity") or "").lower()
    return "important" if ("critical" in s or "important" in s or s == "1") else "recommended"


def parse(doc: object, model: str) -> list[dict]:
    objs = (((doc or {}).get("Result") or {}).get("Obj") or []) if isinstance(doc, dict) else []
    out: list[dict] = []
    page = PAGE.format(model=model)
    for o in objs:
        name = str(o.get("Name") or "")
        files = [f for f in (o.get("Files") or []) if isinstance(f, dict) and f.get("Version")]
        if not files:
            continue
        if name == "BIOS":
            f = max(files, key=lambda f: _ver_key(str(f["Version"])))
            out.append(item("bios", "BIOS", str(f["Version"]), date=date(f.get("ReleaseDate")),
                            notes=text(f.get("Description")), notes_url=page, download_page=page,
                            download_url=((f.get("DownloadUrl") or {}).get("Global") or ""),
                            sha256=str(f.get("sha256") or "").lower(), size=str(f.get("FileSize") or ""),
                            flash="ez-flash", scheme="asus", severity=_severity(f)))
        elif name == "Firmware":
            newest: dict[str, dict] = {}
            for f in files:
                kind, label, scheme = _kind(str(f.get("Title") or ""))
                key = label
                if key not in newest or _ver_key(str(f["Version"])) > _ver_key(str(newest[key]["Version"])):
                    newest[key] = dict(f, _k=(kind, label, scheme))
            for f in newest.values():
                kind, label, scheme = f["_k"]
                out.append(item(kind, label, str(f["Version"]), date=date(f.get("ReleaseDate")),
                                notes=text(f.get("Description")), notes_url=page, download_page=page,
                                download_url=((f.get("DownloadUrl") or {}).get("Global") or ""),
                                sha256=str(f.get("sha256") or "").lower(), flash="windows", scheme=scheme,
                                severity=_severity(f), match_name="MCU" if kind == "controller" else ""))
    return out


def fetch(client, model: str) -> list[dict]:
    return parse(load_json(client.get(API.format(model=model), headers={"Accept": "application/json"})), model)
