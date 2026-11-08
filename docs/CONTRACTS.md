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
