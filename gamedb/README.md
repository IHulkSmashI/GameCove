# gamedb

Builds GameCove's open game database every night and publishes it as a GitHub release asset (`gamedb.json.gz` on the rolling `gamedb` release). The app downloads it from there, so there's no server and no API keys on players' devices.

| Field | Source | License |
| --- | --- | --- |
| Title, release year, Steam / GOG / Epic ids | Wikidata | CC0 |
| Anti-cheat status (works / blocked / denied) | AreWeAntiCheatYet | MIT |
| Time to beat (main, main + extras, 100%, submission count) | IGDB `game_time_to_beats` | IGDB terms, credit IGDB.com |
| `protondb` compatibility tier | Our summary of ProtonDB user reports from [bdefore/protondb-data](https://github.com/bdefore/protondb-data) | ODbL 1.0 |

```
pip install -e '.[test]'
pytest
python -m gamedb.build --out dist/gamedb.json.gz [--max-minutes 50]
```

IGDB needs `TWITCH_CLIENT_ID` and `TWITCH_CLIENT_SECRET` in the environment; without them time to beat is marked `skipped` and last night's values are kept. `GITHUB_TOKEN` (optional) is used to list the ProtonDB dumps.

## ProtonDB tiers

**The `protondb` value is GameCove's own summary of ProtonDB's user reports, not ProtonDB's official tier.** ProtonDB's site uses its own weighting, so the two can differ. How we get it (`gamedb/sources/protondb.py`):

1. Take the newest monthly dump from bdefore/protondb-data (each one holds every report since October 2019).
2. Keep reports from the 540 days (about 18 months) before the newest report in that dump.
3. Put each report in one bucket from the fields its format has:
   - **borked**: `verdict` is "no", or it didn't install, open or reach gameplay (`installs` / `opens` / `startsPlay` "no").
   - **tinkering**: it works, but needed tweaks (`type` "tinker" in 2019-2022 reports; `verdictOob` "no", `triedOob` "no", `tinkerOverride` "yes" or any `customizationsUsed` in 2022+ reports) or has `significantBugs`.
   - **works**: everything else that says it works.
   - Pre-October 2019 reports carry a `rating` word instead: Platinum = works, Gold / Silver / Bronze = tinkering, Borked = borked.
4. Games with fewer than 3 recent reports get no tier.
5. More than half borked → `borked`. Otherwise score = mean of works 1, tinkering 0.75, borked 0: `platinum` ≥ 0.90, `gold` ≥ 0.75, `silver` ≥ 0.60, else `bronze`.

ProtonDB report data © ProtonDB contributors, made available under the [Open Database License 1.0](https://opendatacommons.org/licenses/odbl/1-0/) (individual contents under the [DbCL](https://opendatacommons.org/licenses/dbcl/1-0/)). Our tiers are a derived database, so **the ProtonDB-derived data in `gamedb.json.gz` is shared under the ODbL 1.0 as well**: you may reuse it, but credit ProtonDB and keep any database you derive from it open under the ODbL. The document's `credits` field says the same.

## When a source is down

Every request goes through `gamedb/net.py`: 429 / 5xx / network errors are retried, `Retry-After` is honoured (seconds or a date) and then kept as the pace for later requests (Wikidata has answered "1 req / min" during outages), otherwise exponential backoff. Each source has its own time limit, all inside `--max-minutes`; a wait that wouldn't fit gives up at once instead of sleeping.

Before fetching, the build downloads the previously published `gamedb.json.gz`. A source that fails, or comes back with under 90% of last night's entries, is replaced by its fields from that file, so one source being down never fails the build and a nightly never publishes a worse file. The build only exits non-zero (and the old release asset stays) when there's nothing at all to publish.

## Output

Gzipped compact JSON, schema 2. Null fields are left out, so a missing field means null. `sources` records what happened to each source:

```json
{
  "schema": 2,
  "built": "2026-11-08T06:40:00Z",
  "sources": {
    "previous": {"status": "ok", "seconds": 1, "count": 61234},
    "wikidata": {"status": "fallback", "error": "GiveUp: HTTP 429 ...", "kept_previous": true, "previous_built": "2026-11-07T06:41:12Z", "count": 61234},
    "areweanticheatyet": {"status": "ok", "seconds": 1, "count": 1120},
    "igdb": {"status": "skipped", "error": "no TWITCH_CLIENT_ID / TWITCH_CLIENT_SECRET", "kept_previous": true, "count": 20311},
    "protondb": {"status": "ok", "seconds": 12, "count": 5936, "dump": "reports_nov1_2026.tar.gz"}
  },
  "credits": "...",
  "count": 61000,
  "games": [{"title": "Brotato", "wikidata": "Q...", "released": 2023, "ids": {"steam": "1942280"}, "protondb": "platinum"}]
}
```

`status` is `ok`, `fallback` (failed, last night's data kept), `failed` (failed, nothing to fall back to) or `skipped` (not configured). The build prints the file size when it's done.
