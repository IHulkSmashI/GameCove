# GameCove game database: sources and credits

Published nightly on the `gamedb` release of github.com/IHulkSmashI/GameCove: `gamedb.json.gz` (game database)
and `upcoming.json.gz` (release calendar). This notice is uploaded next to them and used as the release notes.

- **Game data from IGDB** (https://www.igdb.com): time to beat in `gamedb.json.gz` and upcoming release dates in
  `upcoming.json.gz`, used with credit to IGDB under the Twitch Developer Service Agreement. Anyone reusing these
  fields must credit IGDB the same way.
- **Compatibility tiers** (`protondb` field): GameCove's own summary of ProtonDB community reports
  (https://www.protondb.com, data from github.com/bdefore/protondb-data), not ProtonDB's official ratings.
  ProtonDB report data is made available under the Open Database License 1.0
  (https://opendatacommons.org/licenses/odbl/1-0/), its contents under the DbCL 1.0; the ProtonDB-derived data in
  `gamedb.json.gz` is shared under the ODbL 1.0 as well: credit ProtonDB and keep databases derived from it open
  under the ODbL.
- **Wikidata** (CC0 1.0): titles, release years, cross-store ids, release dates.
- **AreWeAntiCheatYet** (MIT): anti-cheat status.
- **Steam store data** (Valve, Steam Web API): which games are most popular (`popular` rank in `gamedb.json.gz`,
  with the store's title and release year for popular games Wikidata doesn't cover), and release dates and
  coming-soon state in `upcoming.json.gz`.
- **Exchange rates** in `upcoming.json.gz`: Source: ECB statistics (European Central Bank, reused unmodified).

Not affiliated with or endorsed by IGDB, Twitch, ProtonDB, Valve or Wikimedia.
