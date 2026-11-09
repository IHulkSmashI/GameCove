# Controls

Every setting is a Control (app/scripts/controls/control.gd) registered by a provider. One section per area.

## Display, audio and system (ctl-display)

Providers: `app/scripts/controls/providers/display.gd`, `audio.gd`, `system.gd`; helpers in
`app/scripts/controls/display/` (xatoms, panel, session_env, store, color, reshade, wpctl, sysfs,
texts_display). Tests: `app/tests/test_ctl_display.gd`, `test_ctl_audio_system.gd` (fake system in
`app/tests/fixtures/ctl_display/`). Every hook runs on the Controls worker; nothing polls.

**How gamescope is driven.** Root-window atoms through `xprop` and `ctx.runner`, built with the
Gamescope service's static `set_args/get_args/parse_values`. The Controls worker *is* the async path
(the Gamescope `*_async` calls answer on the main thread, which a hook can't wait for). Reads share one
`xprop -root -notype` dump for 750 ms, so `detect_all()` costs one process. Writes are read back.
Floats are IEEE bit patterns in a CARDINAL. Names from gamescope `src/steamcompmgr.cpp` at 89b9e6e.

| Control | Applied with | Available when |
| --- | --- | --- |
| `display.brightness` (5-100 %, not per game) | logind `Session.SetBrightness("backlight", <dev>, raw)` over `busctl --system` (no root, no prompt); falls back to writing the sysfs file if the image made it writable. Raw (GPU) backlight beats platform and firmware. Never below 5 %. On ONEXPLAYER 3 always, and on Legion Go 2 while gamescope outputs PQ (`GAMESCOPE_HDR_OUTPUT_FEEDBACK`=1): `GAMESCOPE_SDR_ON_HDR_CONTENT_BRIGHTNESS` 20-600 nits, re-applied on read when gamescope dropped it after suspend | a backlight in `/sys/class/backlight`, or one of those screens |
| `display.vrr` (order 30) | `GAMESCOPE_VRR_ENABLED` | gamescope's `GAMESCOPE_VRR_CAPABLE`=1; without that atom, a `vrr_range` in devices.json |
| `display.refresh_rate` (order 20) | `GAMESCOPE_DYNAMIC_REFRESH`; the panel maximum writes 0 (gamescope's own) | range from `STEAM_DISPLAY_REFRESH_LIMITS` (session) or `panel_hz`; gamescope knows the panel (its displays/*.lua, device-quirks' CUSTOM_REFRESH_RATES) or the session has `CUSTOM_REFRESH_RATES` |
| `display.refresh_unlock` | writes `CUSTOM_REFRESH_RATES` to `~/.config/environment.d/80-gamecove-display.conf`, next session. VRR panels: every whole rate in panel∩VRR range; others: only the two ends | known (non-generic) device, gamescope-session-plus installed, panel not already known |
| `display.fps_limit` (order 10) | `GAMESCOPE_FPS_LIMIT`; choices Off + fractions of the top rate | gamescope |
| `display.allow_tearing` | `GAMESCOPE_ALLOW_TEARING` | gamescope |
| `display.upscale_filter` | `GAMESCOPE_NEW_SCALING_FILTER` (0 linear, 1 nearest, 2 FSR, 3 NIS, 4 pixel, 5 SGSR) | gamescope; SGSR only when the binary has it (`grep -a`) |
| `display.upscale_scaler` | `GAMESCOPE_NEW_SCALING_SCALER` (auto, integer, fit, fill, stretch) | gamescope |
| `display.sharpness` (0-20, higher = sharper) | `GAMESCOPE_SHARPNESS` = 20 - value | gamescope |
| `display.vibrance` | `GAMESCOPE_COLOR_SDR_GAMUT_WIDENESS` float 0-1 (vibrantDeck's atom). Default 100 % on OLED (native gamut there), 0 on sRGB panels | gamescope |
| `display.color_temp` (4500-9500 K) | `GAMESCOPE_DISPLAY_VIRTUAL_WHITE` = CIE xy (daylight locus); 6500 K removes it | gamescope |
| `display.night_light`, `_strength`, `_schedule` | `GAMESCOPE_COLOR_NIGHT_MODE` [amount, hue 0.07, saturation 0.6]. Schedule is stored; the UI arms one timer with `color.gd seconds_to_next_switch()` and sets `display.night_light` | gamescope |
| `display.hdr` | `GAMESCOPE_DISPLAY_HDR_ENABLED`, plus `ENABLE_GAMESCOPE_HDR=1` / `ENABLE_GAMESCOPE_WSI=1` in the session env file (games need the WSI layer from session start) | `GAMESCOPE_DISPLAY_SUPPORTS_HDR`=1; **never on ONEXPLAYER 3** (switching blanks the screen) |
| `display.hdr_itm`, `display.sdr_brightness` | `GAMESCOPE_HDR_ITM_ENABLE`; `GAMESCOPE_SDR_ON_HDR_CONTENT_BRIGHTNESS` (nits) | HDR supported; SDR brightness hidden where Brightness already uses it |
| `display.effect` | `GAMESCOPE_RESHADE_TECHNIQUE_IDX`=0 then `GAMESCOPE_RESHADE_EFFECT` (text, path under Shaders/); Off removes it. Bundled effects are written to `~/.local/share/gamescope/reshade/Shaders/gamecove/` on first use; user and `/usr/share` `.fx` files are listed too | gamescope with ReShade |
| `display.rotation` | `ORIENTATION` in the session env file (auto = removed, device-quirks' own) | gamescope-session-plus |
| `display.dim_after`, `display.screen_off_after` | stored per device; the UI's idle timer reads them (and skips while `system.keep_awake`) | always |
| `audio.volume` / `audio.mute` | `wpctl set-volume -l 1.0 @DEFAULT_AUDIO_SINK@` / `set-mute` | `wpctl status` works and lists a sink |
| `audio.output`, `audio.input` | `wpctl set-default <id>`; values are device names (ids change per boot) | sinks / sources listed |
| `audio.mic_mute` | `wpctl set-mute @DEFAULT_AUDIO_SOURCE@` | a source |
| per-app volume | `audio.gd streams(ctx)` / `set_stream_volume(ctx, id, pct)` for a UI list (not a Control) | |
| `network.wifi` | `nmcli radio wifi on|off`; lifts an rfkill soft block first | `/sys/class/ieee80211/*` and nmcli |
| `network.bluetooth` | BlueZ `Adapter1.Powered` via busctl; rfkill unblock first | `/sys/class/bluetooth/hci*` and BlueZ answering |
| `network.airplane` | `rfkill block all`; off unblocks only the radios that were on (saved per device) | `/sys/class/rfkill` entries |
| `network.wifi_power_save` | steamos-manager `WifiPowerManagement1.WifiPowerManagementState` (user bus) | Wi-Fi and steamos-manager |
| `system.sleep` | `systemctl suspend` | `/sys/power/state` has mem or freeze |
| `system.screenshot` | `GAMESCOPECTRL_REQUEST_SCREENSHOT`=1 (game only), waits ≤3 s for `/tmp/gamescope.png`, copies to `~/Pictures/Screenshots/GameCove_<time>.png` (control meta `last_path`) | gamescope |
| `system.keep_awake` | `systemd-inhibit --what=idle:sleep … tail --pid=<GameCove> -f /dev/null` (ends with us) | always |

**Findings reused (cited in code):** vibrantDeck (`main.py`, gamut atom and encoding); ClawDeck
`screen.py` (OXP3 SDR-on-HDR brightness, never switch HDR there); Rayekkk/LeGo2BrightnessFix release
notes (Legion Go 2 ignores the backlight in PQ; gamescope drops the level after suspend);
Outpox/Bluetooth `main.py` (BlueZ `Adapter1.Powered`; a dongle can own hci0 — with several adapters we
still switch the lowest one, a known limit); gamescope-session-plus (environment.d order: device-quirks
first, then user files, so ours wins; device-quirks' refresh lists aren't exported, hence
`SESSION_QUIRK_REFRESH`). SimpleDeckyTDP and PowerTools have no display code; Decky-AudioLoader and
the brightness-bar plugin only touch Steam's UI, so nothing to take from them.

**Contract notes:** `ctx.env` (optional dict) overrides environment variables, `ctx.config_path`
overrides the store file — both for tests, backward compatible. Choice controls whose options depend on
the device (frame limit, upscaler, effect, outputs) fill `options` in `_detect()`. Controls hold their
provider through `set_meta("provider")`.

**Needs a real handheld:** logind SetBrightness from the gamescope user service; HDR toggle and ITM on
an HDR OLED; refresh unlock (a black screen would need a session restart from SSH/TTY: delete the env
file); the bundled ReShade effects compiling in gamescope's reshadefx; SGSR detection; screenshot timing;
night-light tint strength; rfkill uaccess for airplane mode.

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

**Frame limit: Profiles is the only owner.** `display.fps_limit` is a per-game value in the game's profile. The old per-game `fps_limit` in Launcher's settings (still written by the settings form) is taken over into the game's profile on game start whenever it differs from the value last taken over, snapped to the nearest offered choice at or below it (`sync_launcher_fps()`). While Controls has an available `display.fps_limit`, `GameSession` no longer sets or clears gamescope's limit itself (`GameSession.profiles_own_fps()`); Profiles applies it and puts the pre-game value back. Without that control (no gamescope), GameSession keeps its old behaviour.

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

**ctx in the matrix:** `{sys_root, runner, home, device}` as in production, plus `env` (a gamescope session's variables, empty in "bare": read the environment through `ctx.env` when present so the test machine never leaks in), `config_path` (a settings file inside the fixture's home), `hhd_transport` (a fake `hhd_http.gd`: use `ctx.get("hhd_transport")` when present, else `HhdHttp.new()`) and `devicematrix` (scenario name). The fake runner keeps gamescope's root atoms (`xprop -root`) and D-Bus properties as state, and has `spawn()` / `kill()` / `is_running()` for background processes (never started).

**Extending it**

- New sysfs/D-Bus/commands your provider reads: add them to `gen.py` (`build()` for files, `backends_for()` for props, methods and `commands`; mark mutating commands `"write": true` so the failing scenario refuses them). Facts for one device only: `tools/devicematrix/overrides.json` (`{"<id>": {"cpu_model", "threads", "leds", "backlight", "files": {"/sys/...": "value"}}}`).
- What your provider promises: `tools/devicematrix/expectations.json` → `devices`, keyed by device id or selector (`*`, `generic`, `vendor:amd|intel`, `driver:amdgpu|xe|i915`, `stack:hhd|inputplumber|steamos-manager|powerstation`), e.g. `"lenovo-legion-go-s-z2go": {"power.tdp": {"available": true, "max": 33}}`. Keys: `available`, `reason_contains`, `kind`, `unit`, `min`, `max`, `min_ge`, `max_le`, `step`, `options_include`, `options_exclude`, `value`, `note`, and `ac: {...}` for the plugged-in scenario. A listed id that no provider registers fails, so add entries with the provider.
- `facts` hold what tested community projects know per handheld, with a source each: TDP tables from Handheld Daemon's adjustor, RGB presence and LED names from HueSync, the Steam Deck / Intel TDP limits from SimpleDeckyTDP. They're checked whenever a matching control exists (`power.tdp*` min/max, `*sppt*`/`*boost*`, `*fppt*`; `controller.rgb*`/`controller.led*` must be unavailable where `rgb.present` is false) and drive the LED nodes gen.py creates. `_conflicts` lists where devices.json disagrees with them.
- Report: `DEVICEMATRIX_REPORT=/tmp/r.json godot --headless --path app -s res://tests/run_tests.gd` writes what every control detected on every device in every scenario and which commands had no canned answer; CI uploads it as the `devicematrix-report` artifact.
