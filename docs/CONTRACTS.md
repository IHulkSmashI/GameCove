# Contracts

How the parts of GameCove talk to each other. Change a contract only with a matching change everywhere it's used.

## Services (Godot autoloads, `app/project.godot`)

| Autoload | File | Owner folder | What it does |
| --- | --- | --- | --- |
| `Device` | `scripts/device/device.gd` | `scripts/device/` | Which handheld this is (row of `data/devices.json`), its buttons, glyphs and picture, live battery and watts, "About this device" info |
| `DevicePhoto` | `scripts/device/photo.gd` | `scripts/device/` | Real, freely licensed photo of this handheld from the `device-photos` release, cached in `user://device_photos/` (see [DEVICES.md](DEVICES.md#real-photos)) |
| `Power` | `scripts/device/power.gd` | `scripts/device/` | TDP, profiles, fan, charge limit via PowerStation / steamos-manager over D-Bus |
| `Library` | `scripts/library/library.gd` | `scripts/library/`, `scripts/steam/` | All stores in one list, game info from the game database, launching, store management (install, update, downloads, compatibility tool) |
| `Launcher` | `scripts/launch/launcher.gd` | `scripts/launch/` | Per-game settings and the launch environment (upscaler, frame gen, latency, Proton) |
| `Gamescope` | `scripts/gamescope/gamescope.gd` | `scripts/gamescope/` | Frame limit, refresh rate, overlay focus |
| `Discover` | `scripts/discover/discover.gd` | `scripts/discover/` | Deals, prices across stores, wishlist and alerts, release calendar |
| `Art` | `scripts/discover/art.gd` | `scripts/discover/` | Cover / hero / logo / header images for any game, cached in `user://art/` |
| `PerfMonitor` | `scripts/perf/perf_monitor.gd` | `scripts/perf/` | Running game's fps, frame time, power, load, temps; feeds Auto TDP; performance overlay level |
| `Achievements` | `scripts/achievements/achievements.gd` | `scripts/achievements/` | Steam achievements from the client's local cache, global rarity |
| `Updates` | `scripts/system/updates.gd` | `scripts/system/` | OS image, firmware (fwupd) and Flatpak updates |
| `Storage` | `scripts/system/storage.gd` | `scripts/system/` | Drives, free space, game library folders, hot-plug while the page is open |
| `Setup` | `scripts/system/setup.gd` | `scripts/system/` | First-run checklist, store sign-in, suggested device fixes |
| `Controller` | `scripts/input/controller.gd` | `scripts/input/` | InputPlumber or Handheld Daemon: paddles, gyro, rumble, RGB (hhd), per-game profiles (not named `Input`: that would hide Godot's `Input`) |

The UI (`scenes/`, `scripts/ui/`, `scripts/main.gd`, `theme/`) only calls these services; it never touches sysfs, D-Bus or store tools directly.

## Game (every entry in `Library.games`)

```
{
  "key": "steam:976730",          # "<store>:<id>", unique
  "store": "steam",               # steam | epic | gog | amazon
  "id": "976730",
  "title": "Halo: The Master Chief Collection",
  "installed": true,
  "art": {"cover": "", "hero": "", "logo": "", "icon": ""},   # local file paths or ""
  "info": {
    "released": 2014,             # int or null
    "time_to_beat": {"main_h": 10.0, "extra_h": 20.0, "complete_h": null, "count": 17, "source": "igdb"} or null,
    "anticheat": {"status": "works|blocked|denied|unknown", "anticheats": ["Easy Anti-Cheat"]} or null,
    "protondb": "platinum|gold|silver|bronze|borked" or null
  },
  "last_played": 0,               # unix seconds
  "playtime_min": 0
}
```

`Library` emits `changed` after every refresh. `Library.launch(game)` starts it through the right store and returns `{"ok": bool, "app_id": int, "pid": int, "scoped": bool}`: `app_id` is the id gamescope knows the game by (the Steam app id, or `Library.app_id_for(key)` for a game we start in an `app-steam-app<id>-<n>` scope; 0 when gamescope can't tell), `pid` the process we started (0 for Steam).

`Library.launch(game, options := {})`: `options.args` adds arguments for this launch only (Steam: through Steam control or `steam://run/<id>//<args>/`).

## Store management (`Library`, details in [STORES.md](STORES.md))

Every action returns at once with `{"ok": bool, "via": String, "why": String}` (`via`: `steam-cef | steam-uri | steam-files | steam-files-after-restart | legendary | gogdl | nile | gamecove | heroic | queue | umu`; `why` is a short line to show when `ok` is false). What happens next arrives as signals. Process work runs off the main thread; nothing polls while idle.

| Call | Notes |
| --- | --- |
| `capabilities(game) -> Dictionary` | `{"install", "uninstall", "update", "verify", "move", "launch_options", "compat_tool", "progress", "pause", "resume", "cancel": bool, "how": {cap: via}, "why": {cap: reason}, "needs_window": [caps that open a Steam/Heroic window]}`. Hide or explain anything false |
| `install(game, options := {})` | `options.path`: a folder from `install_locations()` (default `<install_root>/<store>`; Steam: a Steam library folder, default Steam's). `options.platform`: `windows`/`linux` (GOG) |
| `uninstall(game)`, `update(game)`, `verify(game)` | verify = verify and repair |
| `move(game, path)` | Into folder `path`; the game keeps its folder name |
| `pause(game)`, `resume(game)`, `cancel(game)`, `reorder_download(game, delta) -> bool` | |
| `downloads() -> Array[Dictionary]` | `[{"key", "action", "title", "state": queued\|running\|paused, "progress": {"bytes_done", "bytes_total", "rate", "eta", "percent", "unit": bytes\|files, "phase"}, "error", "size"}]` in queue order, Steam jobs last |
| `launch_options(game) -> String`, `set_launch_options(game, s)` | Steam: Steam's launch options (`pending: true` in the result when it waits for Steam to stop). Others: extra game arguments. Steam files are written on a thread; a failed write comes back as `action_failed(key, "launch_options"/"compat_tool", why)` |
| `launch_options_async(game, done)`, `compat_tool_async(game, done)`, `compat_tools_async(game, done)` | Same values, read off the main thread (localconfig.vdf, config.vdf, appmanifest scans); `done(value)` on the main thread. The UI uses these |
| `compat_tool(game) -> String`, `set_compat_tool(game, tool_id)`, `compat_tools(game := {}) -> Array[Dictionary]` | `[{"id", "name", "path"}]`, default (`""`) first. Steam game: Steam's internal names; otherwise umu's PROTONPATH choices |
| `install_locations() -> Array[Dictionary]` | `[{"path", "label", "free", "removable"}]`, internal first, then SD cards / USB under `/run/media` |
| `store_settings() -> Dictionary`, `set_store_setting(name, value) -> bool` | `install_root` (absolute path), `steam_cef` (bool, opt-in Steam control; see security notes in STORES.md), `auto_resume`, `max_parallel` (1–4), `focus_steam_dialogs`; read-only `steam_cef_status` (`off\|flag_missing\|connecting\|ready\|unreachable`), `steam_pending_count` |
| `apply_pending_steam_changes(restart := false)` | Writes Steam settings that waited; `restart` stops and restarts Steam to do it |
| `open_steam_page(game, page)` | `store \| properties \| details \| downloads` |
| `return_from_steam()` | Gives the screen back after a Steam dialog we brought forward (also automatic once Steam starts the job) |

| Signal | When |
| --- | --- |
| `download_progress(key, bytes_done: int, bytes_total: int, rate: float, eta: int)` | bytes/s, seconds; `bytes_total` 0 and `eta` -1 when unknown |
| `install_state_changed(key, state)` | `queued, installing, updating, verifying, moving, uninstalling, downloading, paused, installed, not_installed, update_required, failed` |
| `queue_changed` | Call `downloads()` again |
| `action_failed(key, action, message)` | `message` is shown as is |
| `external_window_needed(key, app, reason)` | `app` `steam` or `heroic`; `reason` `install \| uninstall \| page \| manage` |
| `store_settings_changed` | |

The Library rescans the affected store after a change (`refresh_store(store)`) and emits `changed`. Tests and screens can swap the worker: `Library.attach_store(fake)` with the same methods and signals as `scripts/library/manage/store_manager.gd`.

## Discover (`Discover` autoload, `scripts/discover/`)

Free sources only, no API keys shipped (terms in CREDITS.md): CheapShark (which stores have a game on sale, links, US prices, US historical lows), Steam's keyless store and wishlist endpoints (prices for the user's country, sale end, release state, art), and `upcoming.json.gz` from the nightly job (calendar). Everything is cached in `user://discover/` and works offline. Signals are emitted on the main thread.

**Every number shown is a store's real price for the user's country. Nothing is converted.** Steam rows carry Steam's own price for that country. CheapShark's prices are US prices, so other stores get a number only when the country is US; elsewhere their rows have `"price": null` and the UI shows the store, the discount and a "See price" button that opens the deal's link. GOG and Epic have no usable local-price source (see CREDITS.md), so they're "See price" rows outside the US too.

**GG.deals (optional, the user's own free key in `settings.ggdeals_key`):** for games with a Steam app id, GG.deals gives the best current official-store price and the historical low in the user's region and currency (regions au be br ca ch de dk es eu fi fr gb ie it nl no pl se us; other countries get none). It appears as its own row in `prices_for()` / wishlist `best_deal`, and as a `ggdeals` block on top deals. GG.deals rows open GG.deals' URL unchanged and carry `attribution`; **the UI must show every `attribution` (text + active link) on any screen showing that data**, and `Discover.attributions()` lists the credits for the whole Discover area. Key-shop prices only with `settings.ggdeals_keyshops` (off by default; explain with `SETTINGS_INFO.ggdeals_keyshops.help`). Batches of ≤100 ids, one request per refresh, cached 6 h (GG.deals allows 100 ids/min, 1,000/hour per key).

**Country:** `settings.country` if set, else detected (`region.gd`): a store-country key in Steam's local files (`config/config.vdf`, `registry.vdf`, `config/loginusers.vdf`, `userdata/<id>/config/localconfig.vdf`; keys `StoreCountry`, `IPCountry`, `WalletCountry`, `CountryCode`, `Country`, `SteamCountry` with a two-letter value; best effort, Valve documents none), then the time zone (`/etc/localtime` → `America/Toronto` → `CA` via tzdata's zone.tab), then the locale (`en_CA.UTF-8`), then `US`. The currency always follows the country (Steam's currency for it).

### Signals

| Signal | When |
| --- | --- |
| `deals_changed` | `deals` replaced (after a refresh, a wishlist change, a settings change) |
| `calendar_changed` | a new calendar file was loaded |
| `wishlist_changed` | items added/removed/edited, or new prices for them |
| `settings_changed` | `set_settings()` |
| `prices_ready(game_key, deals: Array)` | answer to `request_prices()` |
| `search_done(query, results: Array)` | answer to `search()` |
| `import_done(ok: bool, added: int, error: String)` | answer to `import_steam_wishlist()`; `error` is a user-facing sentence ("" when fine; set with `ok` true for an empty/private wishlist) |
| `price_alert(item, deal)` | a wishlist item hit its target or went on sale (once per event) |
| `release_alert(item)` | a "notify me" game came out (once) |
| `status_changed(source, status)` | `source` `cheapshark` \| `steam` \| `ggdeals` \| `calendar` \| `wishlist_import`; `ggdeals` also has `error: key not accepted`; `status` `ok` \| `offline` \| `rate_limited` \| `missing` (calendar file not published yet) \| `error: <why>` |

### Properties

- `deals: Array[Dictionary]` — top current deals (Deal shape), CheapShark's "deal rating" order.
- `wishlist: Array[Dictionary]` — wishlist items with live fields, newest first (computed on read).
- `calendar: Array[Dictionary]` — Release dicts in calendar order; `days_until` computed for today on read.
- `status: Dictionary` — last status per source (as in `status_changed`).
- `alerts_inbox: Array[Dictionary]` — fired alerts not yet marked seen, newest first: `{"id", "kind": "price"|"release", "key", "title", "at", "amount"?, "currency"?, "target_price"?}`.
- `game_running: bool` — set true while a game has focus; no background refresh then (same as `pause()`).

### Methods

| Method | Does |
| --- | --- |
| `refresh(force := false) -> bool` | Deals + wishlist prices if 6 h old, calendar file if 24 h old; `force` ignores ages and pause. False when nothing started (busy, paused, not due). A background timer calls `refresh()` 45 s after start-up, then every 15 min (it only fetches when due). At most ~10 requests. |
| `pause()` / `resume()` / `is_paused()` | No background refresh while paused; one that came due runs on resume. |
| `search(title)` | CheapShark title search (+ one Steam call for regional prices) → `search_done`. Result: `{"key", "title", "ids", "art", "best_deal": Deal or {}, "on_wishlist", "release": Release or {}}`. |
| `prices_for(game) -> Array[Deal]` | Every store's price from cache, cheapest first in the user's currency (unconvertible last). `game`: Steam appid (int/String), title, Library game, wishlist item, Release, Deal or `{"ids", "title"}`. |
| `request_prices(game)` | Fetches them (≤3 requests, works while paused) → `prices_ready(key, deals)`. |
| `deal_for_appid(appid) -> Deal or {}` / `deal_for_title(title)` | Best known deal (wishlist prices, then top deals); cheap, for sale badges on library tiles. |
| `add_to_wishlist(game: Dictionary) -> String` | Adds (Release, Deal, search result, Library game or `{"title", "appid"/"ids"}`); returns the key; existing items keep their settings. |
| `remove_from_wishlist(key)` | |
| `set_target_price(key, price_or_null)` | In the user's currency; null = alert on any sale. |
| `set_notify(key, price = null, release = null)` | Turn price / release alerts on/off (null leaves as is). |
| `notify_me(release) -> String` | "Notify me" on a calendar entry: wishlist + release alert (a game already out doesn't alert). |
| `is_wishlisted(game) -> bool`, `get_item(key) -> Dictionary` | |
| `import_steam_wishlist(profile := "")` | 64-bit id, `steamcommunity.com/profiles/<id>`, `steamcommunity.com/id/<name>` or a bare custom name (resolved through the public profile XML); "" uses `settings.steam_id`. Needs the profile's "Game details" set to public. Merges, keeps existing settings, remembers the profile in settings. |
| `check_alerts()` | Runs the alert rules on cached data (also run after each refresh). |
| `mark_seen(id := "")` | Drops an alert from `alerts_inbox` ("" = all). Alerts themselves fire once regardless. |
| `get_settings() -> Dictionary` / `set_settings(patch)` | `{"country": "" (= detected) or "CA", "steam_id", "steamgriddb_key", "ggdeals_key", "ggdeals_keyshops": false, "alerts": true, "affiliate_links": true}`; `Discover.SETTINGS_INFO[key]` = `{"label", "help", "setup": bool}` for the Settings screen and first-run setup (country, Steam profile and "gg.deals key (optional) for real local prices from every store" are setup steps); `get_settings()` adds `country_effective`, `country_source` (`settings` \| `steam` \| `timezone` \| `locale` \| `default`) and `currency_effective`. |
| `country()`, `country_source()`, `user_currency()` | Resolved values. |
| `attributions() -> Array` | `[{"text", "url"}]` credits to show (linked) wherever Discover prices appear; includes GG.deals while its data is in use. |
| `calendar_info() -> Dictionary` | `{"built", "sources", "credits"}` of the calendar file, `{}` before the first download. |
| `open_link(link) -> bool`, `Discover.link_command(link, steam_bin) -> Array` | Opens a Deal's/Release's `link` (below). |

### Deal

```
{
  "key": "cheapshark:<dealID>" | "steam:<appid>",
  "source": "cheapshark" | "steam",       # whose data this row is
  "store": "steam" | "cs:<storeID>", "store_name": "GreenManGaming", "store_icon": url or "",
  "title": "Borderlands 2", "appid": "49520" or "", "game_id": "<CheapShark gameID>" or "",
  "price": {                              # null = no local price: show store + discount + "See price"
    "amount": 2.19, "regular": 21.99,     # the store's own price for `country`
    "currency": "CAD", "country": "CA",
    "source": "steam" | "cheapshark",     # cheapshark only when country is US
    "is_local": true,                     # always true; no estimates exist
    "text": "C$ 2.19", "regular_text": "C$ 21.99"   # Steam's own labels, or ours
  } or null,
  "see_price": bool,                      # price == null
  "savings_pct": 90, "on_sale": true,     # shown for See-price rows too
  "is_historical_low": bool,              # only when the low is in the user's currency (CheapShark: US only)
  "historical_low": {"amount": 1.99, "currency": "USD", "date": unix} or null,
  "sale_ends_at": unix or null,           # Steam only
  "rating": 9.4 or null,                  # CheapShark deal rating 0-10
  "art": {"cover": url, "hero": url, "header": url, "thumb": url},   # URLs; Art caches them
  "link": {"kind": "steam" | "url", "uri": ..., "affiliate": false, "note": ""},   # see Affiliate links
  "attribution": {"text": "Prices by GG.deals", "url": "https://gg.deals/"} or null,  # render it, linked
  "keyshop": false, "keyshop_note"?: "...",  # true only on GG.deals key-shop rows
  "ggdeals": {"price": price block, "historical_low", "url", "attribution", "keyshop": price block or null} or null,
  "on_wishlist": bool, "wishlist_key": "steam:49520"
}
```

`source` can also be `"ggdeals"` (`store` `"ggdeals"` / `"ggdeals-keyshops"`, link = GG.deals' URL, unchanged).

Rows from CheapShark data always link to CheapShark's redirect URL (their terms), even for Steam; a CheapShark Steam row shows Steam's price for the user's country when known but keeps that link. Rows from Steam's own data (`source` "steam") link to `steam://store/<appid>`; in `prices_for()` such a row replaces CheapShark's Steam row. `prices_for()` lists rows with a price first (cheapest first), then See-price rows by discount. `best_deal`, `deal_for_appid()` and `deal_for_title()` only return rows with a price (`{}` otherwise).

### Wishlist item (`Discover.wishlist`, `get_item()`)

```
{
  "key": "steam:<appid>" | "title:<normalised title>",
  "title", "ids": {"steam"?, "cheapshark"?, "igdb"?, "wikidata"?, ...},
  "added": unix, "source": "manual" | "steam" | "calendar",
  "target_price": float or null,          # user's currency; null = any sale
  "notify_price": bool, "notify_release": bool,
  "last_price": float or null,            # best local price amount at the last refresh
  "art": {"cover", "hero", "header"},
  # live, computed on read:
  "best_deal": Deal or {}, "historical_low": {...} or null,
  "savings_pct": int, "on_sale": bool, "is_historical_low": bool, "sale_ends_at": unix or null,
  "release": {"released": bool, "date", "precision", "days_until", "date_unix"} or {},
  "on_wishlist": true
}
```

Alert rules (`alerts.gd`): with a target (in the user's currency), fires when the best local `price.amount` is at or below it and lower than the last alerted price; without one, when the best deal is on sale and lower than the last alerted price. The memory clears when the price goes back above the target / the sale ends, so the next drop alerts again. Release alerts fire once when Steam says the game is out or its day-precision date arrives. Never with `settings.alerts` false; See-price rows never alert.

### Release (`Discover.calendar`)

```
{
  "key": "steam:<appid>" | "title:<normalised>",
  "title": "Football Manager 27",
  "date": "2026-11-10" | "2026-12" | "2027-Q1" | "2027" | "",
  "precision": "day" | "month" | "quarter" | "year" | "tba",
  "date_unix": unix (first day of the period, UTC) or null,
  "days_until": int (day precision only; 0 today, negative once out) or null,
  "released": bool,                       # whole period in the past ("Out now")
  "ids": {"steam"?, "igdb"?, "wikidata"?, "gog"?, "epic"?},
  "art": {"cover": url or "", "hero": url or "", "header": url or ""},
  "link": {"kind": "steam", "uri": "steam://store/<appid>"} | {"kind": "url", "uri": "https://www.wikidata.org/wiki/Q..."} | {},
  "sources": ["steam", "igdb", "wikidata"], "on_wishlist": bool
}
```

Order: by the last day a date can mean (so "December 2026" follows every known December day), finer precision first on ties, TBA last. Entries out for more than 14 days are dropped.

`upcoming.json.gz` (rolling `gamedb` release, built by `gamedb/gamedb/upcoming.py`): `{"schema": 1, "built", "sources", "credits", "fx": {...ECB rates, not used for any displayed price}, "count", "releases": [{"title", "date", "precision", "ids", "art", "sources"}]}` (null fields omitted). The app downloads it at most daily; a 404 (not published yet) gives status `missing` and an empty calendar, a broken file keeps the old copy.

### Affiliate links

`res://data/affiliates.json` maps a store to `{"template", "id"}`; all empty today, so nothing changes. `affiliates.gd` applies them only to store links GameCove builds itself (today: Epic store pages for calendar entries with an Epic id and no Steam id), never to Steam, CheapShark or GG.deals links. A link with an affiliate id has `"affiliate": true, "note": "Supports GameCove"`; show the note small next to the button. `settings.affiliate_links` false turns them off. How to add an id: docs/AFFILIATES.md.

### Opening links

`link.kind == "steam"`: `steam steam://store/<appid>` (the running client shows the store page). `kind == "url"`: `steam steam://openurl/<url>` (Steam's built-in browser; the session has no desktop browser). Without `steam` on PATH: `xdg-open <url>`. Only `https://` and `steam://` URIs are opened. Use `Discover.open_link(deal["link"])`.

### Art (`Art` autoload)

- `request(key, kind, hints := {}) -> String`: cached path at once (and marks it used), or "" and a background download that ends in `art_ready(key, kind, path)` (`path` "" = nothing found; not retried for a day). `kind`: `cover` (600x900), `hero`, `logo`, `header`. `key`: any stable id, e.g. a Library key `"steam:976730"` / `"epic:Fortnite"` or a Discover key; `"steam:<appid>"` supplies the appid. `hints`: `{"appid", "url", "title"}`.
- Order: `hints.url` → a URL `remember(key, {"cover": url, ...})`ed from Steam store data (Discover does this; newer Steam apps keep art under hashed paths only the store data knows) → Steam CDN by appid → SteamGridDB with the user's own key (`settings.steamgriddb_key`), by Steam id or by title.
- `path_for(key, kind) -> String` (cache only), `cleanup()`, `total_bytes()`. Files are checked to be JPEG/PNG/WebP (≤ 8 MB); the cache is capped at `max_bytes` (256 MB) and trimmed to 80% by least recent use.

### Testing and previews

`scripts/discover/fake_http.gd` has the same `request(url, opts, done)` interface as the real `http.gd`, answers synchronously from files by URL prefix and records requests. Set `Discover.http` / `Art.http` to one, `data_dir` / `cache_dir` to a temp folder and `clock` to a fixed time; call `Discover.load_all()`. Under the test runner both autoloads stay idle (no timers, no network). Fixtures: `app/tests/fixtures/discover/` (real responses captured 2026-11-08); `helpers.gd` there wires everything.

## Running game (`scripts/launch/game_session.gd`, owned by `main.gd`)

`GameSession.begin(game, Library.launch(game))` applies the game's `fps_limit` through `Gamescope`, starts Auto TDP when `Launcher.auto_tdp_for(key)` (goal `battery` or `balanced`), waits for the app id in `GAMESCOPE_FOCUSABLE_APPS` (0.5 s timer, up to 60 s) and calls `Gamescope.focus_app(id)`. A 3 s timer runs only while the game does; when its app id and process are gone it calls `focus_home()`, sets the frame limit to 0, stops Auto TDP and emits `ended(game)`.

## Device (`Device`, `scripts/device/device.gd`) and `devices.json`

`Device.profile` is this handheld's row of `data/devices.json` (field reference and matching rules: [DEVICES.md](DEVICES.md)). On hardware no row matches it is a generic row built from the CPU, with `id: "unknown"`, `tier: "generic"`, `support: "generic"`; it is never `{}` after `detect()`.

Fields other services read (all rows have them):

| Field | Type | Used by |
| --- | --- | --- |
| `id`, `name`, `maker`, `support` (`full`/`partial`/`beta`/`generic`), `verified` (bool), `unverified` (field names) | String / bool / Array | UI device page |
| `chip`, `gpu`, `gpu_family` (`amd-vega`, `amd-rdna2`, `amd-rdna3`, `intel-xe-lpg`, `intel-xe2`, `intel-xe3`, or `""`), `gpu_arch` (`RDNA2`, `RDNA3`, `RDNA3.5`, `Xe-LPG`, `Xe2`, `Xe3`, `Vega`, `unknown`), `xmx` | String / bool | Launcher (upscaler, FSR 4, XeSS) |
| `tdp` `{min, battery_max, plugged_max, boost_max?}`, `profiles`, `pl2_offset_w`, `tdp_backends` | Dictionary / Array | Power |
| `fan` (driver or null), `fan_via` (`steamos-manager`/`fix`/null), `charge_limit` (bool), `charge_limit_via` | | Power |
| `panel` `{size_in, resolution, type}` or null, `panel_hz` `[min, max]` (empty on unknown hardware), `vrr_range` `[lo, hi]` or null | | UI screen section, Gamescope |
| `gyro` (`yes`/`fix`/`no`/`none`/`unknown`), `imu`, `rgb` (`{zones, via}` or null) | | UI controller section |
| `buttons` (profile in buttons.gd), `glyphs` (`xbox`/`deck`), `art` | String | Input, UI |
| `fixes`, `quirks`, `sources` | Array | UI device page |

Methods: `id()`, `display_name()`, `maker()`, `chip()`, `support_level()`, `is_verified()`, `features()` → `{tdp, fan, fan_control, charge_limit, gyro, rgb, rgb_via, vrr, buttons, paddles, trackpads, glyphs}`, `buttons()` → special buttons (below), `glyph_set()`, `glyph_for(name)`, `picture()`, static `picture_for(device_id)` → `res://assets/devices/art/<art>.svg` (generic picture for unknown ids), `battery()`, `info()`, `request_slow_info()` + signal `info_updated(info)`.

### Buttons (`scripts/device/buttons.gd`, static, no autoload)

Button names are InputPlumber capability names (`South`, `Guide`, `QuickAccess`, `QuickAccess2`, `Keyboard`, `Screenshot`, `LeftPaddle1`…). GameCove actions: `home`, `quick_menu`, `osk`, `screenshot`, plus navigation `accept`, `back`, `option`, `context`, `menu`, `view`, `tab_left`, `tab_right`, `page_left`, `page_right`. `device` below is a device id, a devices.json row or a profile id.

| Call | Returns |
| --- | --- |
| `special_buttons(device)` | `[{id, label, capability, press: short/long/combo, glyph: res:// path, action}]` |
| `paddles(device)` | `{capability: printed label}`, e.g. `{"LeftPaddle1": "L4"}` |
| `action_map(device)` | `{capability: action}` for specials that trigger a GameCove action |
| `action_for(device, capability)`, `action_for_dbus(device, "ui_guide")` | action or `""` (pass through to Steam / the game) |
| `buttons_for(device, action)` | capabilities that trigger it; `[]` → offer `FALLBACK_CHORDS[action]` |
| `glyph_for(action_or_button, device)` | `res://assets/devices/glyphs/<set>/<name>.svg`, never empty |
| `label_for(device, button)` | printed name: `"Armoury Crate"`, `"L4"`, `"LB"`, `"R1"` |
| `glyph_set(device)`, `capabilities(device)`, `profile_id(device)` | |

How the Input service gets these buttons from InputPlumber inside gamescope: [DEVICES.md, "What the Input service must do"](DEVICES.md#what-the-input-service-must-do).

### Device info (`Device.info()`)

Grouped for an "About this device" panel. Cheap: reads files under `/sys`, `/proc`, `/etc` only. Unknown values are `""`, `-1`, `[]` or `{}`. `request_slow_info()` runs the slow lookups (Steam build, Proton list, free space, `vulkaninfo --summary` when installed) on a thread, caches them and emits `info_updated(info())`; later `info()` calls include them.

```
{
  "device":  {"id", "name", "maker", "model" (DMI product_name), "board", "vendor", "family",
              "bios_version", "bios_date", "serial": "hidden", "picture": "res://…svg"},
  "chip":    {"cpu", "cores": int, "threads": int, "gpu", "gpu_arch", "gpu_driver": "amdgpu|xe|i915",
              "gpu_pci_id": "1002:15BF", "mesa": "Mesa 25.1.3" or "", "kernel",
              "vulkan_driver"?: "radv"   # after slow info},
  "memory":  {"total_mb": int, "vram_mb": int, "gtt_mb": int},
  "storage": {"internal": {"name", "model", "size_gb": float, "free_gb"?: float} or {},
              "sd_card":  {"name", "model", "size_gb", "free_gb"?} or {}},
  "screen":  {"size_in": float, "resolution": [w, h], "type": "IPS|OLED", "refresh_hz": [min, max],
              "vrr": bool, "vrr_range": [lo, hi] or []},
  "battery": {"present": bool, "percent": int, "status", "charging": bool, "design_wh": float,
              "full_wh": float, "health_pct": int, "cycles": int, "charge_limit_supported": bool,
              "model", "manufacturer", "technology"},
  "software":{"os", "os_version", "os_id", "gamecove_version", "steam_version", "proton": [String]},
  "support": {"level", "verified": bool, "unverified": [String], "features": {…features()},
              "fixes": [String], "quirks": [String], "sources": [String], "buttons": profile id, "glyphs": set}
}
```

## Device photo (`DevicePhoto`, `scripts/device/photo.gd`)

- `photo_for(device_id) -> {} | {"path": abs path, "credit": {"author", "license", "license_url", "page_url", "file"}}`: never blocks; a miss starts a one-time background download of this device's photo only. `{}` means show the drawing.
- `cached(device_id)`: same, never touches the network. `signal photo_ready(device_id, path)`.
- `enabled` / `set_enabled(on)`: "Show a real photo of my device" (`[device] real_photo` in `user://settings.cfg`, default on).
- `credit_line(credit) -> "Photo: <author>, <license>"`. Tests: set `http` to `scripts/discover/fake_http.gd`, `cache_dir` and `prefs_path` to temp paths.

## Power state (`Power.state()`)

```
{
  "backend": "powerstation|steamos-manager|hhd|none",
  "tdp_w": 17.0, "tdp_min": 8.0, "tdp_max": 35.0,
  "profile": "balanced", "profiles": ["battery", "balanced", "performance"],
  "charge_limit": 80,             # percent, -1 if unknown
  "fan_mode": "auto", "fan_modes": ["quiet", "auto", "max"],
  "plugged": false,               # on the charger
  "supported": {"tdp": true, "profiles": true, "charge_limit": true, "fan": false}
}
```

More signals (main thread): `source_changed(plugged)` (charger in/out), `battery_level(percent, plugged)` (from the 15 s charger check, only when the level changes), `resumed()` (after `request_resumed()`, which main.gd calls when it sees the device slept; the TDP is already put back. A plain `refresh()` / `request_refresh()` never emits it). `Power.run_sync(job)` runs a Callable on Power's worker and waits (the power.* controls use it). Auto TDP: `request_autotune(on, game_key)`, `request_autotune_pause(reason)`, `set_autotune_option(key, value)` (`target`, `auto_fps`, `keep_pct`, `floor_w`, `plugged`), `autotune_status()`. `request_feed(fps, watts, sample)` takes PerfMonitor's whole reading as the third argument. The full list of power controls: [CONTROLS.md](CONTROLS.md#power-providerspowergd-scriptscontrolspower).

Setters (`set_tdp`, `set_profile`, `set_charge_limit`, `set_fan_mode`) return `true` only after reading the value back. `hhd`: Handheld Daemon's TDP plugin is on (`hhd.settings.tdp_enable`), so the TDP goes through its HTTP API (`scripts/input/hhd.gd`, driver path `tdp.asus.tdp_v2` / `tdp.lenovo.tdp` / `tdp.msi.tdp` switched to `custom`, or `tdp.qam.tdp`) and fan and charge limit are hhd's (`supported` false), so nothing fights it. Everything Power remembers in `user://power.cfg` is per device: sections `profile@<device id>`, `custom_w@<device id>`, `device@<device id>`; plain `[profile]` / `[custom_w]` / `[device]` (from older versions, or first-run setup) move to the device that reads them. `changed(state)` fires after any change. The UI hides any control whose `supported` flag is false.

## Auto TDP feed and "can't reach target" (`Power`)

- `Power.request_feed(fps, watts)`: one sample (rendered fps, package watts or -1). Runs `autotune_feed` on Power's worker; newest wins while it's busy. Ignored unless Auto TDP runs. PerfMonitor calls it; nobody else needs to.
- `Power.request_autotune_target(fps)`: the frame rate the game should hold (its frame limit, 0 = none). PerfMonitor's `set_target_fps` / `start(id, {"target_fps": n})` pass it on (again when Auto TDP starts); Power forgets it when Auto TDP stops.
- `Power.autotune_active() -> bool`, `Power.autotune_limit_info() -> Dictionary`.
- Signals (main thread): `autotune_changed(on: bool)`; `autotune_limit(cant_reach: bool, info)` with `info = {"cant_reach", "target_fps", "fps", "tdp_w", "ceiling_w", "ref_fps", "tdp_max"}`.
- Can't reach: a target is set, the TDP is at the ceiling (the user's TDP) or the ceiling's measured best is under the target, and the fps stay under `target * 0.95` for 10 s. Clears after 5 s on target, a new ceiling or target, or stop. UI: `ceiling_w < tdp_max` → "raise the TDP to hold N fps"; else "this game can't hold N fps on this device; lower its settings or frame limit".

## Performance (`PerfMonitor`)

Samples once a second only between `start()` and `stop()` while focused (or while Auto TDP runs, which starts it by itself). Nothing at idle. Each sample is plain file reads on a thread-pool task; no process per sample.

| Call | What |
| --- | --- |
| `start(app_id := 0, opts := {})` | A game runs and is in front. `opts`: `frame_gen_multiplier` (presented / rendered, default 1), `target_fps` (frame limit). Screens: on `GameSession.started` |
| `stop()` | Screens: on `GameSession.ended` |
| `set_focused(bool)` | false while home is in front of the running game (pauses) |
| `set_target_fps(fps)`, `set_frame_gen_multiplier(m)` | When the quick menu changes them mid-game |
| `latest`, `is_active()` | Last sample, running or not |
| `capabilities()` | `{"fps": bool, "overlay": bool, "fps_needs_overlay": bool, "sources": {metric: source or ""}}`; reads sysfs, call once per screen |
| `overlay_supported()`, `overlay_level()`, `overlay_levels()`, `set_overlay_level(n) -> bool` | Performance overlay: 0 off, 1 fps, 2 compact, 3 full |

Signals: `sample(data)`, `running_changed(active)`, `overlay_changed(level)`.

```
{
  "time": 1762600000.0, "app_id": 976730,
  "fps": 119.6, "fps_rendered": 59.8, "frame_ms": 8.4,      # presented / rendered (fps / frame-gen multiplier)
  "cpu_load": 34.0, "gpu_load": 91.0,                       # percent
  "cpu_temp": 71.0, "gpu_temp": -1.0,                       # C
  "package_w": 17.2, "gpu_w": -1.0, "cpu_w": -1.0, "battery_w": 21.5,
  "gpu_mhz": 1850.0,
  "sources": {"fps": "mangohud", "package_w": "rapl", ...}  # only metrics we have
}
```

Every number is -1 when unknown. Sources (first that works):

| Metric | Source |
| --- | --- |
| fps, frame_ms | mangoapp's MangoHud log: gamescope sends mangoapp each frame's timing (SysV queue `ftok("mangoapp", 65)`, one reader, so we don't read it). We add `output_folder=$XDG_RUNTIME_DIR/gamecove-mangohud` and `log_interval=1000` to the session's `MANGOHUD_CONFIGFILE` and start the log with `mangohudctl set log_session 1` (once per game; again only if no rows come, at most every 3 s, 5 times). No mangohudctl: `autostart_log=1`, which only logs while the overlay is visible (`fps_needs_overlay`). Not used: gamescope's `-T` stats pipe (fps once per 300 frames, may have another reader) |
| cpu_load | `/proc/stat` delta |
| package_w | RAPL `/sys/class/powercap/intel-rapl:N` (name `package-0`) `energy_uj` delta, if readable (root-only on many kernels); else amdgpu hwmon `power1_average`/`power1_input` on an APU (VRAM ≤ 4 GiB) |
| gpu_w | RAPL `uncore` subzone; amdgpu power on a dGPU; discrete Intel hwmon `energy1_input`; else the log's `gpu_power` |
| gpu_load | amdgpu `device/gpu_busy_percent`; else the log's `gpu_load` (Intel) |
| gpu_mhz | xe `device/tile0/gt0/freq0/act_freq`, i915 `gt_act_freq_mhz`, amdgpu hwmon `freq1_input` |
| cpu_temp, gpu_temp | hwmon `coretemp`/`k10temp`/`zenpower` `temp1_input`, else thermal zone `x86_pkg_temp`; amdgpu / discrete Intel hwmon `temp1_input` |
| battery_w | `BAT*/power_now` (or current × voltage) while discharging |

Overlay: no gamescope atom. Like Steam and OpenGamepadUI, we rewrite the session's `MANGOHUD_CONFIGFILE` (gamescope-session-plus makes it with `mktemp /tmp/mangohud.XXXXXXXX` and writes `no_display`); mangoapp reloads it on inotify, and gamescope reads it to know if the overlay shows. Unsupported (returns false) without that variable or without `mangoapp` on `PATH`. The level is remembered in `user://perf.cfg` and put back at start. The overlay also shows over our home screen; while a log runs MangoHud draws a small dot in its corner.

## Achievements (`Achievements`)

- `achievements_for(appid) -> Dictionary`, at once (cached against the files' mtimes):
  `{"appid": "4242", "unlocked": 3, "total": 4, "source": "steam-local" | "", "items": [{"id": api name, "name", "description", "hidden": bool, "icon": local path or "", "icon_gray", "icon_url", "icon_gray_url", "unlocked": bool, "unlock_time": unix or 0, "rarity": percent or -1}]}`. Empty (`total` 0, `source` "") when Steam or the files are missing.
- `request(appid)`: same, read on the thread pool; answers with `loaded(appid, result)`.
- `changed(appid)`: rarity arrived; ask again. `invalidate(appid)` drops the cache (e.g. after the game ends).
- Settings: `steam_root` ("" = first Steam root with `appcache/stats`), `account` ("" = MostRecent in `config/loginusers.vdf`), `language` (Steam language name), `fetch_rarity` (default true).
- Files: `appcache/stats/UserGameStatsSchema_<appid>.bin` and `UserGameStats_<accountid>_<appid>.bin` (binary KeyValues); icons from `appcache/librarycache/<appid>/` when Steam cached them, else Steam's community CDN URL. Steam updates the user file when it syncs stats, so it can lag a running game.
- Rarity: `GetGlobalAchievementPercentagesForApp/v0002` (no key), at most once per game per day (failures too), off the main thread, stored in `user://achievements/rarity/<appid>.json`. Steam Web API terms: personal use, no implied Valve endorsement.

## Per-game settings (`Launcher.settings_for(key)`)

```
{"goal": "battery|balanced|smooth", "fps_limit": 0, "upscaler": "auto|off|fsr|xess", "frame_gen": false, "low_latency": true}
```

`Launcher.launch_env(game)` returns the environment variables to add for that game on this device. A game's settings are shared by every handheld the drive boots and resolve per device at launch: `auto` picks XeSS on Intel Xe with the XMX driver, FSR 4 on AMD where the Proton has it, else off; an explicit choice that can't work on this GPU (`xess` on AMD, anything on an unknown GPU) falls back for this launch with a note, and the saved choice stays (`LaunchEnv.choice_for_gpu`). Measured frame rates (`record_base_fps` / `base_fps`) are kept per device (`"measured": {device id: {game: fps}}`).

Non-Steam games also have compatibility settings, stored in the same file under `"compat"`: `Launcher.compat_for(key)` → `{"proton": tool id ("" = umu default), "prefix": "", "extra_env": {}, "args": ""}`, `save_compat(key, dict)`, `compat_tools()`, `proton_path_for(id)`. The UI changes them through `Library.set_compat_tool` / `set_launch_options`. Steam games start through `steam://`, which takes no environment: for them the game page shows only goal and frame limit, plus a line pointing to Steam launch options. `Launcher.auto_tdp_for(key)` is true for goals `battery` and `balanced`. `Launcher.set_default_goal(goal)` / `default_goal()`: the goal for games without their own settings (`""` = the device default); the installer's Auto TDP choice sets `balanced` or `smooth`.

## Root actions

Anything that needs root (firmware, kernel arguments, InputPlumber overrides, udev rules) goes through one helper, `packaging/libexec/gamecove-fix`, run with `pkexec`. Each fix (a folder `fixes/<name>/` with `fix.sh`) has `install`, `remove` and `status` (some also `set <value>`), records what it changed, and can be undone. No root daemon of our own.

Two entry points, because polkit picks its rule by the program pkexec runs:

| Program | polkit action | Password | Accepts |
| --- | --- | --- | --- |
| `/usr/libexec/gamecove/gamecove-fix-set` | `io.github.ihulksmashi.gamecove.fix-set` | none in the active local session | `<name> set <value>` and `<name> status`, only for `charge-limit set 50..100`, `fan set auto\|quiet\|max`, `claw8ex-gyro set accel-on\|accel-off` (gyro must be installed), and `set on\|off` of the file fixes built on `fixes/lib/gcfix.sh` (list `FILE_FIXES`; see docs/CONTROLS.md, Fixes). Then hands over to `gamecove-fix`. |
| `/usr/libexec/gamecove/gamecove-fix-set` | `io.github.ihulksmashi.gamecove.fix-set` | none in the active local session | `<name> set <value>` and `<name> status`, only for `charge-limit set 50..100`, `fan set auto\|quiet\|max\|curve:<duties>`, `claw8ex-gyro set accel-on\|accel-off` (gyro must be installed), `power-tune set <key>:<value>\|restore` (keys in CONTROLS.md; fix.sh checks each value against the kernel). Then hands over to `gamecove-fix`. |
| `/usr/libexec/gamecove/gamecove-fix` | `io.github.ihulksmashi.gamecove.fix` | administrator (`auth_admin_keep`) | everything: `<name> install\|remove\|status\|set <value>`, `--list` |

- The app's everyday settings use `pkexec /usr/libexec/gamecove/gamecove-fix-set <name> set <value>` (`Power.fix_command()`). Exit 64 bad usage or action not allowed there, 65 fix not allowed there, 66 value not allowed, else as `gamecove-fix`.
- Install and remove always use `pkexec /usr/libexec/gamecove/gamecove-fix <name> install|remove`. That asks for a password, and the gamescope session has no polkit agent to ask with, so the UI must say so (e.g. run it from Desktop Mode or a terminal) rather than fail silently; pkexec exits 126 or 127 when nobody could authorize.
- Read-only calls need no pkexec: `/usr/libexec/gamecove/gamecove-fix --list` prints one fix name per line; `/usr/libexec/gamecove/gamecove-fix <name> status` prints `key=value` lines and always ends with `state=<s>`. Every fix prints `applies=yes|no` (`no` with `state=n/a`: not this hardware) and, when it applies, `installed=yes|no`. `state` is `on` or `off` for every fix, plus per fix: `restart` (claw8ex-vrr, claw8ex-gyro: takes effect after a restart / cold boot, see `next=`), `partial`, `not-needed` (claw8ex-buttons; file fixes when the part isn't there), `os-fixed` (file fixes: the OS already does it), `unsupported`, `other-override` (claw8ex-vrr). charge-limit and fan are `installed=yes`/`state=on` from the first `set` until `remove`; `Power.restore()` re-applies a remembered charge limit or fan preset only while `installed=yes`, so `remove` sticks.
- `devices.json` field `"fixes"`: the fixes the device page offers for that handheld, each exactly a folder name in `fixes/` (what `gamecove-fix --list` prints), e.g. `["claw8ex-buttons", "claw8ex-vrr", "claw8ex-gyro"]` for the Claw 8 EX. Show only names that are both in this list and in `--list`, with their `status`. `charge-limit` and `fan` are not listed there; they belong to the Power page (`"charge_limit"`, `"fan"` fields).

## System services (`Updates`, `Storage`, `Setup`, `Controller`)

Research, privileges and the device checklist: [SYSTEM.md](SYSTEM.md). Shared rules: every
call returns at once; work runs on the service's worker thread and comes back on the main
thread as signals; nothing runs at start or polls (except `Controller` re-applying a saved
layout at start, and `Storage.watch(true)`); no root action of ours. Each service has a
`setup(runner, ...)` for tests, `state()` for the screen, and capability flags: hide what
says `unsupported` / `false`.

### `Updates`

```
signal changed(state)                         # after every phase change
signal checked(kind, result)                  # os: {"available", "version", "notes_url", "staged", "staged_version", "error"}
                                              # firmware: {"available", "devices": [{"id", "name", "current", "version", "summary", "needs_reboot", "trusted", "details_url"}], "error"}
                                              # flatpak: {"available", "pending": [{"id", "name", "version", "branch", "origin", "installation"}], "error"}
signal progress(kind, percent, line)          # percent 0..100 or -1
signal finished(kind, ok, message)            # kind also "reboot"; message "" or game_running | busy | not_available | unsupported | tool's last line
check_updates()                               # every supported kind
check(kind) -> bool                           # kind: os | firmware | flatpak
apply_update() -> bool                        # = apply("os")
apply(kind, target := "") -> bool             # target: one firmware DeviceId, "" = all
reboot() -> bool                              # systemctl reboot; refused during a game
set_game_running(on)                          # main.gd from GameSession.started/ended; apply/reboot refuse while true
phase(kind) -> String                         # unsupported | idle | checking | up_to_date | available | applying | staged | error
state() -> {"os_info": {"id", "name", "version", "variant", "image", "atomic", "family", "backend", "apply_via", "notes_url"},
            "phase": {kind: phase}, "os": {...}, "firmware": {...}, "flatpak": {...},
            "supported": {"os", "firmware", "flatpak"}, "game_running", "reboot_needed"}
```

### `Storage`

```
signal changed(state)
refresh()                                     # findmnt + lsblk + library files
watch(on)                                     # true when the Storage page opens, false when it closes
measure(path)                                 # du -sb one library folder on request
state() -> {"ready", "error", "watching",
            "drives": [{"device", "kind": internal|sd|external, "label", "model", "fstype", "mount", "mounts",
                        "size", "used", "free", "compression", "removable"}],   # bytes, -1 unknown
            "libraries": [{"store": steam|heroic|games, "path", "device", "mount", "free", "bytes", "games", "compression"}]}
```

No formatting (future work in SYSTEM.md).

### `Setup`

```
signal changed(steps)
signal login_started(store, info)             # {"store", "url", "needs": steam|code|redirect_url|heroic|unavailable, "param"}
signal login_finished(store, ok, message)
signal fixes_checked(fixes)                   # [{"name", "applies", "installed", "state", "status": {k: v}}]
steps() -> [{"id", "optional", "done", "skipped", "status"}]   # welcome, theme, stores, device_fixes, steamgriddb, done
is_first_run() -> bool                        # until complete("done")
next_step() -> String
complete(step) -> bool / skip(step) -> bool (optional steps only) / reset()
store_status() -> {store: {"signed_in", "account", "tool", "how", "config"}}   # steam | epic | gog | amazon
start_login(store) -> bool                    # then login_started: show `url` as QR + text
finish_login(store, text) -> bool             # text: the code or the whole address; then login_finished
cancel_login(store)
suggested_fixes() -> Array / check_fixes()    # devices.json "fixes" that `gamecove-fix --list` has, with status
steamgriddb_key() -> String / set_steamgriddb_key(key) -> bool   # 32 hex chars, "" removes
```

Stored in `user://setup.cfg` (`[steps]`, `[skipped]`, `[keys] steamgriddb`). The installer (docs/SESSION.md, "Installer") marks the steps it covered after a successful install, so the first-run flow opens only for what's left; on a first run its Next skips steps already done or skipped.

### `Controller`

```
signal changed(state)
signal applied(setting, ok)                   # paddle | gyro | rumble | profile | game_profile
refresh()                                     # call when the controller page opens
set_paddle(paddle, target)                    # InputPlumber: paddle LeftPaddle1..3 / RightPaddle1..3; target a gamepad button, "Key…", or "" to reset
set_paddle_mode(mode)                         # hhd: paddles as a whole, one of state()["paddle_modes"] (steam_input | noob | touchpad | both | disabled)
set_gyro_mode(mode)                           # one of state()["gyro_modes"]: InputPlumber off | mouse | stick; hhd off | on
set_rumble(enabled) / test_rumble(strength := 0.6)   # test_rumble: InputPlumber only
set_led(color, brightness) -> bool            # hhd: solid color, true when queued, then applied("led", ok); InputPlumber has no LED setter (false)
load_profile_file(path)
set_game_profile(key, on) / has_game_profile(key)
start_game(key) / end_game()                  # main.gd from GameSession.started/ended (also set game focus on / off)
signal ui_action(action)                      # "home" | "quick_menu" | "osk" | "screenshot", main thread (intercept, below)
signal button_event(capability, pressed)      # every button seen through the intercept ("South", "Guide"...): button test
set_game_focused(on)                          # via SessionWiring (home_in_front / menu_over_game / sync_focus): false while home or the quick menu is over a running game; the mode is written again on every call (InputPlumber moves itself from Pass to Always on Guide)
release_intercept(done := Callable())          # before a session switch: stop intercepting, InterceptMode 0 on every composite device (worker), then done() on the main thread
set_button_test(on)                           # controller page's button test: virtual pad straight to Godot (paddles show) when no game runs
intercept_state() -> {"active", "listening", "mode", "game_focused", "activation": {"events", "target"}, "chords": {action: [modifier, button]}}
state() -> {"backend": "inputplumber" | "hhd" | "none",
            "capabilities": {"guide_qam", "intercept", "paddles": "remap" | "mode" | "", "gyro", "rumble", "rgb", "per_game"},
            "gyro_modes", "paddle_modes", "paddle_mode", "rgb": {"hue", "saturation", "brightness"} | null,
            "available", "version", "devices": [{"path", "name", "profile_name", "profile_path", "capabilities",
            "output_capabilities", "paddles", "gyro", "rumble", "led", "gamepad"}], "active",
            "profile": {"name", "path", "paddles": {paddle: target or ""}, "gyro": off|mouse|stick|custom},
            "rumble": bool|null, "led", "game", "game_profile",
            "supported": {"profiles", "paddles", "gyro", "rumble", "led", "per_game"}}
```

The UI shows a control only when `capabilities` says the backend can do it. Backend: InputPlumber
when it has a gamepad composite device, else Handheld Daemon when its API answers
(`http://127.0.0.1:5335/api/v1/state`, bearer token from `/tmp/hhd/token`, `/etc/hhd/.token` or
`~/.config/hhd/token`), else none. With hhd there is no intercept: Guide reaches GameCove as the virtual
pad's Guide button while our UI has focus (main.gd), and hhd's Steam shortcuts arrive as Ctrl+1 (home) and
Ctrl+2 (quick menu); in a game hhd keeps its buttons.

Profiles we write, per device (`<id>` = `Device.id()`): `~/.config/inputplumber/profiles/gamecove/<id>/default.yaml`
and `<store>_<id>.yaml` (JSON, InputPlumber profile schema v1); with hhd, `<store>_<id>.hhd.json` (the
controller section and LEDs of hhd's state, posted at game start, the old values posted back at the end).
Files straight in `gamecove/` (older versions) move to the device that starts first.

**Guide / Quick Access intercept** (`scripts/input/intercept.gd`, as OpenGamepadUI does it; why in
[DEVICES.md](DEVICES.md#what-the-input-service-must-do)). Only inside GameCove's own gamescope session
(`GAMECOVE_STEAM_MODE` set by our session file, `Gamescope.is_running()`, and not `GAMECOVE_INTERCEPT=0`);
under Steam's session InputPlumber is left alone.

- Every gamepad composite device gets `SetInterceptActivation(as, s)`: its home button (Guide on most
  handhelds), else its Quick Access button (GPD WIN 4), else View + Menu delivered as Guide (GPD WIN Max 2).
- `InterceptMode` (u): **2** (Always) while GameCove's UI has focus, **1** (Pass) while a game has focus,
  **0** when the monitor isn't running, for the button test, and when GameCove quits.
- Signals: one `gdbus monitor --system --dest org.shadowblip.InputPlumber` child (a normal match rule;
  `busctl monitor` / `dbus-monitor` need root on the system bus), read line by line on its own thread.
  The exact signal: `org.shadowblip.Input.DBusDevice.InputEvent(event s, value d)` from
  `/org/shadowblip/InputPlumber/devices/target/dbusN`; value 1.0 pressed, 0.0 released, 0..1 for stick
  directions. `ObjectManager.InterfacesAdded` for a new `CompositeDeviceN`, or InputPlumber getting a new
  bus owner, applies the intercept again. If the monitor exits it is restarted up to 3 times.
- `event` goes through `Buttons.action_for_dbus(device, event)`: `home` / `quick_menu` / `osk` /
  `screenshot` become `ui_action(action)`; navigation (`ui_accept`, `ui_back`, d-pad, sticks, LB/RB,
  LT/RT...) is injected as Godot `InputEventJoypadButton` / `InputEventJoypadMotion`, because in mode 2
  the virtual pad gets nothing. Devices without a button for an action get `Buttons.FALLBACK_CHORDS`
  (Quick Access + A = home, + Y = keyboard, + RB = screenshot) while our UI has focus.
- In a game, Guide (the activation) switches InputPlumber to Always and arrives as `ui_action("home")`;
  main.gd shows home and calls `set_game_focused(false)`, and `set_game_focused(true)` when the game has
  the screen again. Quick Access stays Steam's inside a game (InputPlumber's Xbox target turns it into
  Guide + A, Steam's quick access menu); in GameCove's UI it opens our quick menu.

## Device pages (`scripts/ui/device/`, embedded by Settings)

`about_panel.gd`, `controller_panel.gd`, `storage_panel.gd`, `updates_panel.gd`: each
`static func build(services: Dictionary) -> Control` with services `{"device", "power", "controller",
"storage", "updates"}`. The Control (base `device_panel.gd`) offers `default_focus()`, `focusables()`,
`set_top_target(c)`, `hints() -> [[glyph, label], ...]` + `signal hints_changed(hints)`,
`signal toast_requested(text, icon, tone)`, and `opened()` / `closed()` (Storage watches hot-plug from
open to close, Controller refreshes on open and ends the button test on close; entering / leaving the
tree does the same). Pages listen to their services' signals and disconnect when freed.


- GDScript: `godot --headless --path app -s res://tests/run_tests.gd`. Tests are `app/tests/test_*.gd` extending `res://tests/test_case.gd`; fixtures in `app/tests/fixtures/`.
- Python (game database): `cd gamedb && pytest`.
- Shell helpers: `shellcheck`, plus tests under `packaging/tests/`.
- No test may touch the real system: use fixture files and fake command output.

## Style

- Every user-visible setting has one short line saying what it does and what it costs.
- Battery first: no polling while a game has focus unless a feature needs it.
- Credit borrowed ideas in CREDITS.md.
