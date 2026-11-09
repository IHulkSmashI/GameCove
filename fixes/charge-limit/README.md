# charge-limit

Stops charging at a set level (50-100 %) so the battery lasts more years. Costs: a little less play time per charge.

Used only when neither steamos-manager (`BatteryChargeLimit1.MaxChargeLevel`) nor PowerStation offers a charge limit: the MSI Claw 8 EX (steamos-manager reports -1) and the rows of `devices.json` with `charge_limit_via: "sysfs"` (OneXPlayer, AYANEO).

| Battery control | Devices | How |
| --- | --- | --- |
| `charge_control_end_threshold` | MSI Claw 8 EX, OneXPlayer (oxpec 6.16+) | The firmware stops at the level by itself. ClawDeck tested the Claw 8 EX: 0 = no limit, accepts 80, back to 0. |
| `charge_behaviour` (`auto` / `inhibit-charge` only) | AYANEO (ayaneo-ec) | The firmware can't stop at a level. `set N` remembers N in `/var/lib/gamecove/fixes/charge-limit/limit` and holds charging (`inhibit-charge`) only while the charger is in and the battery is at N % or more; otherwise `auto`. GameCove runs `set N` again when the charger or the level crosses that line (its 15 s charger check; a single sysfs read when nothing changed). Unplugging always goes back to `auto`, so another session (Steam, Desktop) never finds a battery that won't charge; `remove` also leaves `auto`. |

| Command | What it does |
| --- | --- |
| `install` | Records the current limit in `/var/lib/gamecove/fixes/charge-limit/original` |
| `set <50-100>` | Sets the limit (installs first). 100 = no limit: the recorded value when it was the firmware's "none" (0 on the Claw) |
| `status` | Prints `applies=`, `mode=` (threshold or behaviour), `installed=`, `original=`, `path=`, `value=` (behaviour: also `limit=`, `behaviour=`, `capacity=`, `ac=`), then `state=` |
| `remove` | Writes the recorded value back and forgets it (and deletes the udev rule) |
| `set release` | Behaviour mode: lets the battery charge now (`auto`), keeps the limit for next time. GameCove's session runs it when GameCove exits (`post_client_shutdown`, through `gamecove-fix-set`, no password). Threshold mode: nothing to do |
| `guard` | Run by udev on every `power_supply` add/change, boot included: in behaviour mode holds charging only while GameCove runs and the battery is at the limit on the charger, else `auto`. Writes only when the value differs |

Behaviour mode's install also writes `/etc/udev/rules.d/90-gamecove-charge-limit.rules` (runs `guard`), so a crash, Steam's session or the desktop never find a battery that won't charge.

Only acts on the handhelds in `fixes/lib/handhelds.txt` (generated from `devices.json` by `tools/fixes/gen_handhelds.py`): MSI and ASUS laptops share these battery drivers, so on anything else `status` says `applies=no` and `set` exits 2. One run at a time (`/run/gamecove-charge-limit.lock`).

Every change is appended to `/var/lib/gamecove/fixes/charge-limit/changes.log`. GameCove calls it as `pkexec /usr/libexec/gamecove/gamecove-fix-set charge-limit set 80` (no password) and reads the value back from sysfs.

The limit lives in the battery controller; whether it survives a reboot depends on the firmware. GameCove puts your saved limit back at start when the value read differs.

Test (fake sysfs, never the real one): `sh fixes/charge-limit/test.sh`. `GAMECOVE_ROOT` is the filesystem prefix.
