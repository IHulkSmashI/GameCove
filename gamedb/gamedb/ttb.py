"""Sanity checks for time-to-beat values.

IGDB's time-to-beat rows are user submissions, and a few submissions can be
plainly wrong: Forza Horizon 5 had main = 1 h, main + extras = 1 h and
100% = 132 h from 4 submissions. These checks drop values that can't be
right instead of showing them:

- a value under 15 minutes, or over 1000 h (live-service games collect
  "100%" times in the thousands of hours),
- for games on the popular list, a value under 2 h, unless at least 10
  players submitted the record and its 100% time is within 10x of it (Portal
  really is 1.9 h; Forza Horizon 5 isn't 1 h),
- a main value under 1/40 of the completionist value (the FH5 shape),
- a record whose values are out of order (main > main + extras > 100%,
  with 5% slack): one of them is wrong and we can't tell which, so the whole
  record goes.

`pick` chooses among several candidate records for one game (several IGDB
entries for one Steam app, or IGDB vs last night's value): the sane one with
the most submissions wins.
"""

from __future__ import annotations

KEYS = ("main_h", "extra_h", "complete_h")
BIG_FLOOR_H = 2.0
BIG_SHORT_MIN_COUNT = 10
BIG_SHORT_MAX_SPREAD = 10.0
FLOOR_H = 0.25
MAX_H = 1000.0
MAX_SPREAD = 40.0  # complete_h / main_h above this means main_h is bogus
ORDER_SLACK = 1.05


def _num(v) -> float | None:
    return float(v) if isinstance(v, (int, float)) and not isinstance(v, bool) and v > 0 else None


def clean(t: dict | None, big: bool = False) -> dict | None:
    """The record with bogus values removed, or None when nothing sane is left."""
    if not isinstance(t, dict):
        return None
    vals = {k: _num(t.get(k)) for k in KEYS}
    present = [vals[k] for k in KEYS if vals[k] is not None]
    # Out of order: main <= main + extras <= 100% must hold for whatever is present.
    for a, b in zip(present, present[1:]):
        if a > b * ORDER_SLACK:
            return None
    count = t.get("count") if isinstance(t.get("count"), int) else 0
    complete = vals["complete_h"]
    for k in KEYS:
        v = vals[k]
        if v is None:
            continue
        if v < FLOOR_H or v > MAX_H:
            vals[k] = None
        elif big and v < BIG_FLOOR_H:
            short_game = count >= BIG_SHORT_MIN_COUNT and complete is not None and complete <= BIG_SHORT_MAX_SPREAD * v
            if not short_game:
                vals[k] = None
    main, extra, complete = vals["main_h"], vals["extra_h"], vals["complete_h"]
    if main is not None and complete is not None and complete > MAX_SPREAD * main:
        vals["main_h"] = None
        if extra is not None and complete > MAX_SPREAD * extra:
            vals["extra_h"] = None
    if not any(vals[k] is not None for k in KEYS):
        return None
    out = dict(t)
    out.update({k: v for k, v in vals.items() if k in t})
    return out


def pick(candidates: list[dict | None], big: bool = False) -> dict | None:
    """The sane candidate with the most submissions (then the most fields filled)."""
    best, best_key = None, None
    for c in candidates:
        c = clean(c, big)
        if c is None:
            continue
        key = (int(c.get("count") or 0), sum(c.get(k) is not None for k in KEYS))
        if best_key is None or key > best_key:
            best, best_key = c, key
    return best
