# Contracts

How the parts of GameCove talk to each other. Change a contract only with a matching change everywhere it's used.

## Services (Godot autoloads, `app/project.godot`)

| Autoload | File | Owner folder | What it does |
| --- | --- | --- | --- |
| `Device` | `scripts/device/device.gd` | `scripts/device/` | Which handheld this is (row of `data/devices.json`), live battery and watts |
| `Power` | `scripts/device/power.gd` | `scripts/device/` | TDP, profiles, fan, charge limit via PowerStation / steamos-manager over D-Bus |
| `Library` | `scripts/library/library.gd` | `scripts/library/` | All stores in one list, game info from the game database, launching |
| `Launcher` | `scripts/launch/launcher.gd` | `scripts/launch/` | Per-game settings and the launch environment (upscaler, frame gen, latency, Proton) |
| `Gamescope` | `scripts/gamescope/gamescope.gd` | `scripts/gamescope/` | Frame limit, refresh rate, overlay focus |
| `PerfMonitor` | `scripts/perf/perf_monitor.gd` | `scripts/perf/` | Running game's fps, frame time, power, load, temps; feeds Auto TDP; performance overlay level |
| `Achievements` | `scripts/achievements/achievements.gd` | `scripts/achievements/` | Steam achievements from the client's local cache, global rarity |

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

`Launcher.launch_env(game)` returns the environment variables to add for that game on this device. Steam games start through `steam://`, which takes no environment: for them the game page shows only goal and frame limit, plus a line pointing to Steam launch options. `Launcher.auto_tdp_for(key)` is true for goals `battery` and `balanced`.

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
