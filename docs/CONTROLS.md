# Controls

Every adjustable setting is a Control (`app/scripts/controls/control.gd`) registered with the `Controls` autoload by a provider script in `app/scripts/controls/providers/`. Each area appends its own section below.

## Profiles

`app/scripts/controls/profiles.gd`, autoload `Profiles`. Saved Control values that apply by themselves. Ports ClawDeck's `profiles.py` layering (same author).

**Layers, per device** (stored under `PerDevice.key(Device.id())`; a profile from one handheld never reaches another):

| Layer | `game` / `src` arguments | Holds |
| --- | --- | --- |
| global | `""`, `""` | everyday values |
| ac / battery | `""`, `"ac"` / `"battery"` | per power source |
| game | `"<game key>"`, `""` | one game (`Library` key, e.g. `steam:976730`) |
| game+ac / game+battery | `"<game key>"`, `"ac"` / `"battery"` | one game on one power source |

Precedence: **game+source > game > source > global**.

**When values apply** (no polling; all from signals):

- `Controls.detected`, first time: global + source. Later detections apply only the values of controls that just became available (a provider loaded late, a backend started), never undoing a change made by hand.
- `GameSession.started`: the game's layers. Profiles finds `GameSession` itself when main.gd adds it (`attach_session()` for anything else). The values from just before the game are kept.
- `GameSession.ended`: everything a game layer touched goes back to its pre-game value, then global + source.
- `Power.changed` with a different `plugged`: the other source's layers (also re-checked at every game start/end).
- An edit that touches what's in effect now (`save_current`, `set_layer`, `set_value`, `copy`, `reset`, `import_json`).

**Unknown and late controls.** Values are stored by control id and kept even when nothing registers that id (a provider merged later, a backend not running today, an import from other hardware). Applying skips ids that are unknown, unavailable, not `per_game`, or whose value `Control.coerce` rejects; Controls clamps the rest to the control's range. Brightness-like controls (`per_game = false`) never come from a profile.

| Call | Does |
| --- | --- |
| `effective(game := "", src := "") -> Dictionary` | merged values (`src` "" = current source) |
| `explain(game, src) -> {id: layer}` | where each value comes from: `global`, `ac`, `battery`, `game`, `game+ac`, `game+battery` (for "from this game's profile" badges) |
| `layer(game, src) -> Dictionary` | one layer's own values |
| `save_current(game := running game, src := "")` | snapshot of every available per-game control into a layer ("Save current as this game's profile") |
| `set_layer(game, src, values)`, `set_value(game, src, id, v)` | replace a layer / one value (`null` removes) |
| `copy(from_game, from_src, to_game, to_src)` | `"*"` as src copies all three of a game's layers |
| `reset(game := "", src := "*")`, `reset_all()` | clear a layer, a whole game, or this device |
| `has_profile(game)`, `games() -> [{key, title, updated}]`, `game_ids(game)` | |
| `export_json(game := "") -> String`, `import_json(text, as_game := "") -> {ok, why, game, values, from_device}` | one game or the whole device; `why` is a sentence to show |
| `apply_now(reason := "", only := [])` | send what's in effect to Controls |
| `game_started(game)`, `game_ended(game)`, `set_plugged(bool)` | the events, callable directly (tests, UI) |
| signals `changed()`, `applied({game, source, values, from, reason})` | |

File `user://profiles.json`, written through a temporary file: `{"format": "gamecove-profiles", "version": 1, "devices": {"<device>": {"global", "ac", "battery", "games": {"<key>": {"title", "updated", "all", "ac", "battery"}}}}}`. Values are plain JSON (bool, number, text); whole numbers come back as ints.

Contract change: `Control.coerce()` for `choice` now compares like types only and returns the option's own value (a String against an int option used to be a script error).

## Device matrix

Every provider is tested against every handheld in `app/data/devices.json` plus an unlisted AMD and an unlisted Intel handheld, without the hardware.

