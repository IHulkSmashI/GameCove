# Contracts

How the parts of GameCove talk to each other. Change a contract only with a matching change everywhere it's used.

## Services (Godot autoloads, `app/project.godot`)

| Autoload | File | Owner folder | What it does |
| --- | --- | --- | --- |
| `Device` | `scripts/device/device.gd` | `scripts/device/` | Which handheld this is (row of `data/devices.json`), live battery and watts |
| `Power` | `scripts/device/power.gd` | `scripts/device/` | TDP, profiles, fan, charge limit via PowerStation / steamos-manager over D-Bus |
| `Library` | `scripts/library/library.gd` | `scripts/library/`, `scripts/steam/` | All stores in one list, game info from the game database, launching, store management (install, update, downloads, compatibility tool) |
| `Launcher` | `scripts/launch/launcher.gd` | `scripts/launch/` | Per-game settings and the launch environment (upscaler, frame gen, latency, Proton) |
| `Gamescope` | `scripts/gamescope/gamescope.gd` | `scripts/gamescope/` | Frame limit, refresh rate, overlay focus |
| `Discover` | `scripts/discover/discover.gd` | `scripts/discover/` | Deals, prices across stores, wishlist and alerts, release calendar |
| `Art` | `scripts/discover/art.gd` | `scripts/discover/` | Cover / hero / logo / header images for any game, cached in `user://art/` |

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
| `launch_options(game) -> String`, `set_launch_options(game, s)` | Steam: Steam's launch options (`pending: true` in the result when it waits for Steam to stop). Others: extra game arguments |
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

## Power state (`Power.state()`)

```
{
  "backend": "powerstation|steamos-manager|none",
  "tdp_w": 17.0, "tdp_min": 8.0, "tdp_max": 35.0,
  "profile": "balanced", "profiles": ["battery", "balanced", "performance"],
  "charge_limit": 80,             # percent, -1 if unknown
  "fan_mode": "auto", "fan_modes": ["quiet", "auto", "max"],
  "supported": {"tdp": true, "profiles": true, "charge_limit": true, "fan": false}
}
```

Setters (`set_tdp`, `set_profile`, `set_charge_limit`, `set_fan_mode`) return `true` only after reading the value back. `changed(state)` fires after any change. The UI hides any control whose `supported` flag is false.

## Per-game settings (`Launcher.settings_for(key)`)

```
{"goal": "battery|balanced|smooth", "fps_limit": 0, "upscaler": "auto|off|fsr|xess", "frame_gen": false, "low_latency": true}
```

`Launcher.launch_env(game)` returns the environment variables to add for that game on this device.

Non-Steam games also have compatibility settings, stored in the same file under `"compat"`: `Launcher.compat_for(key)` → `{"proton": tool id ("" = umu default), "prefix": "", "extra_env": {}, "args": ""}`, `save_compat(key, dict)`, `compat_tools()`, `proton_path_for(id)`. The UI changes them through `Library.set_compat_tool` / `set_launch_options`. Steam games start through `steam://`, which takes no environment: for them the game page shows only goal and frame limit, plus a line pointing to Steam launch options. `Launcher.auto_tdp_for(key)` is true for goals `battery` and `balanced`.

## Root actions

Anything that needs root (firmware, kernel arguments, InputPlumber overrides, udev rules) goes through one helper, `packaging/libexec/gamecove-fix`, run with `pkexec`. Each fix (a folder `fixes/<name>/` with `fix.sh`) has `install`, `remove` and `status` (some also `set <value>`), records what it changed, and can be undone. No root daemon of our own.

Two entry points, because polkit picks its rule by the program pkexec runs:

| Program | polkit action | Password | Accepts |
| --- | --- | --- | --- |
| `/usr/libexec/gamecove/gamecove-fix-set` | `io.github.ihulksmashi.gamecove.fix-set` | none in the active local session | `<name> set <value>` and `<name> status`, only for `charge-limit set 50..100`, `fan set auto\|quiet\|max`, `claw8ex-gyro set accel-on\|accel-off` (gyro must be installed). Then hands over to `gamecove-fix`. |
| `/usr/libexec/gamecove/gamecove-fix` | `io.github.ihulksmashi.gamecove.fix` | administrator (`auth_admin_keep`) | everything: `<name> install\|remove\|status\|set <value>`, `--list` |

- The app's everyday settings use `pkexec /usr/libexec/gamecove/gamecove-fix-set <name> set <value>` (`Power.fix_command()`). Exit 64 bad usage or action not allowed there, 65 fix not allowed there, 66 value not allowed, else as `gamecove-fix`.
- Install and remove always use `pkexec /usr/libexec/gamecove/gamecove-fix <name> install|remove`. That asks for a password, and the gamescope session has no polkit agent to ask with, so the UI must say so (e.g. run it from Desktop Mode or a terminal) rather than fail silently; pkexec exits 126 or 127 when nobody could authorize.
- Read-only calls need no pkexec: `/usr/libexec/gamecove/gamecove-fix --list` prints one fix name per line; `/usr/libexec/gamecove/gamecove-fix <name> status` prints `key=value` lines and always ends with `state=<s>`. Every fix prints `applies=yes|no` (`no` with `state=n/a`: not this hardware) and, when it applies, `installed=yes|no`. `state` is `on` or `off` for every fix, plus per fix: `restart` (claw8ex-vrr, claw8ex-gyro: takes effect after a restart / cold boot, see `next=`), `partial`, `not-needed` (claw8ex-buttons), `unsupported`, `other-override` (claw8ex-vrr). charge-limit and fan are `installed=yes`/`state=on` from the first `set` until `remove`; `Power.restore()` re-applies a remembered charge limit or fan preset only while `installed=yes`, so `remove` sticks.
- `devices.json` field `"fixes"`: the fixes the device page offers for that handheld, each exactly a folder name in `fixes/` (what `gamecove-fix --list` prints), e.g. `["claw8ex-buttons", "claw8ex-vrr", "claw8ex-gyro"]` for the Claw 8 EX. Show only names that are both in this list and in `--list`, with their `status`. `charge-limit` and `fan` are not listed there; they belong to the Power page (`"charge_limit"`, `"fan"` fields).

## Tests

- GDScript: `godot --headless --path app -s res://tests/run_tests.gd`. Tests are `app/tests/test_*.gd` extending `res://tests/test_case.gd`; fixtures in `app/tests/fixtures/`.
- Python (game database): `cd gamedb && pytest`.
- Shell helpers: `shellcheck`, plus tests under `packaging/tests/`.
- No test may touch the real system: use fixture files and fake command output.

## Style

- Every user-visible setting has one short line saying what it does and what it costs.
- Battery first: no polling while a game has focus unless a feature needs it.
- Credit borrowed ideas in CREDITS.md.
