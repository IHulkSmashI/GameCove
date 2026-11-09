"""Small helpers every source shares."""
from __future__ import annotations

import html
import json
import re

_TAG = re.compile(r"<[^>]+>")


def text(s: object, limit: int = 400) -> str:
    """Plain text from a maker's HTML-ish description, cut to `limit` characters."""
    t = html.unescape(_TAG.sub(" ", str(s or "").replace("<br/>", "\n").replace("<br>", "\n")))
    t = re.sub(r"[ \t]+", " ", t)
    t = re.sub(r"\s*\n\s*", "\n", t).strip()
    return t[:limit].rstrip()


def date(s: object) -> str:
    """'2026/10/14', '2026-10-14T..', unix ms -> '2026-10-14' ('' when unreadable)."""
    if isinstance(s, (int, float)) and s > 0:
        import datetime as dt
        sec = s / 1000 if s > 1e11 else s
        return dt.datetime.fromtimestamp(sec, dt.timezone.utc).strftime("%Y-%m-%d")
    m = re.match(r"(\d{4})[/-](\d{1,2})[/-](\d{1,2})", str(s or ""))
    return f"{int(m[1]):04d}-{int(m[2]):02d}-{int(m[3]):02d}" if m else ""


def load_json(raw: bytes) -> object:
    return json.loads(raw.decode("utf-8", "replace"))


def item(kind: str, name: str, version: str, **kw) -> dict:
    """One firmware entry of the index. Only known keys, empty ones dropped."""
    out = {"kind": kind, "name": name, "version": str(version or "").strip()}
    for k in ("date", "notes", "notes_url", "download_page", "download_url", "sha256", "size", "flash",
              "scheme", "severity", "board", "match_name"):
        v = kw.get(k)
        if v not in (None, "", [], {}):
            out[k] = v
    return out
