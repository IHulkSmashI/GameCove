# Device fixes

One folder per fix, each with `fix.json` (its definition: what it changes, how it's undone, who gets it,
Recommended or Optional, and the lifecycle rules that say when it's no longer needed), `fix.sh`
(`install | remove | update | status`, some `set <value>`) and `test.sh` (runs against a fake root, never the
real system). How fixes are chosen, kept current by the nightly audit and removed when the system catches up:
[docs/FIXES.md](../docs/FIXES.md). `python3 tools/fixes/build.py` checks every `fix.json` and regenerates
`app/data/fixes.json`, the README table and the catalogue in docs/FIXES.md; folders named `advice-*` hold only a
`fix.json` (text for a must-fix problem with no software fix), and `quiet` is GameCove's own behaviour.
 They run as root through
`packaging/libexec/gamecove-fix` (admin password; every install, the small file fixes included) or, for the everyday
settings, `gamecove-fix-set` (no password; day-to-day settings only, see docs/SYSTEM.md "GameCove's root actions"). What each fix is for, who gets it automatically and the
research behind it: each `fix.json` (built into `app/data/fixes.json`) and [docs/DEVICE-FIXES.md](../docs/DEVICE-FIXES.md).

| Fix | Devices | What it fixes | Kind |
| --- | --- | --- | --- |
| `claw8ex-buttons` | Claw 8 EX | MSI face buttons | InputPlumber override (admin) |
| `claw8ex-vrr` | Claw 8 EX, 8 AI+ (same panel); A1M, 7 AI+ (optional) | VRR down to 30 Hz | EDID override (admin, restart; Bazzite and SteamOS) |
| `claw8ex-gyro` | Claw 8 EX | Gyro | HID-BPF + ISH firmware (admin, cold boot) |
| `claw-kbd-wakeup` | every MSI Claw | volume buttons wake it from sleep | udev rule |
| `claw-wifi-d3cold` | every Intel Claw (optional) | Wi-Fi gone after sleep | udev rule |
| `ax210-d3cold` | every row with an AX210 (auto: WIN 5, AYANEO 2 / 2S), any handheld (optional) | AX210 Wi-Fi dead after sleep | udev rule (Bazzite: os-fixed up to 45.20261105, rule reverted 2026-11-08) |
| `gpd-fingerprint` | WIN 4, WIN Max 2 | sleep broken by the fingerprint reader | udev rule (Bazzite: os-fixed) |
| `gpd-wm2-touch-wakeup` | WIN Max 2 (optional) | wakes again right after sleeping | udev rule |
| `ally-controller-wakeup` | Ally X, Xbox Ally, Xbox Ally X, X20 (controller 0b05:1b4c) | stick bumps wake it | udev rule (Bazzite: os-fixed) |
| `ally-fingerprint-drain` | Ally, Ally X; Xbox Allys (optional) | battery drain while off | udev rule (Bazzite: os-fixed) |
| `ally-mcu-powersave` | every ROG Ally (optional) | drain while asleep | udev rule + sysfs |
| `onexfly-touch` | OneXFly F1; OneXPlayer 2 / 2 Pro / X1 A / X1 mini, AOKZOE A1 / A1 Pro (optional) | touch turned 90° in Gaming Mode | gamescope-session file |
| `journal-flood` | any handheld with steamos-manager but no steamos-log-submitter (optional; Bazzite) | split-lock lines flood the journal and wipe older boots | systemd drop-in (SteamOS: not needed) |
| `overlay-power` | every Intel handheld (optional) | 0.0 W for the CPU in the performance overlay (RAPL counter root-only) | tmpfiles.d rule + sysfs mode |
| `fan`, `charge-limit` | see devices.json | fan presets, charge limit (Power page) | sysfs |
| `controller-led`, `controller-rumble` | handhelds with the kernel LED / rumble-strength attributes | lights and rumble strength (Controller settings) | sysfs, no password |

## File fixes (`lib/gcfix.sh`)

The udev and session-file fixes share `lib/gcfix.sh`. A fix's devices come from its trait selectors
in its `fix.json` (built into `app/data/fixes.json`) (`DEVICES="@"`: `lib/fix-devices.txt`, generated with `lib/devices.txt` by
`tools/fixes/gen_handhelds.py`; the handheld's id is looked up from DMI in `lib/devices.txt`), the
files it writes, and four small functions: `file_text`, `hw_present`, `os_fixed`, `apply_now`.

- `install` (= `set on`): only on the listed handhelds (else exit 2); "not needed" (exit 0, nothing
  written) when the system already does it or the part isn't there; writes the file with a
  `# GameCove fix <name>` first line (never over someone else's file), reloads udev, applies the
  value at once and saves the original.
- `remove` (= `set off`): deletes only its own file, writes the saved values back.
- `update`: only when installed. Rewrites the files from this revision of the script (`REVISION=`, the same
  number as `revision` in `fix.json`); if a file can't be written or the fix's `verify` says no, every file,
  the saved values and the record go back as they were and it exits 1. (The three Claw 8 EX fixes change boot
  configuration, so their `update` takes the old version out by its own record and puts this one in.)
- `status`: `applies=`, `installed=`, `os_fixed=` (the probe: the system does it by itself), `hw=`,
  `revision=` (and `installed_revision=`), then `state=` one of `on`, `off`,
  `os-fixed` (the OS ships the same rule, or the value is already right without us), `not-needed`,
  `partial`, `n/a`.
- Every rule also matches the DMI ids itself (`gc_rule_lines`: one line per DMI alternative of
  every handheld the fix resolves to), so one drive booting several handhelds applies a fix only on
  handhelds that share the part.
- One run at a time (`/run/gamecove-<name>.lock`); changes logged to
  `/var/lib/gamecove/fixes/<name>/changes.log` and gamecove-fix's log.

Tests: `fixes/<name>/test.sh` with `lib/tests/gcfix-testlib.sh` (`t_common` checks install,
idempotence, update, remove, set on/off, foreign files, os-fixed, other handhelds, no DMI); `lib/test.sh`
proves update's rollback with a throwaway fix.
