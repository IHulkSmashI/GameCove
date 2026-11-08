# claw8ex-vrr: 30-120 Hz VRR on the Claw's screen

The Claw 8 AI+ / 8 EX AI+ panel refreshes down to 30 Hz, but its EDID announces 48-120 Hz. Below 48 fps the GPU driver then holds each frame for a whole 48 Hz refresh, which judders. This fix gives the driver a corrected EDID with a 30-120 Hz range. It's the Linux version of the Intel VRR range fix (Zendo-GIT/Intel-Handheld-and-ARC-GPU-laboratory, MIT), ported from ClawDeck. Bazzite only for now.

```
gamecove-fix claw8ex-vrr install    # then restart
gamecove-fix claw8ex-vrr status
gamecove-fix claw8ex-vrr remove     # then restart
```

## Safety rule

It only patches the exact factory EDIDs listed in `panels.txt` (matched by sha256), and only the range bytes:

- base block bytes 95/96
- on the Claw 8 panel, DisplayID bytes 142/143
- the checksums: each block's, plus the DisplayID section checksum that Linux validates

The patched EDID is checked again (range, all checksums, nothing else changed) before it's written. Any other panel or EDID is refused, and so is a system where another EDID override or another `firmware_class.path` is already set.

## What it changes

| What | Where |
| --- | --- |
| Patched EDID | `/etc/firmware/edid/gamecove-<panel>-30-120.bin` |
| Initramfs | `rpm-ostree initramfs-etc --track=<that file>`, so the GPU driver has it at its first probe |
| Kernel arguments | `firmware_class.path=/etc/firmware` (shared with `claw8ex-gyro`, removed only when neither fix needs it) and `drm.edid_firmware=eDP-1:edid/<file>` |

It takes effect at the next restart. `remove` undoes all three, also at the next restart. The boot menu's previous entry always starts without the fix. Changes are recorded in `/var/lib/gamecove/fixes/claw8ex-vrr/manifest`.

`status` prints `panel`, `validated`, `range` (what the driver sees now), `installed`, `pending` and `state`. `state` is one of `off`, `restart`, `on`, `unsupported` or `other-override`.

`edid.awk` does the byte work (panel id, range, checks, patch) in POSIX awk.

## Tests

`sh fixes/claw8ex-vrr/tests/test.sh` uses a synthetic EDID shaped like the Claw 8 panel's (`tests/make-edid.sh`). It covers:

- the patch, checked independently in Python
- the roundtrip, including kernel arguments and initramfs tracking
- refusals: unknown panel, someone else's override, no rpm-ostree
- undo when the initramfs step fails
- a zero-padded 128-byte EDID
