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
| `Updates` | `scripts/system/updates.gd` | `scripts/system/` | OS image, firmware (fwupd) and Flatpak updates |
| `Storage` | `scripts/system/storage.gd` | `scripts/system/` | Drives, free space, game library folders, hot-plug while the page is open |
| `Setup` | `scripts/system/setup.gd` | `scripts/system/` | First-run checklist, store sign-in, suggested device fixes |
| `Controller` | `scripts/input/controller.gd` | `scripts/input/` | InputPlumber: paddles, gyro, rumble, per-game profiles (not named `Input`: that would hide Godot's `Input`) |

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

Stored in `user://setup.cfg` (`[steps]`, `[skipped]`, `[keys] steamgriddb`).

### `Controller`

```
signal changed(state)
signal applied(setting, ok)                   # paddle | gyro | rumble | profile | game_profile
refresh()                                     # call when the controller page opens
set_paddle(paddle, target)                    # paddle LeftPaddle1..3 / RightPaddle1..3; target a gamepad button, "Key…", or "" to reset
set_gyro_mode(mode)                           # off | mouse | stick
set_rumble(enabled) / test_rumble(strength := 0.6)
set_led(color, brightness) -> false           # InputPlumber has no LED setter
load_profile_file(path)
set_game_profile(key, on) / has_game_profile(key)
start_game(key) / end_game()                  # main.gd from GameSession.started/ended
state() -> {"available", "version", "devices": [{"path", "name", "profile_name", "profile_path", "capabilities",
            "output_capabilities", "paddles", "gyro", "rumble", "led", "gamepad"}], "active",
            "profile": {"name", "path", "paddles": {paddle: target or ""}, "gyro": off|mouse|stick|custom},
            "rumble": bool|null, "led", "game", "game_profile",
            "supported": {"profiles", "paddles", "gyro", "rumble", "led", "per_game"}}
```

Profiles we write: `~/.config/inputplumber/profiles/gamecove/default.yaml` and `<store>_<id>.yaml`
(JSON, InputPlumber profile schema v1).

## Tests

- GDScript: `godot --headless --path app -s res://tests/run_tests.gd`. Tests are `app/tests/test_*.gd` extending `res://tests/test_case.gd`; fixtures in `app/tests/fixtures/`.
- Python (game database): `cd gamedb && pytest`.
- Shell helpers: `shellcheck`, plus tests under `packaging/tests/`.
- No test may touch the real system: use fixture files and fake command output.

## Style

- Every user-visible setting has one short line saying what it does and what it costs.
- Battery first: no polling while a game has focus unless a feature needs it.
- Credit borrowed ideas in CREDITS.md.
