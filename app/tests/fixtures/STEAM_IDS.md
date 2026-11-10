# Steam ids in these fixtures are synthetic

No fixture holds a real person's Steam account. Every SteamID64 here is 76561197960265728 (the base for individual
accounts) plus a made-up account id:

| SteamID64 | Account id | Used for |
| --- | --- | --- |
| 76561197972611406 | 12345678 | the signed-in "player" (stores, library, Discover profile import) |
| 76561198047920049 | 87654321 | a second local account ("other"); a SteamGridDB artist in metadata fixtures |
| 76561197960266729, 76561197960267730 | 1001, 2002 | achievements fixtures |
| 76561198000000001, 76561198000000002 | 39734273, 39734274 | system fixtures; SteamGridDB artists in metadata fixtures |

`app/tests/test_steam_files.gd` (and packaging/tests/release.sh) check that no other SteamID64 appears.
