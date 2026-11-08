"""Compatibility tiers summarised from ProtonDB's report dumps (ODbL).

ProtonDB publishes every user report as a monthly dump in
github.com/bdefore/protondb-data (`reports/reports_<mon><day>_<year>.tar.gz`,
one JSON array `reports_piiremoved.json` inside). Each dump since December 2019
holds every report since the October 2019 questionnaire, so the newest dump is
all we need for recent reports.

This is OUR summary of those reports, not ProtonDB's official tier (which uses
its own, unpublished weighting). Method:

1. Keep reports from the WINDOW_DAYS before the newest report in the dump
   (anchored to the dump, not the clock, so a rebuild gives the same answer).
2. Put each report in one bucket - works / tinkering / borked - from the fields
   its format version has (see `classify`).
3. Games with fewer than MIN_REPORTS recent reports get no tier.
4. If more than half the reports are borked the tier is "borked". Otherwise the
   score is the mean of works = 1, tinkering = 0.75, borked = 0, and
   platinum >= 0.90, gold >= 0.75, silver >= 0.60, else bronze.

Report formats seen across the dumps:

* v1 (dumps up to Nov 2019, reports before 28 Oct 2019): flat objects with
  `appId`, `timestamp` and `rating` = Platinum/Gold/Silver/Bronze/Borked.
* v2 (questionnaire, 28 Oct 2019 - 18 Feb 2022): `app.steam.appId`, `timestamp`,
  `responses` with `verdict` yes/no, `type` steamPlay/tinker, `installs`,
  `opens`, `startsPlay`, `significantBugs` and the `*Faults` answers.
* v3 (from 18 Feb 2022): like v2 without `type`; adds `variant`, `triedOob`,
  `verdictOob`, `tinkerOverride`, `customizationsUsed`, `launchOptions`.
"""

from __future__ import annotations

import datetime as dt
import io
import json
import os
import re
import tarfile
from collections import defaultdict
from typing import IO, Iterable, Iterator

from ..net import Client, GiveUp, NotFound

REPO_API = "https://api.github.com/repos/bdefore/protondb-data/contents/reports"
RAW = "https://raw.githubusercontent.com/bdefore/protondb-data/HEAD/reports/"

WINDOW_DAYS = 540          # about 18 months
MIN_REPORTS = 3
POINTS = {"works": 1.0, "tinkering": 0.75, "borked": 0.0}
TIERS = ((0.90, "platinum"), (0.75, "gold"), (0.60, "silver"))

_MONTHS = {m: i for i, m in enumerate(
    ("jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"), 1)}
_DUMP = re.compile(r"^reports_([a-z]{3})(\d{1,2})_(\d{4})\.tar\.gz$")


# ---- finding and reading the dump ------------------------------------------

def dump_date(name: str) -> dt.date | None:
    m = _DUMP.match(name)
    if not m or m.group(1) not in _MONTHS:
        return None
    try:
        return dt.date(int(m.group(3)), _MONTHS[m.group(1)], int(m.group(2)))
    except ValueError:
        return None


def latest_dump(names: Iterable[str]) -> str | None:
    dated = [(d, n) for n in names if (d := dump_date(n))]
    return max(dated)[1] if dated else None


def recent_names(today: dt.date, months: int = 3) -> list[str]:
    """Dump names the last few months could have, newest first. Dumps land on
    day 1-5 of a month; used when the GitHub API listing is unavailable."""
    names = []
    y, m = today.year, today.month
    for _ in range(months):
        for d in range(6, 0, -1):
            if dt.date(y, m, d) <= today:
                names.append(f"reports_{list(_MONTHS)[m - 1]}{d}_{y}.tar.gz")
        y, m = (y, m - 1) if m > 1 else (y - 1, 12)
    return names


def iter_array(f: IO[str], chunk: int = 1 << 20) -> Iterator[dict]:
    """Yield the objects of a top-level JSON array without loading it all (the
    current dump is over 500 MB of JSON)."""
    dec = json.JSONDecoder()
    buf, pos, started = "", 0, False
    while True:
        data = f.read(chunk)
        buf = buf[pos:] + data
        pos = 0
        if not started:
            i = buf.find("[")
            if i < 0:
                if not data:
                    return
                continue
            pos, started = i + 1, True
        while True:
            while pos < len(buf) and buf[pos] in " \t\r\n,":
                pos += 1
            if pos < len(buf) and buf[pos] == "]":
                return
            try:
                obj, end = dec.raw_decode(buf, pos)
            except json.JSONDecodeError:
                if not data:
                    raise
                break  # object continues in the next chunk
            pos = end
            yield obj
        if not data:
            return


