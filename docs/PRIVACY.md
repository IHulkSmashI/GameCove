# Network and privacy

GameCove has no analytics, no crash reporting, no telemetry and no GameCove account. It never sends device
serial numbers, Steam or store account ids, API keys to anyone but the service they belong to, or anything else
about you to the GameCove project. The README's "Network and privacy" table is the short version; this is every
call, where it lives in the code and what stops it. `app/scripts/system/privacy.gd` (`NETWORK_CALLS`) is the list
the app itself shows under Settings > About > Network and privacy.

## The switches

| Switch | Where | Default | Off means |
| --- | --- | --- | --- |
| Background lookups | Settings > About > Network and privacy (`user://settings.cfg` `[privacy] background`) | On | Nothing is requested on GameCove's own initiative: no deals refresh, no game-database or calendar download, no device-photo request (a cached picture still shows), no Steam insights on game pages (what's cached still shows). What you ask for right then (searching, opening a store page, pressing Check) still works. |
| Look up deals and prices | Same card, and Discover's settings (`price_lookups`) | On | No request to CheapShark, the Steam store API or GG.deals at all, background or not. Discover shows no prices. |
| Look up game details | Same card (`user://settings.cfg` `[privacy] metadata`) | On | No Steam store details, OpenCritic or SteamGridDB request at all, background or not. Game pages show what the store and GameCove's game database already have. |
| Show maker photos | Same card, and Settings > Device (`[device] maker_photo`) | On | Your handheld's picture is never requested from its maker's site; the free photo or our drawing is used. |
| Affiliate links | Settings > Discover | On | Store links GameCove builds carry no affiliate id. None are configured today. It only changes a link's address; prices are the same and nothing is sent. |

## Every outbound call

