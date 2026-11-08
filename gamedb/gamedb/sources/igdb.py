"""Time to beat from IGDB's game_time_to_beats endpoint.

Needs TWITCH_CLIENT_ID and TWITCH_CLIENT_SECRET (a GitHub Actions secret in the
nightly job; never shipped to players). Skipped cleanly when they're missing.
IGDB allows 4 requests a second and 500 rows per request.
"""

from __future__ import annotations

import json
import os
import time
import urllib.parse
import urllib.request

TOKEN_URL = "https://id.twitch.tv/oauth2/token"
API = "https://api.igdb.com/v4/"
STEAM_SOURCE = 1  # IGDB external game source id for Steam
BATCH = 500


def credentials() -> tuple[str, str] | None:
    cid, secret = os.environ.get("TWITCH_CLIENT_ID"), os.environ.get("TWITCH_CLIENT_SECRET")
    return (cid, secret) if cid and secret else None


def token(cid: str, secret: str) -> str:
    q = urllib.parse.urlencode({"client_id": cid, "client_secret": secret, "grant_type": "client_credentials"})
    with urllib.request.urlopen(urllib.request.Request(f"{TOKEN_URL}?{q}", method="POST"), timeout=30) as r:
        return json.load(r)["access_token"]


def post(endpoint: str, body: str, cid: str, tok: str) -> list:
    req = urllib.request.Request(
        API + endpoint,
        data=body.encode(),
        headers={"Client-ID": cid, "Authorization": f"Bearer {tok}", "Accept": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=60) as r:
        out = json.load(r)
    time.sleep(0.3)
    return out


def hours(seconds) -> float | None:
    return round(seconds / 3600, 1) if isinstance(seconds, (int, float)) and seconds > 0 else None


def to_time_to_beat(row: dict) -> dict | None:
    t = {
        "main_h": hours(row.get("hastily")),
        "extra_h": hours(row.get("normally")),
        "complete_h": hours(row.get("completely")),
        "count": row.get("count", 0),
        "source": "igdb",
    }
    return t if any(t[k] for k in ("main_h", "extra_h", "complete_h")) else None


def fetch_for_steam(steam_ids: list[str]) -> dict[str, dict]:
    """Steam app id -> time to beat. Empty when credentials are missing."""
    creds = credentials()
    if not creds:
        return {}
    cid, secret = creds
    tok = token(cid, secret)
    steam_to_game: dict[str, int] = {}
    for i in range(0, len(steam_ids), BATCH):
        chunk = ",".join(f'"{s}"' for s in steam_ids[i:i + BATCH])
        rows = post("external_games",
                    f"fields game,uid; where external_game_source = {STEAM_SOURCE} & uid = ({chunk}); limit {BATCH};",
                    cid, tok)
        for r in rows:
            if "game" in r and "uid" in r:
                steam_to_game[str(r["uid"])] = r["game"]
    game_to_steam = {g: s for s, g in steam_to_game.items()}
    out: dict[str, dict] = {}
    games = list(game_to_steam)
    for i in range(0, len(games), BATCH):
        ids = ",".join(str(g) for g in games[i:i + BATCH])
        rows = post("game_time_to_beats",
                    f"fields game_id,hastily,normally,completely,count; where game_id = ({ids}); limit {BATCH};",
                    cid, tok)
        for r in rows:
            ttb = to_time_to_beat(r)
            if ttb and r.get("game_id") in game_to_steam:
                out[game_to_steam[r["game_id"]]] = ttb
    return out
