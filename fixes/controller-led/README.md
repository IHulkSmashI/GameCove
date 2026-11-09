# controller-led: handheld RGB through the kernel LED class

Not a fix for something broken: the root action behind GameCove's Lights controls
(`controller.led_*`, app/scripts/controls/providers/controller.gd) when Handheld Daemon
isn't the one driving the lights. The LED nodes are root-only to write and Gaming Mode has
no polkit agent, so the app calls it through the no-password entry point:

```
pkexec /usr/libexec/gamecove/gamecove-fix-set controller-led set all,ff8000,80
pkexec /usr/libexec/gamecove/gamecove-fix-set controller-led set 1,00aaff,60,monocolor
pkexec /usr/libexec/gamecove/gamecove-fix-set controller-led set off
gamecove-fix controller-led status | remove
```

`set <zone>,<rrggbb>,<percent>[,<effect>[,<speed percent>]]`: zone `all` or the node's index
in name order. The effect must be one the node lists in `effect_index`.

| Node | Driver | Handhelds |
| --- | --- | --- |
| `ally:rgb:joystick_rings` | hid-asus | ROG Ally, Ally X, Xbox Ally (12 channels = 4 zones on some kernels) |
| `go:rgb:joystick_rings` | hid-lenovo-go | Legion Go, Legion Go 2 (effect, speed, enabled, mode, profile) |
| `go_s:rgb:joystick_rings` | hid-lenovo-go-s | Legion Go S (same attributes) |
| `msi_claw:rgb:joystick_rings` | hid-msi (patch series, 2026) | MSI Claw |
| `ayaneo:rgb:joystick_rings`, `multicolor:chassis` | ayaneo-platform | AYANEO |
| `ayn:rgb:joystick_rings` | ayn-ec | AYN Loki (`led_mode` 1 = manual) |
| `zotac:rgb:spectra_zone_0` / `_1` | zotac-zone-platform | ZOTAC Zone (two zones) |

Device handling copied from HueSync (github.com/honjow/HueSync, py_modules/devices/legion_go2.py
and asus_ally.py): the Legion ring needs a valid `profile` (3) before anything else, `mode=custom`,
and `enabled=true`; its channels are 0-100 (`multi_max_intensity`), so colours are scaled; the
Ally may list 12 channels. Sources for the attributes: kernel
Documentation/ABI/testing/sysfs-driver-hid-lenovo-go and -go-s, LKML "HID: hid-msi: Add RGB
control interface" (v13), InputPlumber's device configs (`group: led`).

Every value written is read back; a node that refuses one gets its previous values back and the
run fails. The first `set` records every node's values; `remove` puts them back. Nothing but
these LED nodes is touched (other LEDs, like keyboard lights, never match the names above).

Tests: `sh fixes/controller-led/test.sh` (fake LED trees; also goes through gamecove-fix-set).