- `tools/devicematrix/gen.py OUT` (stdlib Python, run with `-I`) builds `OUT/<id>/root/`: DMI ids from the row's `match`, `/proc/cpuinfo`, drm (amdgpu `pp_*` / `power_dpm_force_performance_level`, xe `tile0/gt0/freq0`, i915 `gt_*_freq_mhz`), power_supply (AC + battery, charge limit files per the row), backlight, hwmon (CPU/GPU temp, the row's fan driver), LED class nodes, firmware-attributes PPT limits (`asus-armoury`, `lenovo-wmi-other-0`, `msi-wmi-platform`), RAPL, cpufreq/SMT/`intel_pstate`, IIO IMU, `usr/bin` stand-ins for installed tools, `home/`. `OUT/<id>/backends.json` holds the fake D-Bus (steamos-manager, PowerStation, InputPlumber props and methods), hhd state and canned command answers. The test generates into `user://devicematrix` unless `DEVICEMATRIX_DIR` points at a generated folder (CI does that).
- `app/tests/devicematrix/matrix.gd` runs each provider in four scenarios: **battery** and **ac** (every available control written past both ends, the middle, every choice, invalid values, then put back), **failing** (services refuse writes, sysfs read-only when not root: value and hardware must stay), **bare** (nothing answers: detection must give a reason).
- Checks: detect never crashes or takes over 1.5 s; available ⇔ reason ""; reasons one short line; ids `<group>.<name>`, no two providers share one; ranges inside `invariants.limits`; sysfs sane after every extreme write (backlight ≥ 1, PPT/RAPL inside the row's range, pwm 0–255, charge threshold 50–100, cpu0 online, governor/EPP from the offered list, Intel media GT untouched, GPU clocks inside RPn–RP0); D-Bus TDP/charge, hhd TDP and `gamecove-fix-set` numbers inside limits; no command argument names a real `/sys`, `/proc`, `/dev`... path; lint: provider sources never call `OS.execute`, `get_tree()`, `Timer.new()` or use an absolute system path without `sys_root`/`home` (`# devicematrix: allow` on a line waives it).

**ctx in the matrix:** `{sys_root, runner, home, device}` as in production, plus `hhd_transport` (a fake `hhd_http.gd`: use `ctx.get("hhd_transport")` when present, else `HhdHttp.new()`) and `devicematrix` (scenario name).

**Extending it**

- New sysfs/D-Bus/commands your provider reads: add them to `gen.py` (`build()` for files, `backends_for()` for props, methods and `commands`; mark mutating commands `"write": true` so the failing scenario refuses them). Facts for one device only: `tools/devicematrix/overrides.json` (`{"<id>": {"cpu_model", "threads", "leds", "backlight", "files": {"/sys/...": "value"}}}`).
- What your provider promises: `tools/devicematrix/expectations.json` → `devices`, keyed by device id or selector (`*`, `generic`, `vendor:amd|intel`, `driver:amdgpu|xe|i915`, `stack:hhd|inputplumber|steamos-manager|powerstation`), e.g. `"lenovo-legion-go-s-z2go": {"power.tdp": {"available": true, "max": 33}}`. Keys: `available`, `reason_contains`, `kind`, `unit`, `min`, `max`, `min_ge`, `max_le`, `step`, `options_include`, `options_exclude`, `value`, `note`, and `ac: {...}` for the plugged-in scenario. A listed id that no provider registers fails, so add entries with the provider.
- `facts` hold what tested community projects know per handheld, with a source each: TDP tables from Handheld Daemon's adjustor, RGB presence and LED names from HueSync, the Steam Deck / Intel TDP limits from SimpleDeckyTDP. They're checked whenever a matching control exists (`power.tdp*` min/max, `*sppt*`/`*boost*`, `*fppt*`; `controller.rgb*`/`controller.led*` must be unavailable where `rgb.present` is false) and drive the LED nodes gen.py creates. `_conflicts` lists where devices.json disagrees with them.
- Report: `DEVICEMATRIX_REPORT=/tmp/r.json godot --headless --path app -s res://tests/run_tests.gd` writes what every control detected on every device in every scenario and which commands had no canned answer; CI uploads it as the `devicematrix-report` artifact.
