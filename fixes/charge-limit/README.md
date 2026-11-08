# charge-limit

Stops charging at a set level (50-100 %) so the battery lasts more years. Costs: a little less play time per charge.

Used only when neither steamos-manager (`BatteryChargeLimit1.MaxChargeLevel`) nor PowerStation offers a charge limit. On the MSI Claw 8 EX steamos-manager reports -1, so GameCove writes the kernel's `charge_control_end_threshold` itself (ClawDeck tested it on the Claw 8 EX: 0 = no limit, accepts 80, back to 0).

| Command | What it does |
| --- | --- |
| `install` | Records the current limit in `/var/lib/gamecove/fixes/charge-limit/original` |
| `set <50-100>` | Sets the limit (installs first). 100 = no limit: the recorded value when it was the firmware's "none" (0 on the Claw) |
| `status` | Prints `installed=`, `original=`, `path=`, `value=` |
| `remove` | Writes the recorded value back and forgets it |

Every change is appended to `/var/lib/gamecove/fixes/charge-limit/changes.log`. GameCove calls it as `pkexec /usr/libexec/gamecove/gamecove-fix charge-limit set 80` and reads the value back from sysfs.

The limit lives in the battery controller; whether it survives a reboot depends on the firmware. GameCove puts your saved limit back at start when the value read differs.

Test (fake sysfs, never the real one): `sh fixes/charge-limit/test.sh`. `GAMECOVE_ROOT` is the filesystem prefix.
