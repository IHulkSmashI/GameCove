# Controls

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
