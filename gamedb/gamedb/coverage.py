"""Coverage check: the games players open first must be in the database.

    python -m gamedb.coverage dist/gamedb.json.gz

Exits 1 and names every game on MUST_HAVE that has no entry (by Steam app
id, main or extra) or an entry without a title. The nightly workflow runs it
before publishing, so a regression keeps last night's file and fails loudly.
Missing time to beat is only reported (IGDB can be skipped or down).

The build also forces these ids into the popular list, so they get an entry
from Steam's own data even when Wikidata has nothing usable.
"""

from __future__ import annotations

import gzip
import json
import sys

# Steam app id -> name (for the message only). Big single-player hits first,
# then the most played games; every one was checked against Steam's store.
MUST_HAVE = {
    "1086940": "Baldur's Gate 3",
    "367520": "Hollow Knight",
    "1593500": "God of War",
    "2050650": "Resident Evil 4 (2023)",
    "990080": "Hogwarts Legacy",
    "2358720": "Black Myth: Wukong",
    "1903340": "Clair Obscur: Expedition 33",
    "1030300": "Hollow Knight: Silksong",
    "1551360": "Forza Horizon 5",
    "1245620": "Elden Ring",
    "1091500": "Cyberpunk 2077",
    "292030": "The Witcher 3: Wild Hunt",
    "271590": "Grand Theft Auto V Legacy",
    "3240220": "Grand Theft Auto V Enhanced",
    "1174180": "Red Dead Redemption 2",
    "730": "Counter-Strike 2",
    "570": "Dota 2",
    "578080": "PUBG: Battlegrounds",
    "1172470": "Apex Legends",
    "413150": "Stardew Valley",
    "105600": "Terraria",
    "252490": "Rust",
    "374320": "Dark Souls III",
    "814380": "Sekiro: Shadows Die Twice",
    "1145360": "Hades",
    "1145350": "Hades II",
    "377160": "Fallout 4",
    "489830": "The Elder Scrolls V: Skyrim Special Edition",
    "1716740": "Starfield",
    "2322010": "God of War Ragnarok",
    "1817070": "Marvel's Spider-Man Remastered",
    "1817190": "Marvel's Spider-Man: Miles Morales",
    "2651280": "Marvel's Spider-Man 2",
    "582010": "Monster Hunter: World",
    "2246340": "Monster Hunter Wilds",
    "553850": "Helldivers 2",
    "1966720": "Lethal Company",
    "435150": "Divinity: Original Sin 2",
    "620": "Portal 2",
    "400": "Portal",
    "646570": "Slay the Spire",
    "632470": "Disco Elysium",
    "504230": "Celeste",
    "268910": "Cuphead",
    "588650": "Dead Cells",
    "1794680": "Vampire Survivors",
    "2379780": "Balatro",
    "601150": "Devil May Cry 5",
    "883710": "Resident Evil 2",
    "2215430": "Ghost of Tsushima",
    "1623730": "Palworld",
    "550": "Left 4 Dead 2",
    "4000": "Garry's Mod",
    "227300": "Euro Truck Simulator 2",
}


def index(doc: dict) -> dict[str, dict]:
    out: dict[str, dict] = {}
    for g in doc.get("games", []):
        ids = g.get("ids") if isinstance(g, dict) else None
        if not isinstance(ids, dict):
            continue
        for sid in [ids.get("steam"), *(ids.get("steam_more") or [])]:
            if sid:
                out.setdefault(str(sid), g)
    return out


def check(doc: dict, must: dict[str, str] | None = None) -> tuple[list[str], list[str]]:
    """(missing, without time to beat): lines naming each game."""
    must = MUST_HAVE if must is None else must
    idx = index(doc)
    missing, no_ttb = [], []
    for sid, name in must.items():
        g = idx.get(sid)
        if not g or not g.get("title"):
            missing.append(f"{name} (Steam {sid})")
        elif not g.get("time_to_beat"):
            no_ttb.append(f"{name} (Steam {sid})")
    return missing, no_ttb


def main(argv: list[str] | None = None) -> int:
    argv = sys.argv[1:] if argv is None else argv
    path = argv[0] if argv else "dist/gamedb.json.gz"
    with open(path, "rb") as f:
        raw = f.read()
    doc = json.loads(gzip.decompress(raw) if raw[:2] == b"\x1f\x8b" else raw)
    missing, no_ttb = check(doc)
    if no_ttb:
        print(f"note: {len(no_ttb)} must-have games without time to beat: " + "; ".join(no_ttb))
    if missing:
        print(f"::error::gamedb is missing {len(missing)} of {len(MUST_HAVE)} must-have games: " + "; ".join(missing),
              file=sys.stderr)
        return 1
    print(f"coverage ok: all {len(MUST_HAVE)} must-have games present")
    return 0


if __name__ == "__main__":
    sys.exit(main())
