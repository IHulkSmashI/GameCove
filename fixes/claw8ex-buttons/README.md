# claw8ex-buttons: the MSI face buttons on the Claw 8 EX AI+

On a stock Bazzite, the two MSI buttons beside the screen do nothing. This fix makes the left one open the Steam menu and the right one open Quick Access (the Steam Deck's left/right convention). It also maps the M1/M2 back buttons. Board `MS-1T91` only. Ported from ClawDeck.

```
gamecove-fix claw8ex-buttons install
gamecove-fix claw8ex-buttons status
gamecove-fix claw8ex-buttons remove
```

## Why they don't work

Measured on a Claw 8 EX with BIOS E1T91IMS.10D and InputPlumber 0.82.0:

- The right button sends `KEY_F15`.
- The left button sends Win+G, which arrives as a bare `G`.

InputPlumber's stock map for the board (`claw2`) waits for the chord F15+G and for F16, which never happen, so both buttons are dropped.

## What it changes

| What | Where |
| --- | --- |
| Capability map `gamecove_claw8ex` (Guide = G, QuickAccess = F15, M1/M2 paddles) | `/etc/inputplumber/capability_maps.d/gamecove_claw8ex.yaml` |
| The board's device config pointing at that map | `/etc/inputplumber/devices.d/50-msi_claw8_ex_ai_cg3em.yaml` |

InputPlumber reads `/etc` before `/usr/share`, and the fix restarts it afterwards.

The device override is shared with `claw8ex-gyro`. Neither fix edits it in place: `claw8ex-common.sh` rebuilds it from the stock file plus whichever features are on (`/var/lib/gamecove/inputplumber/`). Removing one fix therefore keeps the other's part, and when both are gone the file is deleted. An override someone else wrote is never touched, so install refuses.

If a future InputPlumber ships its own map for the board (anything other than `claw2`), install reports "not needed" and changes nothing.

Changes are recorded in `/var/lib/gamecove/fixes/claw8ex-buttons/manifest`, and `remove` undoes them.

`fixes/lib/claw8ex-common.sh` holds the code all three Claw 8 EX fixes share: the change record and undo, the kernel-argument holder count, and the InputPlumber override.

## Tests

`sh fixes/claw8ex-buttons/tests/test.sh` runs against a fake root with stub commands. `tests/lib.sh` is the harness the other two fixes' tests use too.