| # | Host | What is sent | Trigger | Gated by | Code |
| --- | --- | --- | --- | --- | --- |
| 1 | github.com (`gamedb/gamedb.json.gz`) | Nothing personal | Start, at most daily | Background lookups | `app/scripts/library/gamedb.gd` |
| 2 | github.com (`gamedb/upcoming.json.gz`) | Nothing personal | Deals refresh, at most daily | Background lookups | `app/scripts/discover/discover.gd` |
| 3 | www.cheapshark.com | Wishlist Steam app ids and titles; search text | 45 s after start, every 6 h; search; game page | Look up deals and prices (+ Background lookups for the timer) | `discover.gd`, `cheapshark.gd` |
| 4 | api.steampowered.com `IStoreBrowseService/GetItems` | Wishlist and top-deal app ids, store country | Same | Same | `steam_api.gd` |
| 5 | api.gg.deals | App ids, region, your API key (in the query, as GG.deals requires) | Same, only with a key | Same | `ggdeals.gd` |
| 6 | github.com (`device-photos` release) | The asset name, i.e. your device model | Start until cached, weekly manifest; About or the welcome page showing the picture | Background lookups (every request; a cached picture still shows) | `app/scripts/device/photo.gd` |
| 7 | Your maker's site (MSI, Lenovo, ASUS, OneXPlayer, AOKZOE, AYANEO, Acer, GPD, ...) | The image URL implies your model; your IP address | Same, when there's no free photo | Show maker photos, Background lookups | `photo.gd` |
| 8 | Steam's CDN (`*.steamstatic.com`, `*.akamaihd.net`), images.igdb.com (calendar pictures named in `upcoming.json.gz`), SteamGridDB's CDN; no other host (`IMAGE_HOSTS`) | The picture's address, which names the game | A Discover, calendar or wishlist tile shows a picture that isn't cached | None (pictures of what you're looking at); SteamGridDB lookups: Look up game details | `app/scripts/discover/art.gd` |
| 9 | www.steamgriddb.com, cdn*.steamgriddb.com | A Steam app id or title; your key, else GameCove's project key (bearer header, dropped on cross-host redirects) | Change artwork (when you open it); automatic fill for library games with no cover, hero or logo, one request every 1.5 s, each game and kind at most weekly; Discover art Steam has none of | Look up game details (+ Background lookups for the automatic fill) | `app/scripts/library/art/art_service.gd`, `sgdb.gd`, `art.gd` |
| 9a | store.steampowered.com `api/appdetails` | The Steam app id of a library game, or of a GOG / Epic / Amazon game's Steam edition (from the game database) | After a library scan, for games whose details or Metacritic score are missing, one request every 1.6 s, cached a week (`user://metadata/steam/`); at once for the game page you open | Look up game details (+ Background lookups for the background queue) | `app/scripts/library/meta/resolver.gd` |
| 9b | opencritic-api.p.rapidapi.com | A game's title (search, once per game), then its OpenCritic id; your own RapidAPI key in the `X-RapidAPI-Key` header (dropped on cross-host redirects) | Same as 9a, only if you added a key; at most 20 searches and 180 requests a day, stops for the day on HTTP 429; cached a week | Look up game details; remove the key (Settings > Discover > Keys) | `resolver.gd`, `opencritic.gd` |
| 9c | Steam CDN (`*.steamstatic.com`), images.igdb.com | A screenshot's address | When a game page shows its screenshots (cached in `user://metadata/shots/`) | Look up game details | `resolver.gd` (`image`) |
| 10 | api.steampowered.com achievements, Steam CDN icons | App id | Opening a game page | Settings > Performance | `app/scripts/achievements/` |
| 10a | api.steampowered.com `ISteamUserStats/GetNumberOfCurrentPlayers`, `IStoreBrowseService/GetItems` (reviews + Deck rating, asked with a fixed country `US`, not yours), `ISteamNews/GetNewsForApp` (`tags=patchnotes`); store.steampowered.com `api/appdetails` (DLC ids) | App id | Opening a Steam game's page: players at most every 10 min, the rest at most every 12 h per game (cached in `user://insights/`); a failed call waits 5 min | Background lookups | `app/scripts/steam/steam_insights.gd`, `insights_api.gd` |
| 10b | api.steampowered.com `IStoreBrowseService/GetItems`; CheapShark, GG.deals (rows 3 to 5) | DLC app ids and your store country, for local DLC prices; the game's current price and lowest ever go through Discover's own calls (rows 3 to 5) | Same page, at most every 6 h (the deals refresh) | Look up deals and prices | `steam_insights.gd` |
| — | steamdb.info | Nothing: GameCove never contacts SteamDB (it forbids scraping). The page shows a QR code with the game's SteamDB address for your phone. | — | — | `app/scripts/ui/games/insights_card.gd` |
| 11 | steamcommunity.com, `IWishlistService` | Your Steam profile name or SteamID64 | You import your wishlist | You start it | `discover.gd` |
| 12a | github.com (`upscalers/upscalers.json`, `.sigstore.json`; the upscaler files on `upscalers*` releases, then their upstream release) | Nothing personal | The list: at most daily, 90 s after start (background check), and before any upscaler install or update; files: only when you install or update | Background lookups (the daily check); installs and updates: you start them | `app/scripts/controls/providers/perf.gd`, `packaging/helpers/gamecove_upscale/mirror.py` |
| 12 | github.com (`firmware/firmware.json.gz`, `.sha256`, `.sigstore.json`) | Nothing | Checking for updates | You start it | `app/scripts/system/updates.gd` |
| 13 | The maker's own download site (allow-listed per maker, https only; at most 5 redirects, each ending on the maker's site; offered only when cosign on this device checked the list's signature) | Nothing | You prepare a USB drive | You start it | `updates.gd`, `firmware_index.gd` |
| 14 | LVFS, rpm-ostree / steamos-update, Flatpak, Flathub | Those tools' own | You update or install Moonlight | You start it | `updates.gd`, `app/scripts/streaming/` |
| 15 | PCs on your LAN (GameStream 47989 http, 47984 https pinned to the PC's certificate) | Fixed client id, Moonlight's client certificate | Stream tab | You start it | `app/scripts/streaming/host_api.gd` |
| 16 | LAN broadcast (Wake-on-LAN) | Your PC's MAC address | You wake a PC | You start it | `wol.gd` |
| 17 | 127.0.0.1 (Steam's CEF debugger; Handheld Daemon) | Local only | Opt-in Steam control; controller settings | — | `app/scripts/steam/`, `hhd_client.gd` |
| 18 | legendary.gl, auth.gog.com, Amazon | The sign-in code you type back | You sign in to a store | You start it | `app/scripts/library/stores/` |

Helpers and scripts outside the app: the upscaling helper downloads OptiScaler, OptiPatcher, fakenvapi,
REFramework, xess-xmx-linux and the FSR 4 files only when you install or update them: the newest versions from
GameCove's signed `upscalers.json` (row 12a; its signature is checked with the cosign the installer pins, which it
downloads once from sigstore's GitHub release if the system has none; cosign itself may refresh Sigstore's public
trust root from tuf-repo-cdn.sigstore.dev, sending nothing about you), else the tested pins in
`packaging/helpers/gamecove_upscale/data/versions.json`; each file from GameCove's own mirror first, then its upstream
release, always sha256 checked; the gyro fix downloads MSI's sensor firmware
from download.msi.com (size and sha256 pinned); the installer (`get-gamecove.sh`) downloads GameCove's own
release, checks its Sigstore signature and every file's sha256, and fetches a pinned cosign if the system has
none.

## Files GameCove writes for game details and art

- `user://metadata/` (Steam store answers, OpenCritic answers and daily quota, screenshots) and
  `user://art/picked/` (art you picked or the automatic fill found), `user://art/thumbs/` (artwork picker
  thumbnails).
- Steam's own art folder, `~/.local/share/Steam/userdata/<account>/config/grid`, **only** when you pick art for a
  Steam game in Change artwork with "Also change in Steam" on (the default): `<appid>p`, `<appid>_hero`,
  `<appid>_logo` images and `<appid>.json` (logo position). Every file replaced there is first copied to
  `user://art/steam_backup/<account>/` with a manifest; "Reset to default" removes ours and restores the originals.
  The automatic fill never writes there. Nothing about this leaves the device.
