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
| Sync cloud saves | Settings > Saves (`user://settings.cfg` `[privacy] cloud_saves`), and a switch per game on its page and in Settings > Saves (`user://saves.cfg`) | On | legendary and gogdl never sync saves, and GOG's remote config is never asked. Saves stay on the handheld. |
| Affiliate links | Settings > Discover | On | Store links GameCove builds carry no affiliate id. None are configured today. It only changes a link's address; prices are the same and nothing is sent. |

All switches are on by default. A settings file that can't be read never turns them on: the damaged copy is kept
as `<file>.bad` and Background lookups, Look up game details (`settings.cfg`) and Look up deals and prices
(Discover's `settings.json`) stay off until you set them again.

A switch counts from the moment you turn it off. Discover's refresh is several steps and many requests; each
request asks the switches again right before it goes out (`discover.gd` `may_fetch`), so the ones still waiting
are never sent.

Every request has a size limit (4 MB for an answer kept in memory unless it names a smaller one, 16 MB for the
calendar file, 64 MB for the game database, a few MB for a picture): a bigger answer is dropped, not read.

## Every outbound call

GameCove's own data files (rows 1, 2, 6, 12a and 12) are on the releases of
[IHulkSmashI/GameCove-data](https://github.com/IHulkSmashI/GameCove-data); github.com sends each download on to
GitHub's file host (`release-assets.githubusercontent.com` or `objects.githubusercontent.com`), as for any GitHub
release. The app's own releases (what `get-gamecove.sh` installs) stay on IHulkSmashI/GameCove.

| # | Host | What is sent | Trigger | Gated by | Code |
| --- | --- | --- | --- | --- | --- |
| 1 | github.com/IHulkSmashI/GameCove-data (`gamedb/gamedb.json.gz`) | Nothing personal | Start, at most daily | Background lookups | `app/scripts/library/gamedb.gd` |
| 2 | github.com/IHulkSmashI/GameCove-data (`gamedb/upcoming.json.gz`) | Nothing personal | Deals refresh, at most daily | Background lookups | `app/scripts/discover/discover.gd` |
| 3 | www.cheapshark.com | Wishlist Steam app ids and titles; search text; nothing for the free-to-keep list (`deals?onSale=1&upperPrice=0`, one more request per refresh) | 45 s after start, every 6 h; search; game page | Look up deals and prices (+ Background lookups for the timer) | `discover.gd`, `cheapshark.gd` |
| 4 | api.steampowered.com `IStoreBrowseService/GetItems` | Wishlist and top-deal app ids, store country | Same | Same | `steam_api.gd` |
| 5 | api.gg.deals | App ids, region, your API key (in the query, as GG.deals requires) | Same, only with a key | Same | `ggdeals.gd` |
| 6 | github.com/IHulkSmashI/GameCove-data (`device-photos` release) | The asset name, i.e. your device model | Start until cached, weekly manifest; About or the welcome page showing the picture | Background lookups (every request; a cached picture still shows) | `app/scripts/device/photo.gd` |
| 7 | Your maker's site (MSI, Lenovo, ASUS, OneXPlayer, AOKZOE, AYANEO, Acer, GPD, ...) | The image URL implies your model; your IP address | Same, when there's no free photo | Show maker photos, Background lookups | `photo.gd` |
| 8 | Steam's CDN (`*.steamstatic.com`, `*.akamaihd.net`), images.igdb.com (calendar pictures named in `upcoming.json.gz`), SteamGridDB's CDN; no other host (`IMAGE_HOSTS`), and that holds for every redirect on the way: each hop is checked before it's followed, https only (`http.gd` `hosts`) | The picture's address, which names the game | A Discover, calendar or wishlist tile shows a picture that isn't cached | None (pictures of what you're looking at); SteamGridDB lookups: Look up game details | `app/scripts/discover/art.gd` |
| 9 | www.steamgriddb.com, cdn*.steamgriddb.com | A Steam app id or title; your own key (bearer header, dropped on cross-host redirects) | Change artwork (when you open it); automatic fill for library games with no cover, hero or logo, one request every 1.5 s, each game and kind at most weekly; Discover art Steam has none of | Look up game details (+ Background lookups for the automatic fill) | `app/scripts/library/art/art_service.gd`, `sgdb.gd`, `art.gd` |
| 9a | store.steampowered.com `api/appdetails` | The Steam app id of a library game, or of a GOG / Epic / Amazon game's Steam edition (from the game database) | After a library scan, for games whose details or Metacritic score are missing, one request every 1.6 s, cached a week (`user://metadata/steam/`); at once for the game page you open | Look up game details (+ Background lookups for the background queue) | `app/scripts/library/meta/resolver.gd` |
| 9b | opencritic-api.p.rapidapi.com | A game's title (search, once per game), then its OpenCritic id; your own RapidAPI key in the `X-RapidAPI-Key` header (dropped on cross-host redirects) | Same as 9a, only if you added a key; at most 20 searches and 180 requests a day, stops for the day on HTTP 429; cached a week | Look up game details; remove the key (Settings > Discover > Keys) | `resolver.gd`, `opencritic.gd` |
| 9c | Steam CDN (`*.steamstatic.com`), images.igdb.com | A screenshot's address | When a game page shows its screenshots (cached in `user://metadata/shots/`) | Look up game details | `resolver.gd` (`image`) |
| 10 | api.steampowered.com achievements, Steam CDN icons | App id | Opening a game page | Settings > Performance | `app/scripts/achievements/` |
| 10a | api.steampowered.com `ISteamUserStats/GetNumberOfCurrentPlayers`, `IStoreBrowseService/GetItems` (reviews + Deck rating, asked with a fixed country `US`, not yours), `ISteamNews/GetNewsForApp` (`tags=patchnotes`); store.steampowered.com `api/appdetails` (DLC ids) | App id | Opening a Steam game's page: players at most every 10 min, the rest at most every 12 h per game (cached in `user://insights/`); a failed call waits 5 min | Background lookups | `app/scripts/steam/steam_insights.gd`, `insights_api.gd` |
| 10b | api.steampowered.com `IStoreBrowseService/GetItems`; CheapShark, GG.deals (rows 3 to 5) | DLC app ids and your store country, for local DLC prices; the game's current price and lowest ever go through Discover's own calls (rows 3 to 5) | Same page, at most every 6 h (the deals refresh) | Look up deals and prices | `steam_insights.gd` |
| — | steamdb.info | Nothing: GameCove never contacts SteamDB (it forbids scraping). The page shows a QR code with the game's SteamDB address for your phone. | — | — | `app/scripts/ui/games/insights_card.gd` |
| 11 | steamcommunity.com, `IWishlistService` | Your Steam profile name or SteamID64 | You import your wishlist | You start it | `discover.gd` |
| 12a | github.com/IHulkSmashI/GameCove-data (`upscalers/upscalers.json`, `.sigstore.json`; the upscaler files on `upscalers*` releases), then their upstream release | Nothing personal | The list: at most daily, 90 s after start (background check), and before any upscaler install or update; files: only when you install or update | Background lookups (the daily check); installs and updates: you start them | `app/scripts/controls/providers/perf.gd`, `packaging/helpers/gamecove_upscale/mirror.py` |
| 12c | github.com/IHulkSmashI/GameCove-data (`fixes/fixes.json`, `.sigstore.json`: the nightly list of device fixes, [FIXES.md](FIXES.md)) | Nothing personal: two plain downloads, the same for every handheld (not your model, not which fixes you use) | At most once a day, at start, never while a game runs. Used only when cosign verifies it on the device; otherwise the list built into GameCove stays | Background lookups | `app/scripts/device/fixes.gd`, `app/scripts/device/fix_data.gd`, `app/scripts/system/data_repo.gd` |
| 12b | api.github.com (`repos/GloriousEggroll/proton-ge-custom/releases/latest`), then github.com (that release's `GE-Proton*.tar.gz` and `.sha512sum`, only from GloriousEggroll's release page) | Nothing personal (curl's request with a `User-Agent: GameCove` header) | You press Check, then Install, in Settings > Performance > GE-Proton; never in the background | You start it | `app/scripts/launch/proton_ge.gd` |
| 12 | github.com/IHulkSmashI/GameCove-data (`firmware/firmware.json.gz`, `.sha256`, `.sigstore.json`) | Nothing | Checking for updates | You start it | `app/scripts/system/updates.gd` |
| 13 | The maker's own download site (allow-listed per maker, https only, redirects included; at most 5 redirects, and the address the download ends on must be on the maker's site (the hops in between are https but not host-checked); the file must match the sha256 in the signed list; offered only when cosign on this device checked the list's signature) | Nothing | You prepare a USB drive | You start it | `updates.gd`, `firmware_index.gd` |
| 14 | LVFS, rpm-ostree / steamos-update, Flatpak, Flathub | Those tools' own | You update or install Moonlight; Flatpak apps also at most daily (3 min after start or when a game ends, never while one runs, on AC or an unmetered network) if you turned on "Update apps by themselves" | You start it; the automatic app update is off by default and also needs Background lookups | `updates.gd`, `app/scripts/streaming/` |
| 14a | Whatever EmuDeck, RetroDECK, ES-DE and Steam ROM Manager contact (Steam ROM Manager: SteamGridDB, with its own settings) | Those tools' own requests | Only while you have them open: you open them from the Emulation page | You start it | `app/scripts/ui/emulation_page.gd` |
| 15 | PCs on your LAN (GameStream 47989 http, 47984 https pinned to the PC's certificate) | Fixed client id, Moonlight's client certificate | Stream tab | You start it | `app/scripts/streaming/host_api.gd` |
| 15a | Every address of your local IPv4 networks (each network from /22 to /30, so at most 1,022 addresses; larger networks are skipped), TCP port 47989 | A TCP connection attempt (no data), then a GameStream `serverinfo` request to each address that answers | Opening the Stream tab when no PC is saved and mDNS (avahi) finds none | You start it (opening the tab) | `app/scripts/streaming/streaming.gd` (`_probe_job`), `gamestream.gd` (`subnet_hosts`) |
| 16 | Wake-on-LAN: your LAN's broadcast addresses, and every address saved for that PC, which includes a remote (internet) address or host name if you added the PC by one; UDP ports 9, 47009 and five around the PC's GameStream port | The wake packet, which is your PC's MAC address | You wake a PC | You start it | `wol.gd` |
| 17 | 127.0.0.1 (Steam's CEF debugger; Handheld Daemon) | Local only | Opt-in Steam control; controller settings | — | `app/scripts/steam/`, `hhd_client.gd` |
| 18 | legendary.gl, auth.gog.com, Amazon | The sign-in code you type back | You sign in to a store | You start it | `app/scripts/library/stores/` |
| 18a | Epic (through legendary `sync-saves`), GOG cloud storage (through heroic-gogdl `save-sync`) | Your save files for that game and your store sign-in (legendary's / Heroic's own tokens; GameCove never reads them) | Just before an installed Epic or GOG game starts and just after it ends; Sync now on its page or in Settings > Saves; a conflict you settle. Never while a game runs | Sync cloud saves (also per game) | `app/scripts/system/saves_service.gd`, `cloud_saves.gd` |
| 18b | remote-config.gog.com (`components/galaxy_client/clients/<client id>`) | The game's GOG client id (from its `goggame-<id>.info`), nothing about you | Once per game, the first sync of a GOG game whose save folders Heroic doesn't list (games GameCove installed with gogdl); the answer is cached in `user://saves.cfg` | Sync cloud saves | `saves_service.gd` (`_gog_plan`) |
| 19 | www.steamgriddb.com (`games/steam/400`) | Your SteamGridDB key (bearer header), once | You send or type your key in the Game art step: one request checks it before it is saved | You start it (needs Look up game details) | `app/scripts/ui/setup/art_key_step.gd`, `sgdb.gd` (`check_url`) |
| 20 | Inbound, on your LAN only: your phone opens GameCove's one-time page | Your phone sends the key you paste; GameCove sends the page (no scripts, nothing from outside) | Only after you choose **Send from my phone** in the Game art step (showing the step opens nothing), until the key arrives, you leave the step or 10 minutes pass by the clock | You start it | `app/scripts/system/key_drop.gd` |
| 21 | Inbound, on your LAN only: your phone opens a clip's one-time page | GameCove sends the page and the one clip you picked; your phone sends nothing but its requests | Only while the Send to phone code shows: until the clip is downloaded in full, you close it, or 10 minutes pass | You start it | `app/scripts/system/clip_drop.gd` |
| 22 | Flathub (dl.flathub.org) through `flatpak install` | Flatpak's own requests | You press Install GPU Screen Recorder (system-wide) or Get a video player (mpv, for your user) in Settings > Media | You start it | `app/scripts/ui/settings/media_page.gd` |

`gamecove-selftest` (the check you run yourself from a terminal) asks GitHub once whether GameCove's releases page
answers: a `HEAD` request to `github.com/IHulkSmashI/gamecove/releases/latest`, with nothing about you or the
device in it, to tell you whether updates and downloads can work. `gamecove-selftest --no-network` skips it, and
nothing else in the selftest goes online. The installer script (`get-gamecove.sh`) asks `api.github.com` for this
repository's release list (or the one release you named with `--tag`) before it downloads anything.

Helpers and scripts outside the app: the upscaling helper downloads OptiScaler, OptiPatcher, fakenvapi,
REFramework, xess-xmx-linux and the FSR 4 files only when you install or update them: the newest versions from
GameCove's signed `upscalers.json` (row 12a; its signature is checked with the cosign the installer pins, which it
downloads once from sigstore's GitHub release if the system has none; cosign itself may refresh Sigstore's public
trust root from tuf-repo-cdn.sigstore.dev, sending nothing about you), else the tested pins in
`packaging/helpers/gamecove_upscale/data/versions.json`; each file from GameCove's own mirror (the data repo's `upscalers` release) first, then its upstream
release, always sha256 checked; the gyro fix downloads MSI's sensor firmware
from download.msi.com (size and sha256 pinned); the installer (`get-gamecove.sh`) downloads GameCove's own
release, checks its Sigstore signature and every file's sha256, and fetches a pinned cosign if the system has
none.

## Clips: the phone page

Send to phone (Settings > Media > a clip) works like the Game art page below, with the same rules
(`app/scripts/system/clip_drop.gd` reuses `key_drop.gd`'s address picking, token and request parsing): only while
the code shows, only on this device's private LAN address, a random port, a 128-bit one-time token in the address,
wrong requests throttled per device, silent connections closed after 3 s (a download that stops taking data
after 30 s) and the longest-idle one making room when all eight slots are taken, no scripts or outside
resources, `no-store` and `no-referrer`. It serves exactly one file,
read-only: the clip you picked. The page lets the phone watch it (byte ranges, so it can seek) and download it; the
first complete download closes the page, and so do closing the code or 10 minutes with nothing being sent. The clip
crosses your Wi-Fi once in plain HTTP and never leaves your network through GameCove.

Recording itself sends nothing anywhere: GPU Screen Recorder writes the file to `~/Videos/GameCove/`. Controller
batteries (UPower) and the Apps list (.desktop files) are read on the device only.

## Game art: the phone page (the other thing GameCove listens for)

GameCove doesn't ship a SteamGridDB key. The Game art step of setup (and of the installer, and Settings > Discover >
SteamGridDB key) walks you through getting your own, free, by signing in to SteamGridDB with Steam on your phone.
To get the 32-character key onto the handheld without typing it with a controller, the step serves a tiny web page
on your own network (`app/scripts/system/key_drop.gd`):

- It listens only after you choose **Send from my phone** (the step itself opens nothing: until then its QR code is
  SteamGridDB's own page), on this device's private LAN address (Wi-Fi first; never on every interface, never on a
  public address), on a random port. No LAN address, no page: the step offers typing or pasting the key instead.
- The address in the QR code carries a one-time token of 128 random bits. Any other address gets "Not found"; after
  30 wrong requests in a minute from one device, that device's new connections are closed unanswered until the
  minute is over. The count is per device and the page stays open, so someone else on the network can't close it
  on you or keep your phone out. A key sent from another web site (a foreign `Origin`) is refused.
- It closes as soon as one well-formed key arrives, when you leave the step, or after 10 minutes, whichever comes
  first. The 10 minutes run by the clock, so time the handheld spent asleep counts. A request must arrive within 10 s and be under 8 KiB; a connection that sends nothing for 3 s is closed, and
  when all eight slots are taken the longest-idle connection makes room.
- The page has no scripts, loads nothing from anywhere else, and is sent with `Cache-Control: no-store`,
  `Referrer-Policy: no-referrer` and a `Content-Security-Policy` of `default-src 'none'`.
- It is plain HTTP on your local network: the key crosses your Wi-Fi once, like a store sign-in code you'd type.
  It never leaves your network through GameCove except to SteamGridDB itself (row 19).

GameCove then checks the key with one SteamGridDB request and saves it only if SteamGridDB accepts it, in
`user://setup.cfg` and Discover's settings file, both readable by your user only (0600). After that it fills in the
art your games are missing (row 9).

## Collections and emulation: read on the device only

- Favourites, hidden games and your collections live in `user://collections.json`; play time for ES-DE, RetroDECK
  and emulated games in `user://playtime.json`. Neither leaves the device.
- Steam's collections, favourites and hidden games are **read** from
  `~/.local/share/Steam/userdata/<account>/config/cloudstorage/cloud-storage-namespace-1.json` (the account that
  signed in last) and Steam ROM Manager's games from `config/shortcuts.vdf` in the same folder. GameCove never writes
  either file.
- The Emulation page reads EmuDeck's `~/.config/EmuDeck/settings.sh`, RetroDECK's `retrodeck.cfg` /
  `retrodeck.json`, ES-DE's `es_settings.xml`, `es_systems.xml` and `gamelist.xml` files, and counts the files in the
  ROM folders (it doesn't open them). It never writes their files and never downloads or bundles games or BIOS files.
  Its EmuDeck QR code is drawn on the handheld; showing it contacts nothing.

## Files GameCove writes for cloud saves and battery history

- `user://saves.cfg`: per game, its sync switch, the last sync time, how it stands, gogdl's timestamps and the save
  folders they were made with, and a note while a download is replacing a save folder; GOG's remote-config answers
  per client id.
- `user://saves/backups/<game>/`: the local backups (`<time>-<n>.tar.gz` per save folder and `<time>.json` listing
  them), at most 10 everyday ones per game plus 10 made by a choice, a restore or a copy of the cloud. Taken before a
  cloud save replaces one on the handheld, before a restore, and of the cloud's copy before a GOG upload would delete
  files from it.
- `user://steam_libraries.json`: the Steam library folders seen on this handheld and the app ids each held, so Clean
  up never offers the shader caches of games on a card that isn't in. Never sent anywhere.
- `user://gamecove.pid`: the process id of the running home screen, so a second one steps aside.
- `user://battery_history.json`: battery level, energy and time at game starts and ends, sleep, wake and the
  charger (30 days, at most 3,000 entries), and the battery each game used. Nothing about this leaves the device.

## Files GameCove writes for game details and art

- `user://metadata/` (Steam store answers, OpenCritic answers and daily quota, screenshots) and
  `user://art/picked/` (art you picked or the automatic fill found), `user://art/thumbs/` (artwork picker
  thumbnails).
- Steam's own art folder, `~/.local/share/Steam/userdata/<account>/config/grid`, **only** when you pick art for a
  Steam game in Change artwork with "Also change in Steam" on (the default): `<appid>p`, `<appid>_hero`,
  `<appid>_logo` images and `<appid>.json` (logo position). Every file replaced there is first copied to
  `user://art/steam_backup/<account>/` with a manifest; "Reset to default" removes ours and restores the originals.
  The automatic fill never writes there. Nothing about this leaves the device.
