# Contracts

How the parts of GameCove talk to each other. Change a contract only with a matching change everywhere it's used.

## Services (Godot autoloads, `app/project.godot`)

| Autoload | File | Owner folder | What it does |
| --- | --- | --- | --- |
| `Device` | `scripts/device/device.gd` | `scripts/device/` | Which handheld this is (row of `data/devices.json`), its buttons, glyphs and picture, live battery and watts, "About this device" info |
| `Power` | `scripts/device/power.gd` | `scripts/device/` | TDP, profiles, fan, charge limit via PowerStation / steamos-manager over D-Bus |
| `Library` | `scripts/library/library.gd` | `scripts/library/` | All stores in one list, game info from the game database, launching |
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

## Tests

- GDScript: `godot --headless --path app -s res://tests/run_tests.gd`. Tests are `app/tests/test_*.gd` extending `res://tests/test_case.gd`; fixtures in `app/tests/fixtures/`.
- Python (game database): `cd gamedb && pytest`.
- Shell helpers: `shellcheck`, plus tests under `packaging/tests/`.
- No test may touch the real system: use fixture files and fake command output.

## Style

- Every user-visible setting has one short line saying what it does and what it costs.
- Battery first: no polling while a game has focus unless a feature needs it.
- Credit borrowed ideas in CREDITS.md.
