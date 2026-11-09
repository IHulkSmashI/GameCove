# fan

Fan presets for handhelds whose fan driver has no service of its own. **Auto** hands control back to the firmware. **Max** runs the fans flat out (cool and loud). **Quiet** (only where the driver has fan tables) keeps the fans off or slow at idle and ramps gently: a warmer chip, and it may lower clocks in long heavy sessions.

Used only when steamos-manager doesn't offer fan control (`FanControl1`, Steam Deck). PowerStation has no fan interface. Which driver a handheld uses is its `fan` field in `app/data/devices.json` (`fan_via: "fix"` means this fix drives it).

| hwmon `name` | Devices | Control | Modes |
| --- | --- | --- | --- |
| `msi_wmi_platform` | MSI Claw | Two fans, six-point duty tables `pwmN_auto_point1..6_pwm`; `pwmN_enable` 1 = table, 2 = MSI automatic. Temperatures untouched. | quiet, auto, max |
| `asus_custom_fan_curve` | ROG Ally family | `pwm1` CPU, `pwm2` GPU (`pwm3` mid fan if present), eight points `_temp` (°C) and `_pwm`; `pwmN_enable` 1 = custom curve, 2 = factory curve | quiet, auto, max |
| `oxp_ec` | OneXPlayer, AOKZOE (oxpec, kernel 6.16+) | `pwm1` 0-255; `pwm1_enable` 0 = full, 1 = manual, 2 = EC automatic | auto, max |
| `oxpec` | Same, older oxp-sensors driver | `pwm1_enable` 0 = EC automatic, 1 = manual | auto, max |
| `ayaneo_ec` | AYANEO (ayaneo-ec) | `pwm1` 0-255; `pwm1_enable` 1 = manual, 2 = automatic | auto, max |
| `gpdfan` | GPD (gpd-fan, 6.18+) | `pwm1` 0-255; `pwm1_enable` 0 = full, 1 = manual, 2 = EC automatic | auto, max |
| `zotac_*` | ZOTAC Zone (out-of-tree `zotac_zone_platform`) | Standard hwmon ABI assumed (1 = manual, 2 = automatic). **Unverified on hardware**; every write is read back. | auto, max |

No fixed "quiet" duty on the one-duty drivers: without a curve, a low fixed speed could overheat the chip under load. The fix refuses `set quiet` there (exit 2) and GameCove doesn't offer it.

| Driver | Mode | Duty per point (%) |
| --- | --- | --- |
| `msi_wmi_platform` | quiet | 0 40 40 45 60 75 (ClawDeck's known-good Claw tables, from MSI's own presets) |
| `msi_wmi_platform` | max | 100 x 6 |
| `asus_custom_fan_curve` | quiet | at 30 40 50 60 70 80 90 100 °C: 2 5 17 35 55 75 75 75 (Handheld Daemon's minimum curve up to 50 °C, its default curve above) |
| `asus_custom_fan_curve` | max | 100 x 8 |

The tables must match `FAN_DRIVERS` in `app/scripts/device/power.gd` (`packaging/tests/run.sh` checks the driver list and modes). On ASUS, changing the platform profile puts the factory curve back; GameCove re-applies the saved preset at start.

| Command | What it does |
| --- | --- |
| `install` | Records the driver and every fan's tables, duty and enable flag in `/var/lib/gamecove/fixes/fan/original` |
| `set auto\|quiet\|max` | Applies the mode (installs first) and checks the values read back |
| `status` | Prints `applies=`, `driver=`, `modes=`, `installed=`, each fan's values, then `state=` |
| `remove` | Writes the recorded values back and forgets them |

Every change is appended to `/var/lib/gamecove/fixes/fan/changes.log`. GameCove calls it as `pkexec /usr/libexec/gamecove/gamecove-fix-set fan set quiet` (no password: see docs/CONTRACTS.md, Root actions) and reads the values back from sysfs.

Test (fake sysfs, never the real one): `sh fixes/fan/test.sh`. `GAMECOVE_ROOT` is the filesystem prefix.

Only acts on the handhelds in `fixes/lib/handhelds.txt` (generated from `devices.json` by `tools/fixes/gen_handhelds.py`): MSI and ASUS laptops use the same `msi_wmi_platform` / `asus_custom_fan_curve` drivers, so on anything else `status` says `applies=no` and `set` exits 2. If a `set` fails halfway, every fan goes back to the firmware's automatic control before the error is returned. One run at a time (`/run/gamecove-fan.lock`).
