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
Every adjustable setting is a Control (app/scripts/controls/control.gd) registered with the
`Controls` autoload by a provider in app/scripts/controls/providers/. Each area appends its own
section here.

## Controller

Provider: `app/scripts/controls/providers/controller.gd`. Helpers in `app/scripts/controls/input/`:
`backend.gd` (one snapshot of InputPlumber, hhd and LED nodes per detect pass, dropped on every
write; nothing polls), `ip_edit.gd` (InputPlumber profile edits), `hhd_client.gd` (Handheld
Daemon over curl), `leds.gd` (kernel LED nodes), `caps.gd` (what the hardware has, from
devices.json and the button profile). Root writes: `fixes/controller-led` through
`gamecove-fix-set controller-led set ...` (no password).

The Controller service (`app/scripts/input/controller.gd`: Guide/QAM intercept, its page, legacy
per-game layout files) stays. The controls write the same everyday layout file
(`~/.config/inputplumber/profiles/gamecove/<device>/default.yaml`), which the service loads again
at start because InputPlumber forgets profiles at reboot, and ask the service to refresh after a
change.

### Which backend, on which device

Picked at detect time on the running system, not from the table:

1. **InputPlumber** when it has a gamepad composite device (Bazzite and SteamOS default).
2. **Handheld Daemon** when `/run/hhd` exists and its API answers (UNIX socket `/run/hhd/api`,
   else `127.0.0.1:<hhd.http.port>` with the token). Options come from hhd's own schema
   (`/api/v1/settings`), so each handheld shows what hhd offers on it.
3. **RGB**: hhd when its state has `rgb.handheld.mode`; otherwise the kernel LED nodes when
   InputPlumber (or nothing) handles the pad. InputPlumber's D-Bus API has no LED setter; it only
   forwards a game's lightbar colour to the same nodes when it emulates a DualSense.

### The controls

