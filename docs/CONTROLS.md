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
