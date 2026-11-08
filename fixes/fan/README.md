# fan

Fan presets for handhelds with the `msi_wmi_platform` kernel driver (MSI Claw). Quiet keeps the fans off at idle and ramps gently (warmer chip, may lower clocks in long heavy sessions); Max runs both fans flat out (cool and loud); Auto hands control back to MSI's firmware.

Used only when steamos-manager doesn't offer fan control (`FanControl1`, Steam Deck) — PowerStation has no fan interface.

The driver gives two fans (`pwm1` CPU, `pwm2` GPU), each a six-point table `pwmN_auto_point1..6_pwm` (0-255) and `pwmN_enable` (1 = follow the table, 2 = MSI automatic). Only duty values are written, never the temperature points.

| Mode | Duty per point (EC %) |
| --- | --- |
| `auto` | MSI's own control (`pwmN_enable = 2`) |
| `quiet` | 0 40 40 45 60 75 |
| `max` | 100 x 6 |

Presets are ClawDeck's known-good Claw tables (from MSI's own GamingWidget presets). They must match `FAN_TABLES` in `app/scripts/device/power.gd`.

| Command | What it does |
| --- | --- |
| `install` | Records every fan's table and enable flag in `/var/lib/gamecove/fixes/fan/original` |
| `set auto\|quiet\|max` | Applies the mode (installs first) and checks the enable flag reads back |
| `status` | Prints `installed=` and each fan's enable flag and table |
| `remove` | Writes the recorded tables and flags back and forgets them |

Every change is appended to `/var/lib/gamecove/fixes/fan/changes.log`. GameCove calls it as `pkexec /usr/libexec/gamecove/gamecove-fix fan set quiet` and reads the tables back from sysfs.

Test (fake sysfs, never the real one): `sh fixes/fan/test.sh`. `GAMECOVE_ROOT` is the filesystem prefix.
