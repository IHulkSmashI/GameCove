# gamedb

Builds GameCove's open game database every night and publishes it as a GitHub release asset. The app downloads it from there, so there's no server and no API keys on players' devices.

| Field | Source | License |
| --- | --- | --- |
| Title, release year, Steam / GOG / Epic ids | Wikidata | CC0 |
| Anti-cheat status (works / blocked / denied) | AreWeAntiCheatYet | MIT |
| Time to beat (main, main + extras, 100%, submission count) | IGDB `game_time_to_beats` | IGDB terms, credit IGDB.com |
| Compatibility rating | ProtonDB data dumps (next) | ODbL |

```
pip install -e '.[test]'
pytest
python -m gamedb.build --out dist/gamedb.json.gz
```

IGDB needs `TWITCH_CLIENT_ID` and `TWITCH_CLIENT_SECRET` in the environment; without them the build skips time to beat.