def iter_reports(tar_bytes: bytes) -> Iterator[dict]:
    with tarfile.open(fileobj=io.BytesIO(tar_bytes), mode="r:gz") as t:
        for m in t:
            if m.isfile() and m.name.endswith(".json"):
                f = t.extractfile(m)
                if f is not None:
                    yield from iter_array(io.TextIOWrapper(f, encoding="utf-8"))


# ---- per-report classification ---------------------------------------------

def app_id(r: dict) -> str | None:
    sid = r.get("appId")
    if sid is None:
        sid = ((r.get("app") or {}).get("steam") or {}).get("appId")
    sid = str(sid) if sid is not None else ""
    return sid if sid.isdigit() else None


def _yes(x) -> bool:
    return x == "yes"


def classify(r: dict) -> str | None:
    """works / tinkering / borked for one report, or None if unreadable."""
    rating = r.get("rating")
    if isinstance(rating, str):  # v1
        return {"platinum": "works", "gold": "tinkering", "silver": "tinkering",
                "bronze": "tinkering", "borked": "borked"}.get(rating.lower())
    x = r.get("responses")
    if not isinstance(x, dict) or x.get("verdict") not in ("yes", "no"):
        return None
    if x["verdict"] == "no" or any(x.get(k) == "no" for k in ("installs", "opens", "startsPlay")):
        return "borked"
    custom = x.get("customizationsUsed")
    tinkered = (
        x.get("type") == "tinker"                                  # v2
        or x.get("verdictOob") == "no"                             # v3: didn't work out of the box
        or x.get("triedOob") == "no"                               # v3: went straight to tweaks
        or _yes(x.get("tinkerOverride"))
        or (isinstance(custom, dict) and any(custom.values()))
    )
    if tinkered or _yes(x.get("significantBugs")):
        return "tinkering"
    return "works"


def tier(counts: dict[str, int]) -> str | None:
    n = sum(counts.get(k, 0) for k in POINTS)
    if n < MIN_REPORTS:
        return None
    if counts.get("borked", 0) * 2 > n:
        return "borked"
    score = sum(POINTS[k] * counts.get(k, 0) for k in POINTS) / n
    for floor, name in TIERS:
        if score >= floor - 1e-9:
            return name
    return "bronze"


def summarise(reports: Iterable[dict], window_days: int = WINDOW_DAYS) -> dict[str, str]:
    """Steam app id -> tier, from an iterable of raw reports (any format)."""
    rows: list[tuple[str, int, str]] = []
    newest = 0
    for r in reports:
        if not isinstance(r, dict):
            continue
        ts, sid, bucket = r.get("timestamp"), app_id(r), classify(r)
        if not isinstance(ts, (int, float)) or sid is None or bucket is None:
            continue
        rows.append((sid, int(ts), bucket))
        newest = max(newest, int(ts))
    cutoff = newest - window_days * 86400
    counts: dict[str, dict[str, int]] = defaultdict(lambda: defaultdict(int))
    for sid, ts, bucket in rows:
        if ts >= cutoff:
            counts[sid][bucket] += 1
    out = {}
    for sid, c in counts.items():
        t = tier(c)
        if t:
            out[sid] = t
    return out


# ---- network ---------------------------------------------------------------

def list_dumps(client: Client) -> list[str]:
    headers = {"Accept": "application/vnd.github+json"}
    tok = os.environ.get("GITHUB_TOKEN") or os.environ.get("GH_TOKEN")
    if tok:
        headers["Authorization"] = f"Bearer {tok}"
    listing = json.loads(client.get(REPO_API, headers=headers))
    return [e.get("name", "") for e in listing if isinstance(e, dict)]


def download_latest(client: Client, today: dt.date | None = None) -> tuple[bytes, str]:
    """(tarball, name) of the newest dump: from the GitHub API listing, or by
    trying this and the previous months' likely names if the API refuses."""
    try:
        name = latest_dump(list_dumps(client))
        if name:
            return client.get(RAW + name), name
    except (GiveUp, ValueError) as e:
        print(f"[protondb] listing unavailable ({e}); trying recent dump names", flush=True)
    for name in recent_names(today or dt.date.today()):
        try:
            return client.get(RAW + name), name
        except NotFound:
            continue
    raise ValueError("no report dump found in bdefore/protondb-data")


def fetch(client: Client, today: dt.date | None = None) -> tuple[dict[str, str], str]:
    """(Steam app id -> tier, dump file name) from the newest ProtonDB dump."""
    data, name = download_latest(client, today)
    return summarise(iter_reports(data)), name
