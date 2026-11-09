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

The same drive may boot more than one handheld (a Claw, a ROG Ally, a Legion Go S...), and their screens are all `eDP-1`. So nothing here is global: no kernel argument. A modprobe `install` rule runs a small hook right before the Intel GPU driver (`xe`, or `i915`) loads. The hook compares `/sys/class/dmi/id/board_name` with the board the fix was installed on and, only on a match, writes `/sys/module/drm/parameters/edid_firmware` (and `/sys/module/firmware_class/parameters/path` when it is empty). Both are writable module parameters the driver reads when it first probes the screen. On any other board, or if anything is off (file missing, someone else's override or firmware path), the hook does nothing and the driver loads as usual. AMD handhelds never load `xe`/`i915` at all.

| What | Where |
| --- | --- |
| Patched EDID | `/etc/firmware/edid/gamecove-<panel>-30-120.bin` |
| Board and EDID the hook uses | `/etc/gamecove/claw8ex-vrr/edid.conf` (`MS-1T91 eDP-1:edid/<file>`) |
| The hook (shell built-ins only, always exits 0) | `/etc/gamecove/claw8ex-vrr/edid-hook.sh` (from `edid-hook.sh`) |
| modprobe rule | `/etc/modprobe.d/gamecove-claw8ex-vrr.conf`: `install xe /bin/sh <hook> \|\| :; /sbin/modprobe --ignore-install xe $CMDLINE_OPTS` (same for `i915`) |
| Initramfs | `rpm-ostree initramfs-etc --track=` for all four files, so it also works when the driver loads from the initramfs |

It takes effect at the next restart. `remove` undoes all of it, also at the next restart. The boot menu's previous entry always starts without the fix. Changes are recorded in `/var/lib/gamecove/fixes/claw8ex-vrr/manifest`. `install` refuses when another modprobe rule already has an `install` line for `xe`/`i915`.

### Older installs

Before this, the fix set the kernel arguments `drm.edid_firmware=eDP-1:edid/<file>` and `firmware_class.path=/etc/firmware`, which every handheld booting the drive got. `install`, or `status` run as root (`pkexec /usr/libexec/gamecove/gamecove-fix claw8ex-vrr status`), moves an old install to the hook and drops both arguments (the gyro fix keeps `firmware_class.path` if it holds it). Run on a different board, it removes the old install entirely, so the Claw's EDID can never reach another screen; install it again on the Claw. `status` shows `old_kernel_args=yes` until this has happened.

`status` prints `applies` (no on boards other than MS-1T*), `panel`, `validated`, `range` (what the driver sees now), `installed`, `pending`, `old_kernel_args` and `state`. `state` is one of `off`, `restart`, `on`, `unsupported` or `other-override`.

`edid.awk` does the byte work (panel id, range, checks, patch) in POSIX awk.

## Tests

`sh fixes/claw8ex-vrr/tests/test.sh` uses a synthetic EDID shaped like the Claw 8 panel's (`tests/make-edid.sh`). It covers:

- the patch, checked independently in Python
- the roundtrip, including initramfs tracking and no kernel arguments
- the same drive booting a ROG Ally and a Legion Go S (hook changes nothing, install changes nothing), then the Claw again
- the hook leaving someone else's EDID override or firmware path alone
- migrating an old kernel-argument install, on the Claw and on another handheld
- refusals: unknown panel, someone else's override, no rpm-ostree
- undo when the initramfs step fails
- a zero-padded 128-byte EDID

## License

`panels.txt` and the EDID logic (`edid.awk`) derive from Zendo-GIT/Intel-Handheld-and-ARC-GPU-laboratory (MIT, © 2026 ClawLab contributors); the notice is in [LICENSE.ClawLab-MIT](LICENSE.ClawLab-MIT). The rest is GPL-3.0-or-later, like GameCove.