| id | kind | InputPlumber | hhd |
| --- | --- | --- | --- |
| `controller.gyro` | toggle | drop / pass the `gyroscope` sources (mapping with no targets) | `imu` / `gyro` bool, or Legion Go `imu` mode (`disabled` vs the side it had) |
| `controller.gyro_source` | choice | which of `Gyroscope:Left/Right/Center` pass (Legion Go: one per controller) | Legion Go `imu` mode left/right/both |
| `controller.gyro_accel` | toggle | MSI Claw 8 EX with the gyro fix: `gamecove-fix-set claw8ex-gyro set accel-on/off` | same |
| `controller.gyro_aim` | choice | always unavailable: points to Steam Input (see below) | same |
| `controller.emulation` | choice | profile `target_devices` (Steam Deck, DualSense Edge, Xbox Elite, Xbox Series, DualSense, Xbox 360; "Handheld default" = the device config's own list, `/etc/inputplumber/devices.d` first) | `controller_mode` / `xinput` modes from the schema |
| `controller.paddles_as` | choice | unavailable (each paddle is set on its own) | `paddles_as` of the current emulation mode |
| `controller.paddle.<Cap>` | choice | one per back paddle in the button profile (label "Back button M1"): itself, off, any button, mouse click, a key | unavailable |
| `controller.button.<Cap>` | choice | special buttons GameCove leaves to the game (e.g. Xbox Ally's Armoury Crate hold) | unavailable |
| `controller.nintendo_layout` | toggle | A<->B, X<->Y mappings | `nintendo_mode` |
| `controller.desktop_mode` | toggle | right stick = pointer, RT left click, LT right click, adds the `mouse`/`keyboard` targets | unavailable |
| `controller.desktop_speed` | slider 200-3000 px/s | pointer `speed_pps` | unavailable |
| `controller.trackpad` | choice | one pad (Legion Go/Go S CenterPad): as sent / Steam right pad / Steam left pad / off; two pads: as sent / off | `touchpad` mode (Legion Go, GPD) or multiple (Legion Go S) |
| `controller.rumble` | toggle | `ForceFeedback.Enabled` | Ally `limits.manual.vibration` 0/100; AYANEO `vibration` disabled; OneXPlayer can't go off |
| `controller.rumble_strength` | choice | unavailable (on/off only) | Ally 20-100 %, OneXPlayer `vibration_strength` v1-v5, AYANEO low/medium/high |
| `controller.rumble_test` | action | `ForceFeedback.Rumble(0.6)` then `Stop` | unavailable |
| `controller.deadzone_{left,right}_stick`, `_{left,right}_trigger` | slider % | unavailable (no deadzone translation in InputPlumber) | Ally `limits.manual.ls_min/rs_min/lt_min/rt_min` |
| `controller.led_effect` | choice | LED nodes: off, solid + the node's `effect_index` | hhd rgb modes (off, solid, pulse, rainbow, spiral, duality, oxp...) |
| `controller.led_color`, `controller.led_color_2` | color | first zone / second node (ZOTAC Zone) | `hue`/`saturation`, `hue2` (duality) |
| `controller.led_brightness` | slider % | `brightness` / `max_brightness` (0 = off) | `brightness` or `brightnessd` |
| `controller.led_speed` | slider % | `speed` within `speed_range` | `speed` or `speedd` |
| `controller.reset_layout` | action | removes every "GameCove ..." mapping and our target override | unavailable |

Per game: everything but `gyro_accel`, `gyro_aim`, `desktop_*`, the actions. Every unavailable
control has a plain reason ("This handheld has no trackpad", "Needs the gyro fix first (Device,
Fixes)", "InputPlumber can only turn rumble on or off").

### Hardware per handheld

From devices.json (`gyro`, `rgb`, `buttons`) and buttons.gd; the controls still check the live
backend.

| Handheld | Gyro | RGB (node) | Back buttons | Trackpad |
| --- | --- | --- | --- | --- |
| Steam Deck LCD/OLED | yes | none | L4 L5 R4 R5 | 2 |
| ROG Ally / Ally X | yes | stick rings (`ally:rgb:joystick_rings`, 3 or 12 channels) | M1 M2 | no |
| ROG Xbox Ally / X / X20 | yes | stick rings (`ally:`) | M1 M2 (+ Armoury Crate hold) | no |
| Legion Go / Go 2 | yes, per controller | stick rings (`go:rgb:joystick_rings`, effects) | Y1 Y2 Y3 M3 | 1 |
| Legion Go S | yes | stick rings (`go_s:rgb:joystick_rings`, effects) | Y1 Y2 | 1 |
| MSI Claw 8 EX | needs the gyro fix | stick rings (hhd, or `msi_claw:` with the hid-msi patches) | M1 M2 | no |
| MSI Claw A1M / A8 | yes | stick rings (hhd / `msi_claw:`) | M1 M2 | no |
| MSI Claw 7/8 AI+ | not on Linux yet | stick rings | M1 M2 | no |
| OneXPlayer X1 / F1 / Apex | yes | stick rings (hhd; OneXPlayer styles) | M1 M2 / M2 | no |
| OneXPlayer 2 / X2 / G1 | yes / yes / none | none | - / M1 M2 / - | no |
| AOKZOE A1 / A1 Pro | yes | stick rings (hhd; AOKZOE styles) | - | no |
| AYANEO 2 / 2S / Air / Kun / Slide | yes | stick rings (`ayaneo:` / `multicolor:chassis`) | - | no |
| AYANEO 3 | yes | stick rings (`*:rgb:joystick_rings`) | - | no |
| GPD WIN 4 / Mini / Max 2 / 5 | yes | none | L4 (R4) | no |
| ZOTAC Zone | yes | two zones (`zotac:rgb:spectra_zone_0/1`) | M1 M2 | 2 |
| Orange Pi Neo | yes | none | - | 2 |
| Acer Atlas 8 / Blaze | unknown | none | M1 M2 / - | no |

### Findings that shaped this (InputPlumber main 6aca920, 2026-11-07)

- Profile events use `CapabilityConfig`: gyro is a top-level `{"gyroscope": {"name": "Left|Right|Center"}}`.
  The older `{"gamepad": {"gyro": ...}}` form is ignored with a warning (src/input/capability.rs).
- Translation from a gyroscope (and from a touchpad to the mouse) is `NotImplemented`
  (src/input/event/value.rs); such an event is dropped. So **gyro as mouse / joystick, its
  sensitivity and activation button can't be done in InputPlumber, and hhd doesn't do it
  either**: both hand raw motion to a Steam Deck / DualSense target and Steam Input does the rest.
  `controller.gyro_aim` stays greyed with that explanation. The Controller service's older
  "mouse"/"stick" gyro modes (ip_profile.gd) write the ignored form, so they change nothing on
  current InputPlumber; the UI should use `controller.gyro` / `controller.emulation` instead.
- A mapping with no target events drops its source: that's how gyro, a pad or a button goes off.
- A profile's `target_devices` replaces the virtual devices when it loads.
- Axis -> mouse motion has a fixed 0.20 dead band; trigger -> mouse button uses the trigger
  deadzone (0.4 here).

### Taken from Decky plugins (owner's rule: reuse tested device handling)

- **HueSync** (github.com/honjow/HueSync): `py_modules/devices/legion_go2.py` (go ring: profile 3
  before anything else, `mode=custom`, `enabled=true`, channels scaled by `multi_max_intensity`,
  kernel `chroma` = colour cycle, `rainbow` = spiral, speeds low/medium/high = 33/66/100),
  `py_modules/devices/asus_ally.py` (12-channel Ally node), `src/index.tsx` (re-apply lights 5 s
  after resume). The provider lists the light controls in `REAPPLY_AFTER_RESUME` /
  `RESUME_DELAY_S` for whoever wires resume (main.gd's clock check); the root action records and
  restores every value it touches.
- **hhd-decky** (github.com/hhd-dev/hhd-decky `main.py`): hhd's port from
  `~/.config/hhd/state.yml` (`hhd.http.port`) and the token in `~/.config/hhd/token`.
- **LegionGoRemapper** / **legion-go-tricks** (aarron-lee): drive the Legion Go controllers over
  raw hidraw (RGB, gyro-to-stick in firmware, touchpad, vibration). On current kernels
  hid-lenovo-go owns that interface and InputPlumber hides it, so nothing is reused; the kernel's
  sysfs (`rumble_intensity`, `touchpad/enabled`, per-handle `imu_enabled`) is the future path once
  a root verb for it is worth adding.
- **ROGueENEMY** (archived 2024): raw hidraw for the Ally; superseded by hid-asus's LED node and
  InputPlumber. No InputPlumber Decky plugin exists (OpenGamepadUI is its front end).

### Needs real hardware to confirm

- Legion Go / Go S / Claw kernel LED attributes as the drivers ship them (brightness readback while
  `enabled=false`, effect names on hid-msi).
- InputPlumber dropping gyro with an empty-target mapping, and CenterPad -> RightPad on a Steam
  Deck / DualSense target (Legion Go).
- `SetTargetDevices` through a profile reload re-creating devices without losing the intercept.
- hhd schema shapes on each device (option names, Legion Go S `touchpad` multiple).
Each area appends its own section.

## Fixes (device fixes)

- **Catalogue** `app/data/fixes.json`: per fix `id`, `title`, `line` (one plain sentence for the
  page), `symptom`, `kind` (`root` admin-password fixes, `file` udev / session-file fixes on
  `fixes/lib/gcfix.sh`, `power` shown on the Power page, `app` GameCove-side), `password`
  (`none` / `admin`), `restart` (`""`, `restart`, `cold-boot`, `session`), `auto` and `optional`
  device ids (`"*"` = any known handheld; the fix itself checks the hardware), `bazzite` /
  `steamos` (already fixed there?), `sources`. Research: `docs/DEVICE-FIXES.md`.
- **Auto-apply**: a device's `devices.json` `"fixes"` equals the catalogue's `auto` list for it
  (`test_fixes.gd` checks), so the installer installs exactly those. Root helper states gained
  `os-fixed`; the installer records what it installed in `install-state.json` `"fixes"`.
- **Service** `app/scripts/device/fixes.gd` (not an autoload; the page owner makes one):
  `setup({sys_root, runner, home, device, data_dir?})`, `entries()`, `refresh()` (status of every
  fix in the background), `rows()` (`id, title, line, status, auto, auto_applied, can_apply,
  can_undo, can_check, admin, restart, sources`), `counts()`, `act(fix, "apply"|"undo"|"check")`,
  signals `changed(rows)` and `action_finished(fix, verb, ok, message)`. Status words: `applied`,
  `restart`, `partial`, `needed` (auto fix that is off), `available` (optional, off),
  `not-needed`, `os-fixed`, `blocked`, `checking`, `working`, `unknown`. Apply / Undo:
  `pkexec gamecove-fix-set <fix> set on|off` for file fixes (no password, works in Gaming Mode),
  `pkexec gamecove-fix <fix> install|remove` for root fixes (Desktop Mode). The user's Apply /
  Undo is remembered per device in `~/.local/share/gamecove/fixes.cfg`
  (`[fixes@<device>] <fix>="on"|"off"`): **the installer should skip re-installing a fix the
  user undid there** (not wired yet; installer owner).
- **quiet** (from ClawDeck `quiet.py`): `set_game_running(bool)` moves GameCove's threads to the
  LP-E cores at nice 10 while a game runs and back after (`taskset -a -p`, `renice`); on by
  default, off with Undo on the page. The game-session owner must call `set_game_running`.
- **What changed** (from ClawDeck `changes.py`): `check_changes()` compares kernel, OS version and
  gamescope-session device-quirks with the last start (`system-snapshot.json`), re-checks every
  fix when something changed; `last_changes`, `now_os_fixed()` (GameCove fixes the system now
  does itself, so they can be undone). Call it once at start.
- **Page** `app/scripts/ui/device/fixes_page.gd`: `build({"fixes": svc, "device": Device})`, a
  device page (`device_panel.gd`): summary and "what changed" on the left, one card per fix with
  status chip, one line, "Applied by GameCove" / "Optional", Undo / Apply / Check again.
  Wiring into Settings and the quick menu is the ui wave's.
- **Selftest**: `gamecove-selftest` gives each fix a verdict (applied, already fixed by the
  system, not needed, needed but not applied, partial) and fails when a fix meant for this
  handheld isn't installed with GameCove.

## Performance (ctl-perf)

Provider: `app/scripts/controls/providers/perf.gd`; helpers in `app/scripts/controls/perf/` (store, overlay, lsfg,
launch_files, upscale). Python helper `packaging/helpers/gamecove_upscale/` with its entry
`packaging/libexec/gamecove-upscale`, and the Steam launch wrapper `packaging/libexec/gamecove-run` (both installed
to `/usr/libexec/gamecove/`, the package to `/usr/lib/gamecove/helpers/`). Tests: `app/tests/test_perf_controls.gd`
(fake services in `app/tests/fixtures/perf_controls/`), `packaging/helpers/tests/` (pytest: ClawDeck's tests for
the ported modules plus GameCove's; run from the GDScript suite when pytest is installed).

**Game scope.** Per-game controls act on `ctx["game"]` (a Library game) or `ctx["game_key"]`. Set it with
`PerfProvider.set_game(Controls.ctx, game)` (`preload("res://scripts/controls/providers/perf.gd")`), then call
`Controls.detect_all()`: availability, options (Proton list) and values follow the game. Without a game they report
"Open a game first". Values are stored per device (`user://perf_controls.cfg`, sections `perf/<game key>@<device>`).

**How a game gets its settings.** Non-Steam games GameCove starts: `Launcher.env_hooks` (new, backward compatible)
adds our variables at launch. Steam games (steam:// takes no environment): the files
`~/.local/share/gamecove/launch/<appid>.perf.env` (ours, plus Launcher's own upscaler/latency variables, which
never reached Steam games before) and `<appid>.env` (the upscaling helper's) are exported by `gamecove-run`, which
GameCove puts into the game's Steam launch options through `Library.set_launch_options` the first time a setting
needs it (after `VAR=value` words, in front of other wrappers such as Decky Framegen's fgmod). When the drive boots
another handheld, the files are rewritten from that device's values (stamp `launch/.device`).

| Control | Applied with | Available when |
| --- | --- | --- |
| `perf.overlay` (off, fps, compact, bar, full, custom; per game) | `PerfMonitor.set_overlay_level` plus the new `set_overlay_style(override, extra)`: mangohud.gd writes the session's `MANGOHUD_CONFIGFILE`. bar = one stretched row (fps, frame graph, CPU/GPU, battery W); custom = the ticked items | mangoapp and its config file (`PerfMonitor.overlay_supported()`) |
| `perf.overlay_position`, `perf.overlay_opacity` (0-100 %), `perf.overlay_scale` (50-200 %), `perf.overlay_item.*` (11 items for custom) | MangoHud `position=`, `background_alpha=`, `font_scale=`; items map to MangoHud options (overlay.gd) | same |
| `perf.mangohud_fps_limit` (0 = off, up to the panel's top Hz), `perf.mangohud_fps_limit_method` (late / early) | the game's environment: `MANGOHUD=1 MANGOHUD_CONFIG=no_display,fps_limit=N,fps_limit_method=M`. With `MANGOHUD_CONFIG` set, MangoHud's layer reads no config file (overlay_params.cpp), so the session overlay isn't drawn twice | a MangoHud Vulkan layer JSON in an implicit_layer.d |
| `perf.lsfg`, `perf.lsfg_multiplier` (2-4x), `perf.lsfg_flow_scale` (0.25-1.0), `perf.lsfg_performance` | `~/.config/lsfg-vk/conf.toml`: one `[[profile]]` per game named `GameCove <key>` (Steam games by `active_in = [ "<appid>" ]`, others by `LSFGVK_PROFILE`); every other line kept; a 1.x file is moved to `conf.toml.v1.bak`. The game also gets `ENABLE_GAMESCOPE_WSI=0 DXVK_HDR=0` | lsfg-vk 2 layer (`VkLayer_LSFGVK_frame_generation.json`) and the user's own `lsfg-vk.dll` in `steamapps/common/Lossless Scaling` (Steam beta branch `lsfg-vk`). Never bundled |
| `perf.upscaler`, `perf.frame_gen`, `perf.upscale_recommended`, `perf.upscale_undo` | `gamecove-upscale choose/apply/undo --home --key --gpu vendor=..,family=..,arch=..,xmx=.. [--dir]` (JSON out). OptiScaler (pinned, sha256) into the folder of the game's exe with the game's fixes, REFramework for Capcom RE Engine games, everything recorded and undone exactly | a known GPU, the helper installed, a game whose folder is known |
| `perf.low_latency` (per game) | `Launcher.save_settings(key, {low_latency})`: `LOW_LATENCY_LAYER=1` (Anti-Lag 2 / Reflex through low_latency_layer, bundled in Proton-CachyOS 11) on AMD, XeLL (`IGDEXT_XELL_CAP`) on Intel with the XeSS XMX driver | Launcher and a known GPU |
| `perf.proton` (per game) | `Library.set_compat_tool` (Steam's own API or config.vdf; umu's PROTONPATH for other stores); options from `Library.compat_tools(game)` | Library and a game |
| `perf.launch_wrapper` (Steam games) | adds / removes `gamecove-run` in the launch options | the wrapper installed |
| `perf.shader_threads` (0 = Steam's default, 1-16; not per game) | `steam_dev.cfg` `unShaderBackgroundProcessingThreads N` (Bazzite's bazzite-steam sets the same), next Steam start | Steam installed |
| `perf.clear_shader_cache` (action, Steam games) | deletes `steamapps/shadercache/<appid>` in every library (only that path shape, never following links) | a cache folder exists |

**Upscaling per GPU** (games.py, generalized from ClawDeck's Claw-only logic):

| GPU | Choices | Default route |
| --- | --- | --- |
| Intel Arc with XMX (Xe2, Xe3, Arrow Lake H) | game's own, XeSS, FSR 4.1.2 on XMX, FSR 4.1.2 Lite; XeSS-FG 2x-4x | exactly ClawDeck's: own XeSS if shipped, else OptiScaler XeSS (FSR 4.1.2 on XMX for DX12 games when nitec's files are there), Capcom setup for RE Engine |
| Intel without XMX (Meteor Lake) | game's own, XeSS (DP4a) | as above without XeSS-FG |
| AMD RDNA3 / RDNA3.5 | game's own, FSR 3.1, FSR 4 (AMD's FSR SDK 2.4 upscaler 4.1.2, downloaded from AMD's GitHub at a pinned commit, sha256 checked); FSR-FG 2x | games with FSR keep it (Proton-CachyOS / GE upgrade it to FSR 4 on RDNA3); DLSS / XeSS / FSR 2 games get OptiScaler FSR 3.1; FSR 4 opt-in |
| AMD RDNA2 (Steam Deck, Z2 A, Z2 Go, 6800U) | game's own, FSR 3.1; FSR-FG 2x | as above, no FSR 4 (AMD's lightweight model takes 5.6 ms at 1080p on a Z2 A) |
| unknown | game's own | nothing added |

Conflicts: OptiScaler put in by Decky Framegen (its `FRAMEGEN_PATCH` marker or `<proxy>.b` backups, checked against
Decky-Framegen v0.17), by ClawDeck (`.clawdeck-optiscaler/manifest.json`) or by hand is never touched; the control
fails with the reason ("remove it there first").

### Taken from Decky plugins and other projects
- **ClawDeck** (same author): optiscaler.py, xess.py, xmxscope.py, launchenv.py, gamedb.py, livedb.py,
  reframework.py, framegen.py (read-only part), downloads.py, games.json and its tests, main.py's per-game flow
  (games.py), clawdeck-launch.sh (gamecove-run).
- **decky-lsfg-vk** (xXJSONDeruloXx, e744826): the v2 config keys and ranges (config_schema.py), the DLL location
  and Steam beta branch (steam_service.py, constants.py), `ENABLE_GAMESCOPE_WSI=0` / `DXVK_HDR=0` defaults
  (wrapper_service.py).
- **Decky-Framegen** (xXJSONDeruloXx, 96eb17b): its per-game markers (`defaults/assets/fgmod.sh`, main.py).
- **MangoPeel** (Gawah): the knobs it offers on the same session file (position, offsets, background_alpha), and
  font_size left out there.
- **decky-storage-cleaner** (mcarlucci): `steamapps/shadercache/<appid>` is what to delete for one game.
- **Bazzite** (bazzite-steam): `unShaderBackgroundProcessingThreads` in steam_dev.cfg.

### Improvements over ClawDeck (each tested)
- Every GPU, not just the Claw (table above); AMD presets in launchenv (`fsr31`, `fsr4_amd`, FSR-FG output, Capcom
  setup on FSR) and AMD's own FSR SDK 2.4 upscaler instead of leaked builds (`test_games.py`).
- ClawDeck's own OptiScaler installs are recognised and left alone (`test_foreign_optiscaler_is_never_touched`).
- The LZMS cabinet.dll is looked up (GAMECOVE_CABINET, ~/.local/share/gamecove, an installed ClawDeck) instead of
  assumed inside the package.

### Needs real hardware / real games to confirm
- MangoHud limiter inside gamescope with mangoapp running (frame pacing, no second overlay).
- lsfg-vk 2 profile pick by Steam app id under gamescope with `ENABLE_GAMESCOPE_WSI=0`.
- FSR 4 through OptiScaler with AMD's SDK DLL on RDNA3 / RDNA3.5 under Proton-CachyOS / GE (needs their amdxc64
  shim), and the Capcom setup on AMD.
- `font_scale` in mangoapp; the bar preset's look on 7-8" screens.
- The wrapper in Steam launch options set through Steam's CEF API while Steam runs.
- Not done: a Steam shader pre-caching on/off switch (Steam keeps it where no tested tool writes it; Steam's own
  Settings > Downloads), installing the XeSS XMX driver from a control (ported in the helper, xess.install; one-time
  setup belongs to the installer), the helper's launch file when the drive boots a handheld with another GPU vendor
  (re-pick the upscaler there).
