# gamedb

Builds GameCove's open game database every night and publishes it as a GitHub release asset (`gamedb.json.gz` on the rolling `gamedb` release of [GameCove-data](https://github.com/IHulkSmashI/GameCove-data), whose `gamedb.yml` runs this package at a pinned GameCove commit). The app downloads it from there, so there's no server and no API keys on players' devices.

| Field | Source | License |
| --- | --- | --- |
| Title, release year, Steam / GOG / Epic ids | Wikidata (English label, else the `mul` label) | CC0 |
| `popular` rank; title and year for popular games Wikidata doesn't cover | Steam Web API (keyless store lists) | [Steam Web API Terms of Use](https://steamcommunity.com/dev/apiterms) |
| Anti-cheat status (works / blocked / denied) | AreWeAntiCheatYet | MIT |
| Time to beat (main, main + extras, 100%, submission count) | IGDB `game_time_to_beats` | IGDB terms, credit IGDB.com |
| `meta.igdb` (summary, genres, themes, modes, developers, publishers, release date, screenshots for popular games), `critics.igdb_critic` (critic average, review count) | IGDB `games` (matched by Steam id, else by IGDB's GOG / Epic ids) | IGDB terms, credit IGDB.com |
| `meta.steam` (short description, genres, developers, publishers, release date, controller support, `at`), `critics.metacritic` (`score`, `url`) | Steam store `appdetails` (keyless), a slice of the popular games each night | [Steam Web API Terms of Use](https://steamcommunity.com/dev/apiterms); Metacritic's score as Valve publishes it, credit Metacritic and link `url` |
| `meta.wikidata` (genres, developers, publishers) | Wikidata P136 / P178 / P123 | CC0 |
| `protondb` compatibility tier | Our summary of ProtonDB user reports from [bdefore/protondb-data](https://github.com/bdefore/protondb-data) | ODbL 1.0 |

```
pip install -e '.[test]'
pytest
python -m gamedb.build --out dist/gamedb.json.gz [--max-minutes 50]
```

IGDB needs `TWITCH_CLIENT_ID` and `TWITCH_CLIENT_SECRET` in the environment; without them time to beat is marked `skipped` and last night's values are kept. `GITHUB_TOKEN` (optional) is used to list the ProtonDB dumps.

## Popular games are always covered

The games players open first must never be missing, so (`gamedb/sources/steamtop.py`, `gamedb/coverage.py`):

- **Titles:** Wikidata's English label, else its `mul` ("all languages") label. Since 2024 editors move proper names
  to `mul`, and an English-only query left Baldur's Gate 3, Hollow Knight, God of War, Hogwarts Legacy and about
  1,700 other Steam games untitled, and untitled items were dropped.
- **Popular list:** the store's top 1000 released games by reviews (`IStoreQueryService/Query` sort 23) and by
  popularity (sort 11), plus the top 100 by players right now (`ISteamChartsService/GetMostPlayedGames`). Every one
  gets an entry, from Steam's own title and year when Wikidata has no item for it, and a `popular` rank (0 = most
  popular). On equal titles the more popular game sorts first, so the app's title fallback finds Resident Evil 4
  (2023) before the 2005 original. `coverage.MUST_HAVE` (54 hand-checked app ids) is always added to the list.
- **Every Steam id:** an item listing several Steam apps keeps the lowest as `ids.steam` and the rest in
  `ids.steam_more`; the app indexes both.
- **Time to beat, three routes to IGDB:** `external_games` by Steam uid (paged, as one uid can map to several IGDB
  games), then Wikidata's IGDB id (P5794 slug) for ids that found nothing, then, for popular games still without a
  value, an IGDB title search kept only on an exact normalised title within a year of the release (at most 400 a
  night). With several IGDB games for one Steam app, the sane value with the most submissions wins.
- **Sanity checks** (`gamedb/ttb.py`): a record out of order (main > main + extras > 100%) is dropped; values under
  15 min or over 1000 h are dropped; for popular games a value under 2 h is dropped unless 10+ players submitted it
  and the 100% time is within 10x (Portal is 1.9 h, Forza Horizon 5 isn't 1 h); a main under 1/40 of the 100% time
  is dropped. Last night's values go through the same checks.
- **Coverage check:** `python -m gamedb.coverage dist/gamedb.json.gz` exits 1 naming any `MUST_HAVE` game without an
  entry. The nightly runs it before publishing, so a regression fails loudly and last night's file stays.

## Game details and critic scores

The app fills in missing details for every library game from these blocks (docs/CONTRACTS.md, "Game details"):

```json
"meta": {"igdb": {"summary": "...", "genres": ["Role-playing (RPG)"], "themes": ["Fantasy"], "modes": ["Single player"],
                  "developers": ["Supergiant Games"], "publishers": ["Supergiant Games"], "release_date": "2020-09-17",
                  "screens": ["https://images.igdb.com/igdb/image/upload/t_screenshot_med/sc8ivc.jpg"]},
         "steam": {"summary": "...", "genres": ["Action", "Indie", "RPG"], "controller": "full", "at": "2026-11-09"},
         "wikidata": {"genres": ["Action role-playing"]}},
"critics": {"metacritic": {"score": 93, "url": "https://www.metacritic.com/game/pc/hades"},
            "igdb_critic": {"score": 93, "count": 37}}
```

- **IGDB:** every Steam id IGDB maps (same three routes as time to beat), plus games that are only on GOG or Epic
  through IGDB's `external_games` for those stores. Of several IGDB games for one store id, the one with a summary
  and the most critic reviews wins. Screenshot links only for popular games (they're the costly field).
- **Steam store:** `appdetails` answers one app per request and allows about 200 requests per 5 minutes, so each night
  refreshes `steamstore.PER_NIGHT` (350) popular games, never-fetched first, then the oldest `at`, one request every
  1.6 s; the rest keep last night's values. The app fetches other games on demand.
- **Metacritic:** only Steam's own `metacritic` field (official, with the link). Metacritic's site is never fetched.
  The app shows a GOG/Epic game the score of its Steam twin (same record, matched by store ids).
- **OpenCritic:** not here. Its API (RapidAPI, free plan about 25 searches and 200 requests a day) doesn't permit
  republishing its scores in a public file, so the app fetches them with the user's own key (CREDITS.md).
- **Wikidata:** genres, developers and publishers as the last fallback; genre names lose "video game".
- Text is cleaned (tags, entities, whitespace), summaries cut at a sentence near 600 characters, lists capped at 6.
- Like every source, each falls back to last night's values when it fails (`igdb_details`, `steamstore`,
  `wikidata_meta` in `sources`).

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
    "steam": {"status": "ok", "seconds": 3, "count": 1518},
    "areweanticheatyet": {"status": "ok", "seconds": 1, "count": 1120},
    "igdb": {"status": "skipped", "error": "no TWITCH_CLIENT_ID / TWITCH_CLIENT_SECRET", "kept_previous": true, "count": 20311},
    "protondb": {"status": "ok", "seconds": 12, "count": 5936, "dump": "reports_nov1_2026.tar.gz"}
  },
  "credits": "...",
  "count": 61000,
  "games": [{"title": "Brotato", "wikidata": "Q...", "released": 2023, "ids": {"steam": "1942280"}, "popular": 412, "protondb": "platinum"}]
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
`firmware` release of IHulkSmashI/GameCove-data by that repo's `.github/workflows/firmware.yml`. Sources and schema: `gamedb/firmware/`;
app side: docs/SYSTEM.md "Firmware, BIOS and drivers".
