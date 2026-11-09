"""MSI: the support panel JSON MSI's own support page loads (ported from ClawDeck msibios.py).

  https://www.msi.com/api/v1/product/support/panel?product=<page>&type=bios
  -> result.downloads.BIOS[]: {download_version "E1T91IMS.10E", download_release "2026-10-30",
     download_url, download_title, download_description}

The part before the dot is the board ("E1T91IMS" = Claw 8 EX); after it MSI's revision in hex
(10D < 10E < 114). One entry per board, newest revision. MSI's Akamai front refuses some cloud
networks; the build then keeps last night's entry (build.py).
"""
from __future__ import annotations

from .common import date, item, load_json, text

API = "https://www.msi.com/api/v1/product/support/panel?product={page}&type=bios"
PAGE = "https://www.msi.com/Handheld/{page}/support#bios"


def split(v: str) -> tuple[str, str]:
    board, _, rev = (v or "").strip().partition(".")
    return board.upper(), rev.upper()


def rev(r: str) -> int:
    try:
        return int(r, 16)
    except ValueError:
        return -1


def parse(doc: object, page: str) -> list[dict]:
    entries = ((((doc or {}).get("result") or {}).get("downloads") or {}).get("BIOS") or []) if isinstance(doc, dict) else []
    best: dict[str, dict] = {}
    for e in entries:
        v = str(e.get("download_version") or "")
        b, r = split(v)
        if not b or rev(r) < 0:
            continue
        if b not in best or rev(r) > rev(split(best[b]["download_version"])[1]):
            best[b] = e
    url = PAGE.format(page=page)
    return [item("bios", "BIOS", str(e["download_version"]), date=date(e.get("download_release")),
                 notes=text(e.get("download_description")), notes_url=url, download_page=url,
                 download_url=str(e.get("download_url") or ""), flash="msi-usb", scheme="msi",
                 severity="recommended", board=b) for b, e in sorted(best.items())]


def fetch(client, page: str) -> list[dict]:
    return parse(load_json(client.get(API.format(page=page), headers={"Accept": "application/json"})), page)
