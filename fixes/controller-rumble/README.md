# controller-rumble: rumble strength in the controller's firmware

Not a fix for something broken: the root action behind GameCove's `controller.rumble_strength`
(app/scripts/controls/input/rumble.gd) on handhelds whose kernel HID driver exposes the
controller's own vibration strength. The attributes are root-only to write and Gaming Mode has no
polkit agent, so the app calls it through the no-password entry point:

```
pkexec /usr/libexec/gamecove/gamecove-fix-set controller-rumble set 60
pkexec /usr/libexec/gamecove/gamecove-fix-set controller-rumble set low
gamecove-fix controller-rumble status | remove
```

| Attribute | Driver | Handhelds | Values |
| --- | --- | --- | --- |
| `rumble_intensity_left`, `rumble_intensity_right` (`rumble_intensity_range`) | hid-msi | MSI Claw (controller firmware 1.66+ / 2.17+) | 0-100, both motors set together |
| `rumble_intensity` (`rumble_intensity_index`) | hid-lenovo-go | Legion Go, Legion Go 2 | off, low, medium, high |

Both live on the controller's HID device (`/sys/bus/hid/drivers/<driver>/<bus>:<vid>:<pid>.<n>/`).
Sources: Linux drivers/hid/hid-msi.c (`rumble_intensity_*_store`, `claw_features_supported`) and
drivers/hid/hid-lenovo-go.c with Documentation/ABI/testing/sysfs-driver-hid-lenovo-go (master,
2026-11-09).

hid-msi writes every value to the controller's flash (`CLAW_COMMAND_TYPE_SYNC_TO_ROM`), so the
action never writes a value that is already set (the app only calls it when the value changes).
Every value is read back; if the controller refuses one, the values from before go back and the
run fails. The first `set` records the original values; `remove` (and uninstall) puts them back.

No knob (yet) on: the ROG Ally family (the hid-asus Ally series with "vibration strength
configuration", v7 2026-10, isn't merged; Handheld Daemon sets it over hidraw), Legion Go S
(hid-lenovo-go-s has none), Steam Deck (hid-steam has none; Steam owns its haptics).

Tests: `sh fixes/controller-rumble/test.sh` (fake HID trees; also goes through gamecove-fix-set).
