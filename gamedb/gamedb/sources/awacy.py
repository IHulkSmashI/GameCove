"""Anti-cheat status from AreWeAntiCheatYet (MIT)."""

from __future__ import annotations

import json

from ..net import Client

URL = "https://raw.githubusercontent.com/AreWeAntiCheatYet/AreWeAntiCheatYet/HEAD/games.json"

# Their status words -> what we show on a tile
STATUS = {
    "supported": "works",
    "running": "works",
    "planned": "blocked",
    "broken": "blocked",
    "denied": "denied",
}


def fetch(client: Client) -> list:
    data = json.loads(client.get(URL))
    if not isinstance(data, list):
        raise ValueError("AreWeAntiCheatYet games.json is not a list")
    return data


def _steam_id(store_ids) -> str | None:
    if not isinstance(store_ids, dict):
        return None
    sid = store_ids.get("steam")
    if isinstance(sid, (str, int)) and str(sid).isdigit():
        return str(sid)
    return None


def by_steam_id(entries: list) -> dict[str, dict]:
    """Steam app id -> {"status", "anticheats", "name"}. Entries without a Steam id are skipped."""
    out: dict[str, dict] = {}
    for e in entries:
        if not isinstance(e, dict):
            continue
        sid = _steam_id(e.get("storeIds"))
        if sid is None:
            continue
        raw = str(e.get("status", "")).strip().lower()
        out[sid] = {
            "status": STATUS.get(raw, "unknown"),
            "anticheats": [a for a in e.get("anticheats", []) if isinstance(a, str)],
            "name": e.get("name", ""),
        }
    return out
