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

## Discover calendar (`upcoming.json.gz`)

A second, small file on the same release, for the app's Discover area:

```
python -m gamedb.upcoming --out dist/upcoming.json.gz [--max-minutes 12]
```

| Field | Source | Terms |
| --- | --- | --- |
| Coming-soon Steam games (the store's popularity order, top 300, adult-only titles left out), dates with Steam's own precision, art URLs | Steam Web API `IStoreQueryService/Query`, no key | [Steam Web API Terms of Use](https://steamcommunity.com/dev/apiterms) |
| PC release dates (`release_dates`, platform 6) | IGDB, only with `TWITCH_CLIENT_ID` / `TWITCH_CLIENT_SECRET` | Free for non-commercial use (Twitch Developer Service Agreement); credit IGDB.com |
| Video games (P31 Q7889) with a future publication date (P577) and its precision, PC only (a Steam/GOG/Epic id or Windows/Linux platform), minus games already out earlier | Wikidata | CC0 |
| `fx`: euro reference rates, as published (the app doesn't use them for displayed prices) | ECB | Free reuse, unmodified, "Source: ECB statistics" |

Records are merged by Steam id, then by normalised title; the date comes from Steam, else IGDB, else Wikidata, whichever isn't TBA. Precision is `day`, `month`, `quarter`, `year` or `tba`; dates are `2026-12-04`, `2026-12`, `2027-Q1`, `2027` or `""`. Entries stay for 14 days after release ("Out now"). Like the main build, a failing source is replaced by what it contributed to last night's file, and the exchange rates fall back to last night's. Shape: see docs/CONTRACTS.md ("Discover").

The Wikidata query avoids `EXISTS` / `NOT EXISTS`: with them the public endpoint times out. The "already out" check is a second query over the matching items only.

## Firmware index

`python -m gamedb.firmware.build --out dist/firmware.json.gz` builds the handheld firmware index
(maker BIOS/EC/controller versions and driver-stack upstream versions) published nightly on the
`firmware` release by `.github/workflows/firmware.yml`. Sources and schema: `gamedb/firmware/`;
app side: docs/SYSTEM.md "Firmware, BIOS and drivers".
