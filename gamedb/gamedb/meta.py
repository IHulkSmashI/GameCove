"""Game details ("metadata") shared by the sources that provide them.

Every source fills the same small shape, so the app can merge them field by
field (docs/CONTRACTS.md "Game details"):

    {"summary": str, "genres": [str], "themes": [str], "modes": [str],
     "developers": [str], "publishers": [str], "release_date": "YYYY-MM-DD",
     "controller": "full" | "partial", "screens": [https URL]}

Missing fields are left out. Critic scores travel separately in a game's
`critics` block: {"metacritic": {"score", "url"}, "igdb_critic": {"score", "count"}}.

Text from the sources is cleaned here: HTML tags and entities go, whitespace
is folded, summaries are cut at a sentence end near SUMMARY_MAX, lists are
de-duplicated and capped. URLs are kept only when they are https on the host
the source is known to use.
"""

from __future__ import annotations

import datetime as dt
import html
import re
import urllib.parse

SUMMARY_MAX = 600
LIST_MAX = 6
SCREENS_MAX = 4
TEXT_MAX = 80
FIELDS = ("summary", "genres", "themes", "modes", "developers", "publishers", "release_date", "controller", "screens")

_TAG = re.compile(r"<[^>]+>")
_WS = re.compile(r"\s+")
_DATE = re.compile(r"\d{4}-\d{2}-\d{2}")


def clean_text(value, limit: int = TEXT_MAX) -> str:
    """Plain text: tags and entities removed, whitespace folded, at most `limit` chars."""
    if not isinstance(value, str):
        return ""
    s = _WS.sub(" ", html.unescape(_TAG.sub(" ", value))).strip()
    return s[:limit].rstrip()


def summary(value) -> str:
    """A synopsis cut at the last sentence end before SUMMARY_MAX (else at a word, with an ellipsis)."""
    s = clean_text(value, 100000)
    if len(s) <= SUMMARY_MAX:
        return s
    cut = s[:SUMMARY_MAX]
    end = max(cut.rfind(". "), cut.rfind("! "), cut.rfind("? "))
    if end >= SUMMARY_MAX // 2:
        return cut[:end + 1]
    return cut[:cut.rfind(" ")].rstrip(",;:") + "…"


def clean_list(values, limit: int = LIST_MAX) -> list[str]:
    out: list[str] = []
    seen: set[str] = set()
    for v in values if isinstance(values, list) else []:
        s = clean_text(v)
        if s and s.casefold() not in seen:
            seen.add(s.casefold())
            out.append(s)
        if len(out) >= limit:
            break
    return out


def iso_date(stamp) -> str | None:
    """A unix time (seconds) as YYYY-MM-DD (UTC)."""
    if isinstance(stamp, bool) or not isinstance(stamp, (int, float)) or stamp <= 0:
        return None
    return dt.datetime.fromtimestamp(stamp, dt.timezone.utc).strftime("%Y-%m-%d")


_MONTHS = {m: i + 1 for i, m in enumerate(
    ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"])}


def steam_date(text) -> str | None:
    """Steam's English release date ("3 Aug, 2023", "Aug 3, 2023", "2023-08-03") as YYYY-MM-DD.
    Month- or year-only dates ("Q4 2026", "Coming soon") give None."""
    if not isinstance(text, str):
        return None
    t = text.strip()
    if _DATE.fullmatch(t):
        return t
    m = re.fullmatch(r"(\d{1,2}) ([A-Za-z]{3})[a-z]*\.?,? (\d{4})", t) or None
    if m:
        day, mon, year = m.group(1), m.group(2), m.group(3)
    else:
        m = re.fullmatch(r"([A-Za-z]{3})[a-z]*\.? (\d{1,2}),? (\d{4})", t)
        if not m:
            return None
        mon, day, year = m.group(1), m.group(2), m.group(3)
    month = _MONTHS.get(mon.lower())
    if not month:
        return None
    try:
        return dt.date(int(year), month, int(day)).isoformat()
    except ValueError:
        return None


def https_url(value, hosts: tuple[str, ...]) -> str | None:
    """`value` if it is an https URL on one of `hosts` (or a subdomain), else None."""
    if not isinstance(value, str) or len(value) > 500:
        return None
    try:
        u = urllib.parse.urlsplit(value)
    except ValueError:
        return None
    host = (u.hostname or "").lower()
    if u.scheme != "https" or not any(host == h or host.endswith("." + h) for h in hosts):
        return None
    return value


def metacritic(value) -> dict | None:
    """Steam appdetails' {"score", "url"} block, checked: score 0-100 and a metacritic.com URL.
    The URL's tracking query (Steam adds ?ftag=...) is dropped."""
    if not isinstance(value, dict):
        return None
    score = value.get("score")
    if isinstance(score, bool) or not isinstance(score, (int, float)) or not 0 < score <= 100:
        return None
    url = https_url(value.get("url"), ("metacritic.com",))
    if url is None:
        # Steam has served http:// links for older games; upgrade them.
        raw = value.get("url")
        if isinstance(raw, str) and raw.startswith("http://"):
            url = https_url("https://" + raw[len("http://"):], ("metacritic.com",))
    out = {"score": int(round(score))}
    if url:
        out["url"] = url.split("?", 1)[0]
    return out


def score(value, count) -> dict | None:
    """A critic average (0-100) and how many reviews it comes from."""
    if isinstance(value, bool) or not isinstance(value, (int, float)) or not 0 < value <= 100:
        return None
    n = count if isinstance(count, int) and not isinstance(count, bool) and count > 0 else 0
    return {"score": int(round(value)), "count": n}


def compact(m: dict) -> dict:
    """Only the known fields that have a value."""
    return {k: m[k] for k in FIELDS if m.get(k) not in (None, "", [], {})}
