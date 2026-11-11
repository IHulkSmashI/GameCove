# Fixes: how they are chosen, kept current and removed

GameCove ships workarounds for things that break everyday use on a handheld: sleep and battery
drain while asleep, controls and built-in buttons, sound, the screen, Wi-Fi and Bluetooth, touch,
power and fan control, waking in a bag, charging, starting up. Not every quirk: only must-fix
problems with a proven, reversible workaround.

A workaround is a debt. The day your system fixes the problem itself, GameCove's copy must go, so
this page is as much about removing fixes as about applying them.

- [Recommended and Optional](#recommended-and-optional)
- [One file per fix](#one-file-per-fix)
- [Lifecycle rules](#lifecycle-rules)
- [On the handheld](#on-the-handheld)
- [The nightly audit](#the-nightly-audit)
- [The "fixes" data release](#the-fixes-data-release)
- [Proposing a fix](#proposing-a-fix)
- [Every fix](#every-fix)

The research behind the catalogue (what is broken per model, what each system already fixes, what
was skipped and why) is in [DEVICE-FIXES.md](DEVICE-FIXES.md). The root helper and its two polkit
actions are in [SYSTEM.md](SYSTEM.md#gamecoves-root-actions-polkit).

## Recommended and Optional

Every fix carries one of two badges, in the app, in the installer and in the README table.

| Badge | Means |
| --- | --- |
| **Recommended** | A must-fix problem on your model, a proven workaround, safe, and undone in one press. Preselected in Easy setup. |
| **Optional** | Everything else we offer: it helps only some units, costs something (a little battery asleep), or isn't proven widely enough to switch on for you. Never preselected. |

A second, smaller badge, **Tested on hardware**, shows when we ran that fix on that exact model
ourselves (`tested` in its file: device, date, system). Without it the fix comes from upstream
projects that tested it (Bazzite, InputPlumber, Handheld Daemon and others, linked as sources).

A must-fix problem with no software fix (a BIOS update, a system package that is too old) gets an
**Advice** line instead: text, and GameCove changes nothing.

The same fix can be Recommended on one model and Optional on another: the level follows the
selectors (`auto` = Recommended there, `optional` = Optional there), which pick models by the parts
they share ([DEVICES.md](DEVICES.md), Traits).

## One file per fix

`fixes/<id>/fix.json` is the single source for a fix. `tools/fixes/build.py` checks every file
against [`tools/fixes/fix.schema.json`](../tools/fixes/fix.schema.json) and a few rules a schema
can't say, then generates `app/data/fixes.json` (what the app ships), the README table and the
[catalogue below](#every-fix). CI fails when a fix folder has no definition, no undo, no probe or
no tests, or when a generated file is stale.

| Field | What it holds |
| --- | --- |
| `id`, `revision` | The folder name. `revision` goes up (with `REVISION=` in `fix.sh`) whenever what the fix writes changes. |
| `title`, `line`, `symptom`, `why` | The words the app shows: a name, one plain line, what is broken, which shared part makes it apply. |
| `kind` | `file` (one udev rule or session file, built on `fixes/lib/gcfix.sh`), `root` (boot configuration, firmware, services), `power` (a day-to-day setting, no lifecycle), `app` (GameCove's own behaviour), `advice` (text only). |
| `level`, `must_fix`, `breaks` | `recommended` or `optional`; whether it is a must-fix problem; which core function it restores (`sleep`, `controls`, `sound`, `screen`, `wireless`, `touch`, `power`, `charging`, `session`). |
| `default` | `on` (Recommended: preselected), `suggested-off` (Optional), `advice-only`. |
| `risk`, `risk_note` | `low`, `medium` or `high`, and why in a sentence. A high-risk fix can't be Recommended. |
| `auto`, `optional`, `exclude` | Trait selectors: where it is Recommended, where Optional, and models that have the part but mustn't get it (with the reason). The built file adds `devices`: the same, resolved to models and their DMI ids. |
| `changes` | Exactly what it touches: each file, udev rule, sysfs node, kernel argument, initramfs entry, firmware file or service. |
| `undo` | How `remove` puts it back. |
| `tested` | Hardware we ran it on: device, date, system. |
| `bazzite`, `steamos` | Whether the shipping systems fix it themselves today. |
| `sources` | Where the problem and the workaround come from. |
| `lifecycle` | `needed_when`, `obsolete_when`, `probe`, `both_active`: see the next section. |
| `watch` | What the nightly audit follows for this fix. |
| `withdrawn` | `null`, or `{date, reason}`: the kill switch. |
| `audited` | The day a maintainer last checked it against its sources. |

## Lifecycle rules

Two conditions the handheld checks by itself, with no network:

- `needed_when`: the fix only makes sense when this holds (the driver it configures is there, the
  system uses rpm-ostree, ...). Not needed: it isn't offered.
- `obsolete_when`: the system now does it natively. Not offered; and if GameCove installed it,
  GameCove takes it out.

A condition is one of these, or `all` / `any` / `not` over them:

| Condition | True when |
| --- | --- |
| `{"kernel": ">=6.19"}` | the running kernel is at least that version |
| `{"os": "bazzite", "version": ">=45"}` | os-release says that system (and image version, when given) |
| `{"bios": ">=E1T91IMS.110", "scheme": "msi"}` | the BIOS is at least that version, compared the maker's way |
| `{"ec": ">=1.20"}` | the EC firmware release is at least that |
| `{"tool": "inputplumber", "version": ">=0.70"}` | that package is installed at that version (rpm or pacman) |
| `{"file": "/usr/lib/udev/rules.d/50-x.rules"}`, `{"sysfs": "/sys/..."}` | the path exists |
| `{"file_contains": {"path": ..., "text": ...}}`, `{"sysfs_value": {"path": ..., "equals": ...}}` | the file holds that text / that value |
| `{"module": "hid_msi"}`, `{"module_param": {"module": ..., "param": ..., "equals": ...}}` | the driver is loaded / its parameter exists (or has that value) |
| `{"probe": "os_fixed"}` | the fix's own probe found the system doing it (below) |

Each answers yes, no or **unknown** (a version that can't be read, a rule from a newer GameCove).
Unknown never makes GameCove act.

**The probe.** Where nobody can name the kernel or system version that fixes a problem, the device
looks for itself: `fix.sh status` is read-only, runs without a password, and prints `os_fixed=yes`
when the problem is gone without GameCove (the same udev rule shipped by the system, the sysfs
value already right, InputPlumber's stock file naming its own map, the panel's own EDID already
going down to 30 Hz). Every fix that installs something has one; `probe.what` says in plain words
what it looks at.

`both_active` says what happens if the system's fix and GameCove's are both in place: `harmless`
(the same setting written twice) or `conflict` (GameCove's copy would shadow the system's, as an
InputPlumber override does).

## On the handheld

`app/scripts/device/fixes.gd` runs the lifecycle; `fix_conditions.gd` evaluates rules,
`fix_lifecycle.gd` decides, `fix_data.gd` loads definitions.

**When.** At session start, and after a system update: GameCove remembers the kernel, system
image, BIOS and EC versions and looks at every fix again when one changed. Never on a timer, and
never while a game runs: a pass asked for during a game runs when the game ends. A normal start
only asks the fixes GameCove installed for their status, so a handheld with none pays nothing.

**What.** For each fix GameCove itself installed (the helper's `installed=yes`, which reads the
fix's own record and marker):

1. **Withdrawn** in the definitions, or **the system does it now** (`obsolete_when` is yes): the
   fix's own `remove` runs. It deletes only GameCove's files and writes the saved values back, but only to a node that still holds the value the fix set (`set` in the fix's state folder): when the system or the user has written another since (an OS update that fixes it itself), that value stays and is logged as kept.
   GameCove then asks the fix for its status again; only `installed=no` counts as removed.
2. **A newer revision** of the fix came with a GameCove update: `update` runs. For `file` fixes
   the helper first saves every file, the saved values and the record, writes the new version,
   checks it, and on any failure puts every file, the saved values and the record back exactly as
   they were (`gc_update` in `fixes/lib/gcfix.sh`). The three `root` fixes change boot configuration, so there is no swap in
   place: the old version is taken out by its own record, then the new one goes in; if that fails,
   the fix's own undo leaves the system stock (never half of each) and GameCove says so.
3. Otherwise nothing.

Then GameCove says it once, in plain words ("Your system now takes care of "Sticks don't wake it"
itself, so GameCove removed its workaround."), writes it to **History** on the Fixes page, and
records the fix as undone so a later repair or update of GameCove doesn't put it back.

**What it never does.**

- Touch anything GameCove didn't install. A rule, EDID override or InputPlumber file someone else
  set up has no GameCove record and no marker; `remove` skips it.
- Act on unknown, on a definition with another schema version, or on a download whose signature
  cosign didn't accept on this device.
- Use anything but the existing root helper: `pkexec gamecove-fix <name> remove|update`, the same
  administrator-password action as Apply and Undo. No new polkit action, daemon or timer.
- Act during a game.

**Gaming Mode.** GameCove's own session has no polkit agent, so nothing can ask for the password
there, and GameCove adds no new root action to get round that. The change then waits: the fix shows
"Your system does this itself now" with **Remove now**, and the removal runs the next time GameCove
starts in Desktop Mode (or when you press the button there). Until then both are in place:

- `harmless` (the same udev rule or sysfs value written twice): said once, as a toast.
- `conflict` (GameCove's copy would shadow the system's fix): first the existing no-password path
  takes ours out of the way where it can. The Claw 8 EX's InputPlumber override is rebuilt by
  `gamecove-fix-set claw8ex-buttons set refresh` at every start where InputPlumber's stock file
  changed, and that rebuild keeps InputPlumber's own capability map once the stock file names one
  (`ip_render` in `fixes/lib/claw8ex-common.sh`), so a fixed InputPlumber is used at once and our
  two files only wait to be deleted. The fix's status then says `conflict=no` and the wait is said
  once like a harmless one. Where nothing can step aside (`conflict=yes`, or a fix without that
  line, such as the gyro's firmware), GameCove shows it over the home screen at **every start**
  ("Our MSI buttons fix is in your system's way", with Open Fixes, or Remove now in Desktop Mode),
  the card on the Fixes page turns red ("In your system's way") and the summary counts it, until it
  is out or you keep it.
- A **withdrawn** fix still in place is shown the same way at every start, with the reason.

The pass waits for the no-password rebuild to finish before it judges, so a clash it settles is
never shown.

**Keep the workaround anyway.** Every automatic removal in History has this button. It applies the
fix again (when the fix itself still thinks it is needed) and GameCove stops removing it by
itself. Undo on the fix lifts that again.

## The nightly audit

The data repo's workflow ([GameCove-data](https://github.com/IHulkSmashI/GameCove-data),
`.github/workflows/fixes.yml`) runs `tools/fixes/audit.py` every night, from the GameCove commit its
`gamecove-source.env` pins. For every fix it fetches the `watch` entries and compares each with what it
saw the night before (a signed snapshot kept on the "fixes" release).

| Watch | What is compared |
| --- | --- |
| `github-file` | whether a file exists in a repository and its content hash (a Bazzite udev rule) |
| `github-commits` | the newest commit touching a path (a kernel driver, an InputPlumber config) |
| `github-release` | the newest release of a project (InputPlumber, Handheld Daemon, Bazzite) |
| `github-issue` | an issue's or pull request's state (open, closed, merged) |
| `gitlab-tags` | the newest tag (linux-firmware) |
| `kernel-releases` | kernel.org's mainline, stable and longterm versions |
| `firmware-index` | the newest BIOS / EC the maker lists, from GameCove's own nightly firmware index |
| `lore` | the newest kernel mailing-list message matching a search |
| `url` | a page's content hash (release notes, a maker or wiki page) |

`tools/fixes/audit.json` adds watches that concern every fix: kernel releases, Bazzite, SteamOS,
InputPlumber, Handheld Daemon, gamescope-session and linux-firmware.

**What it decides alone.** Only what a rule already declares:

- A `github-file` watch with `records` (say, Bazzite's own rule file: present = fixed) updates the
  fix's "Bazzite today" state in the published data when the file appears or goes.
- For every `kernel` version named in an `obsolete_when`, it records whether that kernel is
  released and whether the newest Bazzite ships it.
- It stamps every fix with the day it was last audited.

It never writes or changes a rule. Fetched pages are data: nothing in them is run or copied into
rule fields, and what goes into an issue is a short, escaped summary.

**What it leaves to a person.** Everything else. When a watch changed, the audit writes it into
`issues.json` (signed, on the same release), and this repo's `.github/workflows/fix-audit.yml` checks
that signature and opens or updates **one issue per fix** here (label `fix-audit`) saying what changed, with links, and one summary
issue per night with changes. A maintainer reads the change and, when it means the problem is
fixed upstream, adds the rule (`{"kernel": ">=..."}`, `{"os": ..., "version": ...}`) or withdraws
the fix, and sets `audited`. The next nightly release carries it to every handheld.

A weekly job (`fix-audit.yml`) checks that every `https://` source and watch link still answers and
reports dead ones in one issue. `tools/fixes/audit.py --fixtures <dir>` runs the whole audit from recorded
answers (the tests and a dry run use it).

## The "fixes" data release

The audit's output, `fixes.json`, is the bundled definitions plus what the audit recorded, signed
with cosign keyless by GameCove-data's `fixes.yml` on `main` and published on that repo's rolling
`fixes` release (`app/scripts/system/data_repo.gd` names the repo and the signer; a fix definition
reaches it only once `gamecove-source.env` there is bumped to a GameCove commit that has it). Like the firmware and upscaler indexes, two jobs: one
fetches with a read-only token and no signing identity, the other only checks the artifact, signs
it and uploads it, in the `nightly` environment.

On the handheld (at most once a day, at session start, behind **Background lookups**; see
[PRIVACY.md](PRIVACY.md)):

- The file is used only when cosign, on the device, proves it was signed by that workflow on
  `main`. No cosign, a bad signature, another schema version, or a file older than the one already
  held: it is dropped and the definitions built into GameCove stay in charge. Offline devices
  simply keep those.
- It is data. It can change a known fix's lifecycle rules, words, sources and audit notes,
  **withdraw** a fix (`withdrawn`: every handheld takes it out at its next pass and stops offering
  it), and add advice lines. It can't add or change anything that runs as root, who a fix is
  offered to, its kind or its password rule: those come only with GameCove itself.
- A fix whose script must change ships with a GameCove release (a higher `revision`); the release
  only tells older installs that a newer version exists.

## Proposing a fix

1. It must be a must-fix problem (see the top of this page), with a workaround that is proven
   somewhere we can link, and that can be undone completely.
2. Add `fixes/<id>/` with `fix.sh` (`install | remove | update | status`; for one udev rule or
   config file, build on `fixes/lib/gcfix.sh`: about 40 lines), `test.sh` (runs against a fake
   root, never the real system) and `fix.json`. [fixes/README.md](../fixes/README.md) describes the
   script side.
3. In `fix.json`: say exactly what it changes and how it's undone; pick models with trait
   selectors, not model names, so siblings get it too; give it an `os_fixed` probe and every rule
   you know for when it becomes unnecessary; add `watch` entries for where a real fix would land
   (the kernel file, the Bazzite rule folder, the upstream issue). Leave `tested` empty unless you
   ran it on that model; say which model you did run it on in the pull request.
4. New fixes start as **Optional** unless a maintainer has it on hardware or the same change is
   already shipped by a system for that model.
5. Run `python3 tools/fixes/build.py`, `python3 tools/fixes/gen_handhelds.py`, the fix's `test.sh`
   and `sh packaging/tests/run.sh`.

## Every fix

Generated from the `fix.json` files by `tools/fixes/build.py`; do not edit below this line.

<!-- fixes:catalogue:start -->
### claw8ex-buttons

**MSI buttons** · Recommended · restores: controls and built-in buttons · risk: low · revision 1 · last audited 2026-11-10

Makes the two MSI buttons next to the screen work: left opens the menu, right opens Quick Access. Both MSI face buttons do nothing in Gaming Mode: the firmware sends Win+G and F15, InputPlumber's stock map waits for other keys.

- Recommended on: MSI Claw 8 EX AI+
- Changes (file): `/etc/inputplumber/capability_maps.d/gamecove_claw8ex.yaml`. A button map: Guide = G, Quick Access = F15, M1/M2 back buttons.
- Changes (file): `/etc/inputplumber/devices.d/50-msi_claw8_ex_ai_cg3em.yaml`. A copy of InputPlumber's own file for this board that points at the map above (rebuilt when the stock file changes).
- Changes (service): `inputplumber.service`. Restarted once so it reads the new files.
- Undo: Deletes both files and restarts InputPlumber, which then reads its stock files again.
- Risk: Only adds two InputPlumber files in /etc; the stock files are never edited.
- Tested on hardware: MSI Claw 8 EX AI+ (Bazzite, 2026-11-09)
- Bazzite: Not fixed (InputPlumber still maps the board to claw2). SteamOS: Not supported on SteamOS.
- Needed when: `{"file": "/usr/share/inputplumber/devices/50-msi_claw8_ex_ai_cg3em.yaml"}`
- Not needed any more when: `{"probe": "os_fixed"}`
- Probe: Reads InputPlumber's own capability map for this board and checks it takes what this firmware sends (Guide from G or Win+G, Quick Access from F15 alone), from the map itself, not its name. Until ours is removed, the no-password rebuild keeps InputPlumber's map in the override, and conflict=no says ours stands aside.
- With the system's own fix also active: they would conflict, so GameCove's copy must go
- Watches (github-commits): ShadowBlip/InputPlumber `rootfs/usr/share/inputplumber/devices/50-msi_claw8_ex_ai_cg3em.yaml`. The stock config our override shadows: a new capability_map_id means it's fixed upstream.
- Watches (github-release): ShadowBlip/InputPlumber. A release may carry the fix.
- Watches (firmware-index): msi-claw-8-ex. A BIOS that sends other keys for the MSI buttons changes what the map must wait for.
- Sources: <https://github.com/ShadowBlip/InputPlumber/blob/main/rootfs/usr/share/inputplumber/devices/50-msi_claw8_ex_ai_cg3em.yaml>; ClawDeck docs/HARDWARE-FINDINGS.md section 12 (measured with evtest on BIOS E1T91IMS.10D)

### claw8ex-vrr

**Smooth screen down to 30 fps** · Recommended · restores: screen · risk: medium · revision 1 · last audited 2026-11-10

Lets VRR keep games smooth down to 30 fps instead of 48. The Claw's panel EDID says 48-120 Hz although the panel does 30-120 Hz, so VRR stops working under 48 fps.

- Recommended on: MSI Claw 8 EX AI+, MSI Claw 8 AI+
- Optional on: MSI Claw 7 AI+, MSI Claw A1M
- Changes (firmware): `/etc/firmware/edid/gamecove-<panel>-30-120.bin`. A copy of the panel's own EDID with only the refresh range changed to 30-120 Hz.
- Changes (file): `/etc/gamecove/claw8ex-vrr/edid.conf`. Which board and connector the EDID is for.
- Changes (file): `/etc/gamecove/claw8ex-vrr/edid-hook.sh`. A tiny board check that runs right before the GPU driver loads.
- Changes (file): `/etc/modprobe.d/gamecove-claw8ex-vrr.conf`. Runs the hook before xe / i915.
- Changes (initramfs): `rpm-ostree initramfs-etc --track`. Bazzite: the four files above, so it also works when the driver loads early. (SteamOS: only offered where the driver starts after /etc is there, so no initramfs step.)
- Changes (kernel-arg): `gamecove.vrr=1`. The switch the hook looks for (plus firmware_class.path=/etc/firmware, shared with the gyro fix). Bazzite: a kernel argument. SteamOS: one marked line in /etc/default/grub, then update-grub.
- Changes (file): `/etc/atomic-update.conf.d/gamecove-claw8ex-vrr.conf`. SteamOS only: keeps the fix's own files and its record (/etc/gamecove/claw8ex-vrr/record, since SteamOS gives every OS slot its own /var) across SteamOS updates (never Valve's grub file); after an update GameCove puts the grub line back without a password.
- Undo: Takes out the boot switch (kernel argument, or the grub line and update-grub on SteamOS), the initramfs entries, the SteamOS keep list and every file, in reverse order. The panel's own EDID is back after a restart.
- Risk: Changes what the Intel GPU driver is told about the panel at boot. Only exact, validated factory EDIDs are patched, and a boot-menu kill switch (gamecove.novrr) skips it.
- Tested on hardware: MSI Claw 8 EX AI+ (Bazzite, 2026-11-09)
- Bazzite: Not fixed. SteamOS: Not fixed. GameCove's fix works on SteamOS too (a grub switch kept across SteamOS updates, as ClawDeck does it); untested on a SteamOS Claw (fake-root tests only).
- Needed when: `{"all": [{"any": [{"file": "/usr/bin/rpm-ostree"}, {"all": [{"os": "steamos"}, {"file": "/etc/default/grub"}]}]}, {"any": [{"module": "xe"}, {"module": "i915"}]}]}`
- Not needed any more when: `{"probe": "os_fixed"}`
- Probe: Reads the panel's own EDID. If it already says 30 Hz or lower (a BIOS that corrected it), nothing is needed. With GameCove's copy in place the factory EDID can't be read, so a BIOS change is checked by a maintainer.
- With the system's own fix also active: harmless (the same setting twice)
- Watches (firmware-index): msi-claw-8-ex. A new BIOS may correct the EDID's range (the factory sha256 in panels.txt then stops matching).
- Watches (firmware-index): msi-claw-8-ai-plus. Same panel in the Claw 8 AI+.
- Watches (github-commits): torvalds/linux `drivers/gpu/drm/drm_panel_backlight_quirks.c`. Panel quirk tables: a kernel quirk for CSW PN8007QB1-2 would replace the EDID override.
- Watches (lore): s:CSW0801 OR s:PN8007QB1. Kernel patches naming the panel.
- Sources: ClawDeck docs/HARDWARE-FINDINGS.md section 11; fixes/claw8ex-vrr/README.md

### claw8ex-gyro

**Gyro aiming** · Recommended · restores: controls and built-in buttons · risk: medium · revision 1 · last audited 2026-11-10

Turns on the motion sensor so you can aim by tilting the Claw. The Claw 8 EX's IMU sits behind the Intel sensor hub with MSI firmware Linux doesn't load, so there is no gyro.

- Recommended on: MSI Claw 8 EX AI+
- Changes (firmware): `/etc/firmware/intel/ish/ish_ptl_<vendor>_<product>.bin`. MSI's sensor-hub firmware under this model's own name, downloaded from MSI and checked by size and sha256.
- Changes (kernel-arg): `firmware_class.path=/etc/firmware`. Adds a firmware search path (shared with the VRR fix).
- Changes (initramfs): `rpm-ostree initramfs-etc --track`. The firmware file, for an early-loading sensor hub.
- Changes (file): `/etc/udev-hid-bpf/`. A HID-BPF program that labels the hub's sensors as accelerometer and gyro.
- Changes (service): `gamecove-claw-gyro-keepalive.service, gamecove-claw-gyro-bias.service`. Keep the sensor powered and correct its drift.
- Changes (file): `/etc/inputplumber/devices.d/50-msi_claw8_ex_ai_cg3em.yaml`. Adds the gyro as a motion source.
- Undo: Stops and removes both services, the HID-BPF program, the firmware file, its initramfs entry and the kernel argument (when the VRR fix doesn't need it), and rebuilds the InputPlumber override without the gyro.
- Risk: Installs MSI's own sensor-hub firmware (downloaded from MSI, checked by sha256) and changes boot configuration. Only loads on this exact board.
- Tested on hardware: MSI Claw 8 EX AI+ (Bazzite, 2026-11-09)
- Bazzite: Not fixed. SteamOS: Not supported on SteamOS.
- Needed when: `{"file": "/usr/bin/rpm-ostree"}`
- Not needed any more when: `{"probe": "os_fixed"}`
- Probe: Looks for a gyro (gyro_3d) that works without GameCove's firmware and HID-BPF program. With the fix in place that can't be told apart, so new linux-firmware and kernel releases are checked by a maintainer.
- With the system's own fix also active: they would conflict, so GameCove's copy must go
- Watches (github-commits): torvalds/linux `drivers/hid/intel-ish-hid`. Kernel sensor-hub driver: native support for the Claw's custom sensors would replace the HID-BPF program.
- Watches (gitlab-tags): kernel-firmware/linux-firmware. linux-firmware may start shipping MSI's Panther Lake ISH firmware (intel/ish/).
- Watches (github-commits): ShadowBlip/InputPlumber `rootfs/usr/share/inputplumber/devices/50-msi_claw8_ex_ai_cg3em.yaml`. The stock config: an imu source there means InputPlumber expects a native gyro.
- Watches (firmware-index): msi-claw-8-ex. A BIOS update can change the sensor hub's firmware needs.
- Sources: fixes/claw8ex-gyro/README.md

### claw-kbd-wakeup

**Volume buttons don't wake it** · Recommended · restores: sleep and battery while asleep · risk: low · revision 1 · last audited 2026-11-10

Stops a bump of the volume buttons from waking the Claw in your bag. The volume buttons are keys on the i8042 keyboard, which is a wakeup source, so pressing them wakes the Claw from sleep.

- Recommended on: MSI Claw 8 EX AI+, MSI Claw 8 AI+, MSI Claw 7 AI+, MSI Claw A1M, MSI Claw A8
- Changes (udev-rule): `/etc/udev/rules.d/60-gamecove-claw-kbd-wakeup.rules`. Switches off wake-up for the built-in keyboard port (serio, atkbd) on MSI MS-1T* boards.
- Changes (sysfs): `/sys/bus/serio/devices/serio*/power/wakeup`. Set to disabled at once; the old value is saved.
- Undo: Deletes the rule and writes the saved value back.
- Risk: One udev rule; the power button still wakes the Claw.
- Tested on hardware: not yet
- Bazzite: Not fixed: Handheld Daemon switched it off at start, InputPlumber (Bazzite 44+) doesn't. SteamOS: Not fixed (no Claw support in SteamOS).
- Needed when: always
- Not needed any more when: `{"probe": "os_fixed"}`
- Probe: Looks for the same rule from the system itself (any udev rule that isn't GameCove's and does the same), or the value already being right without GameCove.
- With the system's own fix also active: harmless (the same setting twice)
- Watches (github-commits): ShadowBlip/InputPlumber `rootfs/usr/lib/udev/rules.d`. InputPlumber's udev rules: it may start switching the keyboard wake-up off, as Handheld Daemon did.
- Watches (github-commits): ublue-os/bazzite `system_files/deck/shared/usr/lib/udev/rules.d`. Bazzite's handheld udev rules: a Claw wake-up rule would make this os-fixed.
- Watches (lore): s:"MSI Claw" s:wakeup. The kernel quirk was refused in 2025-06 in favour of a udev rule; a new attempt would show up here.
- Sources: <https://lkml.iu.edu/hypermail/linux/kernel/2506.2/01805.html>; <https://lkml.indiana.edu/hypermail/linux/kernel/2506.2/03339.html>; <https://github.com/hhd-dev/hhd/blob/master/src/hhd/device/claw/__init__.py>

### claw-wifi-d3cold

**Wi-Fi back after sleep** · Optional · restores: wi-fi and bluetooth · risk: low · revision 1 · last audited 2026-11-10

Keeps the Wi-Fi card awake enough to come back after sleep. Uses a little more battery asleep. Wi-Fi is gone after sleep until a restart: the Intel card drops into D3cold and doesn't come back.

- Optional on: MSI Claw 8 EX AI+, MSI Claw 8 AI+, MSI Claw 7 AI+, MSI Claw A1M
- Changes (udev-rule): `/etc/udev/rules.d/60-gamecove-claw-wifi-d3cold.rules`. Stops Intel network cards on MS-1T* boards from entering D3cold.
- Changes (sysfs): `/sys/bus/pci/devices/<wifi>/d3cold_allowed`. Set to 0 at once; the old value is saved.
- Undo: Deletes the rule and writes the saved value back.
- Risk: One udev rule. The Wi-Fi card uses a little more power while the Claw sleeps.
- Tested on hardware: not yet
- Bazzite: Not fixed (reported 2024-12, no answer). SteamOS: Not fixed (SteamOS issues 2742, 2703; user-verified workaround).
- Needed when: always
- Not needed any more when: `{"probe": "os_fixed"}`
- Probe: Looks for the same rule from the system itself (any udev rule that isn't GameCove's and does the same), or the value already being right without GameCove.
- With the system's own fix also active: harmless (the same setting twice)
- Watches (github-issue): ValveSoftware/SteamOS #2742. The SteamOS report this workaround comes from: closing it usually names the fixed build.
- Watches (github-issue): ValveSoftware/SteamOS #2703. Second SteamOS report.
- Watches (github-commits): torvalds/linux `drivers/net/wireless/intel/iwlwifi/pcie/drv.c`. iwlwifi PCIe resume handling: a kernel fix would make the rule unnecessary.
- Watches (github-commits): ublue-os/bazzite `system_files/deck/shared/usr/lib/udev/rules.d`. Bazzite's handheld udev rules.
- Sources: <https://github.com/ValveSoftware/SteamOS/issues/2742>; <https://github.com/ValveSoftware/SteamOS/issues/2703>; <https://universal-blue.discourse.group/t/wifi-refuses-to-reconnect-after-resuming-from-sleep/5519>

### ax210-d3cold

**Intel AX210 Wi-Fi after sleep** · Recommended · restores: wi-fi and bluetooth · risk: low · revision 1 · last audited 2026-11-10

Stops the Intel AX210 Wi-Fi card from crashing after sleep. The AX210 enters D3cold during sleep, iwlwifi can't wake it, Wi-Fi is dead (sometimes even after a restart).

- Recommended on: AYANEO 2S, AYANEO 2, GPD WIN 5
- Optional on: Any handheld with the part
- Changes (udev-rule): `/etc/udev/rules.d/60-gamecove-ax210-d3cold.rules`. Stops the Intel AX210 (8086:2725) from entering D3cold.
- Changes (sysfs): `/sys/bus/pci/devices/<ax210>/d3cold_allowed`. Set to 0 at once; the old value is saved.
- Undo: Deletes the rule and writes the saved value back.
- Risk: One udev rule, the same one Bazzite ships.
- Tested on hardware: not yet
- Bazzite: Fixed up to stable 45.20261105 (50-intel-ax200-ax210-disable-d3cold-state.rules, after issue 5867). Bazzite reverted that rule on 2026-11-08 (in testing and unstable 45.20261110), so later builds need ours again; the fix checks the system's own rules. SteamOS: Not shipped as far as we can tell; the fix checks the system's own rules.
- Needed when: always
- Not needed any more when: `{"any": [{"probe": "os_fixed"}, {"file": "/usr/lib/udev/rules.d/50-intel-ax200-ax210-disable-d3cold-state.rules"}]}`
- Probe: Looks for the same rule from the system itself (any udev rule that isn't GameCove's and does the same), or the value already being right without GameCove.
- With the system's own fix also active: harmless (the same setting twice)
- Watches (github-file): ublue-os/bazzite `system_files/deck/shared/usr/lib/udev/rules.d/50-intel-ax200-ax210-disable-d3cold-state.rules`. Bazzite's own rule (added after issue 5867, reverted on 2026-11-08 in commit a4807c3). Recorded by the audit itself.
- Watches (github-issue): ublue-os/bazzite #5867. The report behind Bazzite's rule.
- Watches (github-commits): torvalds/linux `drivers/net/wireless/intel/iwlwifi/pcie/drv.c`. iwlwifi PCIe resume handling: a kernel fix would retire the rule everywhere.
- Sources: <https://github.com/ublue-os/bazzite/issues/5867>; <https://github.com/ublue-os/bazzite/blob/main/system_files/deck/shared/usr/lib/udev/rules.d/50-intel-ax200-ax210-disable-d3cold-state.rules>

### gpd-fingerprint

**Sleep that works** · Recommended · restores: sleep and battery while asleep · risk: low · revision 1 · last audited 2026-11-10

Switches off the fingerprint reader, which has no Linux driver and breaks sleep. Suspend/resume is unreliable on the GPD Win 4 and Win Max 2 because of their USB fingerprint readers.

- Recommended on: GPD WIN 4, GPD WIN Max 2
- Changes (udev-rule): `/etc/udev/rules.d/60-gamecove-gpd-fingerprint.rules`. Removes the fingerprint reader (2808:9338 on the WIN 4, 2541:9711 on the WIN Max 2) from the USB bus when it appears.
- Changes (sysfs): `/sys/bus/usb/devices/<reader>/remove`. Written once at install.
- Undo: Deletes the rule. The reader is back after a restart.
- Risk: One udev rule, the same one Bazzite ships. The fingerprint reader (which has no Linux driver) is switched off.
- Tested on hardware: not yet
- Bazzite: Fixed (50-gpd-win-4-fingerprint.rules, 50-gpd-wm2-fingerprint.rules). SteamOS: Not shipped (GPD isn't a SteamOS device).
- Needed when: always
- Not needed any more when: `{"probe": "os_fixed"}`
- Probe: Looks for the system's own rule for the reader this unit has (Bazzite ships one per model, 50-gpd-win-4-fingerprint.rules and 50-gpd-wm2-fingerprint.rules; a rule for the other model's reader doesn't count), or the value already being right without GameCove.
- With the system's own fix also active: harmless (the same setting twice)
- Watches (github-file): ublue-os/bazzite `system_files/deck/shared/usr/lib/udev/rules.d/50-gpd-win-4-fingerprint.rules`. Bazzite's WIN 4 rule. Recorded by the audit itself.
- Watches (github-file): ublue-os/bazzite `system_files/deck/shared/usr/lib/udev/rules.d/50-gpd-wm2-fingerprint.rules`. Bazzite's WIN Max 2 rule.
- Watches (github-commits): aarron-lee/gpd-win-tricks. Where the workaround comes from.
- Sources: <https://github.com/aarron-lee/gpd-win-tricks>; <https://github.com/ublue-os/bazzite/tree/main/system_files/deck/shared/usr/lib/udev/rules.d>

### gpd-wm2-touch-wakeup

**Stays asleep** · Optional · restores: sleep and battery while asleep · risk: low · revision 1 · last audited 2026-11-10

Stops the touch panel from waking the Win Max 2 right after it goes to sleep. The Win Max 2 (2025 especially) wakes again at once: its I2C touch device (PNP0C50:00) is a wakeup source.

- Optional on: GPD WIN Max 2
- Changes (udev-rule): `/etc/udev/rules.d/60-gamecove-gpd-wm2-touch-wakeup.rules`. Switches off wake-up for the I2C touch device PNP0C50:00.
- Changes (sysfs): `/sys/bus/i2c/devices/<touch>/power/wakeup`. Set to disabled at once; the old value is saved.
- Undo: Deletes the rule and writes the saved value back.
- Risk: One udev rule. Its source calls it not yet widely tested, so it isn't preselected.
- Tested on hardware: not yet
- Bazzite: Not fixed. SteamOS: Not shipped.
- Needed when: always
- Not needed any more when: `{"probe": "os_fixed"}`
- Probe: Looks for the same rule from the system itself (any udev rule that isn't GameCove's and does the same), or the value already being right without GameCove.
- With the system's own fix also active: harmless (the same setting twice)
- Watches (github-commits): aarron-lee/gpd-win-tricks `wm2-suspend-udev.sh`. The workaround's source: a change or removal there is the first sign it's no longer needed.
- Watches (github-commits): torvalds/linux `drivers/hid/i2c-hid/i2c-hid-acpi.c`. Where a kernel quirk for the touch device's wake-up would land.
- Watches (github-commits): ublue-os/bazzite `system_files/deck/shared/usr/lib/udev/rules.d`. Bazzite's handheld udev rules.
- Sources: <https://github.com/aarron-lee/gpd-win-tricks/blob/main/wm2-suspend-udev.sh>; <https://github.com/torvalds/linux/commit/805c74eac8cb306dc69b87b6b066ab4da77ceaf1>

### ally-controller-wakeup

**Sticks don't wake it** · Recommended · restores: sleep and battery while asleep · risk: low · revision 1 · last audited 2026-11-10

Stops a nudge of the sticks from waking the handheld while it goes to sleep. The built-in controller (0b05:1b4c) is a wakeup source, so stick movement wakes the device before or during sleep.

- Recommended on: ASUS ROG Ally X, ASUS ROG Xbox Ally, ASUS ROG Xbox Ally X, ASUS ROG Xbox Ally X20
- Changes (udev-rule): `/etc/udev/rules.d/60-gamecove-ally-controller-wakeup.rules`. Switches off wake-up for the built-in controller (USB 0b05:1b4c).
- Changes (sysfs): `/sys/bus/usb/devices/<controller>/power/wakeup`. Set to disabled at once; the old value is saved.
- Undo: Deletes the rule and writes the saved value back.
- Risk: One udev rule, the same one Bazzite ships. The power button still wakes it.
- Tested on hardware: not yet
- Bazzite: Fixed (50-ally-x-controller.rules). SteamOS: Unknown; the fix checks the system's own rules.
- Needed when: always
- Not needed any more when: `{"any": [{"probe": "os_fixed"}, {"file": "/usr/lib/udev/rules.d/50-ally-x-controller.rules"}]}`
- Probe: Looks for the same rule from the system itself (any udev rule that isn't GameCove's and does the same), or the value already being right without GameCove.
- With the system's own fix also active: harmless (the same setting twice)
- Watches (github-file): ublue-os/bazzite `system_files/deck/shared/usr/lib/udev/rules.d/50-ally-x-controller.rules`. Bazzite's own rule. Recorded by the audit itself.
- Watches (github-commits): torvalds/linux `drivers/hid/hid-asus.c`. The Ally's kernel HID driver: it could switch the wake-up off itself.
- Sources: <https://github.com/ublue-os/bazzite/blob/main/system_files/deck/shared/usr/lib/udev/rules.d/50-ally-x-controller.rules>

### ally-fingerprint-drain

**No drain while off** · Recommended · restores: sleep and battery while asleep · risk: low · revision 1 · last audited 2026-11-10

Lets the fingerprint reader power down, so the battery doesn't drain while the Ally is off. The fingerprint reader (1c7a:0588) stays powered and drains the battery even with the Ally switched off.

- Recommended on: ASUS ROG Ally, ASUS ROG Ally X
- Optional on: ASUS ROG Xbox Ally, ASUS ROG Xbox Ally X, ASUS ROG Xbox Ally X20
- Changes (udev-rule): `/etc/udev/rules.d/60-gamecove-ally-fingerprint-drain.rules`. Lets the fingerprint reader (USB 1c7a:0588) power down by itself.
- Changes (sysfs): `/sys/bus/usb/devices/<reader>/power/control`. Set to auto at once; the old value is saved.
- Undo: Deletes the rule and writes the saved value back.
- Risk: One udev rule, the same one Bazzite ships.
- Tested on hardware: not yet
- Bazzite: Fixed (50-ally-fingerprint.rules). SteamOS: Reported fixed in SteamOS 3.8 and later (second-hand, from a write-up of the 3.8.0 notes; not yet confirmed on our Ally). The fix checks the system's own rules.
- Needed when: always
- Not needed any more when: `{"any": [{"probe": "os_fixed"}, {"file": "/usr/lib/udev/rules.d/50-ally-fingerprint.rules"}]}`
- Probe: Looks for the same rule from the system itself (any udev rule that isn't GameCove's and does the same), or the value already being right without GameCove.
- With the system's own fix also active: harmless (the same setting twice)
- Watches (github-file): ublue-os/bazzite `system_files/deck/shared/usr/lib/udev/rules.d/50-ally-fingerprint.rules`. Bazzite's own rule. Recorded by the audit itself.
- Watches (url): https://store.steampowered.com/feeds/news/app/1675200. SteamOS release notes: 3.8 is reported to fix this; once confirmed on an Ally, add a SteamOS version rule.
- Sources: <https://github.com/ublue-os/bazzite/blob/main/system_files/deck/shared/usr/lib/udev/rules.d/50-ally-fingerprint.rules>; <https://www.pcgamer.com/hardware/big-update-to-steamos-improves-support-for-non-valve-handhelds-newer-platforms-discrete-gpus-and-steam-machine>

### ally-mcu-powersave

**Less drain while asleep** · Optional · restores: sleep and battery while asleep · risk: medium · revision 1 · last audited 2026-11-10

Lets the controller chip power down in sleep. Needs controller firmware 319+ (Ally X 313+); checked first. The Ally loses more battery asleep than it needs to while MCU powersave is off.

- Optional on: ASUS ROG Ally, ASUS ROG Ally X, ASUS ROG Xbox Ally, ASUS ROG Xbox Ally X, ASUS ROG Xbox Ally X20
- Changes (udev-rule): `/etc/udev/rules.d/60-gamecove-ally-mcu-powersave.rules`. Turns MCU powersave on at every start.
- Changes (sysfs): `/sys/class/firmware-attributes/asus-armoury/attributes/mcu_powersave/current_value (or /sys/devices/platform/asus-nb-wmi/mcu_powersave)`. Set to 1 at once; the old value is saved.
- Undo: Deletes the rule and writes the saved value back.
- Risk: With old controller (MCU) firmware the controller can stay dead after waking, so the fix refuses to install until the firmware is new enough (Ally 319, Ally X 313, as the kernel's hid-asus).
- Tested on hardware: not yet
- Bazzite: Handled by Bazzite's own MCU workaround (shows as fixed by the system when on). SteamOS: Not on by default.
- Needed when: `{"any": [{"sysfs": "/sys/class/firmware-attributes/asus-armoury/attributes/mcu_powersave/current_value"}, {"sysfs": "/sys/devices/platform/asus-nb-wmi/mcu_powersave"}]}`
- Not needed any more when: `{"probe": "os_fixed"}`
- Probe: Looks for another rule that sets mcu_powersave, or the value already being 1 without GameCove (Bazzite's own handling).
- With the system's own fix also active: harmless (the same setting twice)
- Watches (github-commits): torvalds/linux `drivers/platform/x86/asus-armoury.c`. The kernel driver that owns mcu_powersave: a default of on would retire the fix.
- Watches (github-commits): torvalds/linux `drivers/platform/x86/asus-wmi.c`. The older driver with the same switch and the MCU firmware minimums.
- Watches (github-commits): aarron-lee/SimpleDeckyTDP `py_modules/devices/rog_ally.py`. Where the workaround comes from.
- Sources: <https://github.com/aarron-lee/SimpleDeckyTDP/blob/main/py_modules/devices/rog_ally.py>; <https://github.com/aarron-lee/SimpleDeckyTDP/blob/main/py_modules/advanced_options.py>

### onexfly-touch

**Touch in the right place** · Recommended · restores: touch · risk: low · revision 1 · last audited 2026-11-10

Makes touch line up with the picture in Gaming Mode (it's turned 90 degrees). gamescope-session-plus marks this sideways panel as external, so gamescope turns the picture but not touch input.

- Recommended on: OneXFly F1
- Optional on: OneXPlayer X1 (AMD), OneXPlayer X1 Mini, OneXPlayer 2, OneXPlayer 2 Pro, AOKZOE A1, AOKZOE A1 Pro
- Changes (file): `/etc/gamescope-session-plus/sessions.d/<session>`. Sets PANEL_TYPE=internal for this handheld, so gamescope turns touch with the screen.
- Undo: Deletes the file. Takes effect next time Gaming Mode starts.
- Risk: One session file that only sets the panel type, checked against the DMI ids.
- Tested on hardware: not yet
- Bazzite: Not fixed (issue 5581; waits for ChimeraOS/gamescope-session PR 128). SteamOS: Not affected the same way (SteamOS uses its own session).
- Needed when: `{"file": "/usr/share/gamescope-session-plus/device-quirks"}`
- Not needed any more when: `{"probe": "os_fixed"}`
- Probe: Reads gamescope-session's own device-quirks file: once it treats this handheld's panel as internal, nothing is needed.
- With the system's own fix also active: harmless (the same setting twice)
- Watches (github-issue): ChimeraOS/gamescope-session #128. The upstream fix (open on 2026-11-10). Merged = fixed once Bazzite packages it.
- Watches (github-issue): ublue-os/bazzite #5581. The Bazzite report.
- Watches (github-commits): ChimeraOS/gamescope-session `usr/share/gamescope-session-plus/device-quirks`. The file the probe reads.
- Sources: <https://github.com/ublue-os/bazzite/issues/5581>; <https://github.com/ChimeraOS/gamescope-session/pull/128>

### quiet

**Keep GameCove off the game's cores** · Optional · risk: low · revision 1 · last audited 2026-11-10

While a game runs, GameCove's own work moves to the efficiency cores at low priority. GameCove's background work could land on a performance core next to the game's render thread.

- Recommended on: Every handheld
- Changes (process): `GameCove's own threads`. While a game runs: CPU affinity to the efficiency cores and nice 10 (taskset, renice). Nothing is written to disk.
- Undo: Affinity and priority go back when the game ends, or at once when you switch it off.
- Risk: Only moves GameCove's own process; no system file changes.
- Tested on hardware: MSI Claw 8 EX AI+ (Bazzite, 2026-11-04)
- Bazzite: Not applicable (GameCove's own behaviour). SteamOS: Not applicable.
- Sources: ClawDeck py_modules/clawdeck/quiet.py (same author, measured on the Claw 8 EX 2026-11-04)

### fan

**Fan presets** · Optional · risk: low · revision 1 · last audited 2026-11-10

Quiet, auto and max fan presets for handhelds whose fan driver has no service.

- A setting on the Power page, not a workaround: it has no lifecycle.
- Changes (sysfs): `the fan driver's hwmon or platform attributes (fixes/fan/README.md lists them per driver)`. Fan mode and curve points; the originals are saved first.
- Undo: Writes the saved fan mode and curve back (also when a preset fails halfway).
- Risk: A day-to-day setting with checked values; the original is always saved and put back.
- Tested on hardware: not yet
- Sources: fixes/fan/README.md

### charge-limit

**Charge limit** · Optional · risk: low · revision 1 · last audited 2026-11-10

Stops charging at a limit you choose.

- A setting on the Power page, not a workaround: it has no lifecycle.
- Changes (sysfs): `/sys/class/power_supply/<battery>/charge_control_end_threshold (or the maker's own attribute)`. The charge limit; the original is saved first.
- Changes (udev-rule): `/etc/udev/rules.d/60-gamecove-charge-limit.rules`. Only on handhelds whose firmware forgets the limit: puts it back at start.
- Undo: Writes the original limit back (100 = no limit) and deletes the rule.
- Risk: A day-to-day setting with checked values; the original is always saved and put back.
- Tested on hardware: not yet
- Sources: fixes/charge-limit/README.md

### advice-ayaneo-bios-sleep

**Sleep needs the newest BIOS** · Advice · restores: sleep and battery while asleep · risk: low · revision 1 · last audited 2026-11-10

If sleep doesn't work or the controller is gone after waking, update the BIOS from AYANEO's site first. Sleep is unreliable on AYANEO handhelds with an old BIOS, and the controller can be lost after waking.

- Shown on: AYANEO 2S, AYANEO 2, AYANEO KUN, AYANEO AIR 1S, AYANEO AIR Plus, AYANEO Flip, AYANEO Flip 1S DS, AYANEO 3, AYANEO Slide
- Undo: Nothing to undo: this is advice, GameCove changes nothing.
- Risk: Text only: GameCove changes nothing.
- Tested on hardware: not yet
- Bazzite: Not a system matter: Bazzite's AYANEO page asks for the newest BIOS. SteamOS: Not a system matter.
- Needed when: always
- Not needed any more when: always
- Probe: Bazzite's page names no BIOS versions, so nothing on the device can tell.
- With the system's own fix also active: harmless (the same setting twice)
- Watches (url): https://docs.bazzite.gg/Handheld_and_HTPC_edition/Handheld_Wiki/Ayaneo_Handhelds/. Bazzite's AYANEO page.
- Sources: <https://docs.bazzite.gg/Handheld_and_HTPC_edition/Handheld_Wiki/Ayaneo_Handhelds/>

### advice-gpd-sleep

**Sleep only partly works** · Advice · restores: sleep and battery while asleep · risk: low · revision 1 · last audited 2026-11-10

On 7840U and newer GPD handhelds sleep drains the battery and the system hibernates after about 5 %. Turn it off for long breaks. Suspend only partly works on GPD handhelds with a 7840U or newer; the firmware wakes it as the battery drops and Bazzite hibernates it.

- Shown on: GPD WIN 4, GPD WIN Mini, GPD WIN Max 2
- Undo: Nothing to undo: this is advice, GameCove changes nothing.
- Risk: Text only: GameCove changes nothing.
- Tested on hardware: not yet
- Bazzite: Not fixed; documented on Bazzite's GPD page (upstream drm/amd issue 3154). SteamOS: Not fixed.
- Needed when: always
- Not needed any more when: always
- Probe: Nothing on the device can tell; the nightly audit watches the reports.
- With the system's own fix also active: harmless (the same setting twice)
- Watches (github-issue): ublue-os/bazzite #5702. WIN 4 wakes about every two hours on battery.
- Watches (url): https://docs.bazzite.gg/Handheld_and_HTPC_edition/Handheld_Wiki/GPD_Handhelds/. Bazzite's GPD page: the sleep note going away means it's fixed.
- Sources: <https://docs.bazzite.gg/Handheld_and_HTPC_edition/Handheld_Wiki/GPD_Handhelds/>; <https://github.com/ublue-os/bazzite/issues/5702>

### advice-xbox-ally-power-button

**Power button doesn't sleep** · Advice · restores: sleep and battery while asleep · risk: low · revision 1 · last audited 2026-11-10

If the power button doesn't put it to sleep, update your system: it needs steamos-powerbuttond 3.4 or newer. On the Xbox Ally models the power button does nothing in Gaming Mode with steamos-powerbuttond older than 3.4.

- Shown on: ASUS ROG Xbox Ally, ASUS ROG Xbox Ally X, ASUS ROG Xbox Ally X20
- Undo: Nothing to undo: this is advice, GameCove changes nothing.
- Risk: Text only: GameCove changes nothing.
- Tested on hardware: not yet
- Bazzite: Reports 6036 and 6180 were still open on 2026-11-08; fixed by steamos-powerbuttond 3.4 and newer. SteamOS: Fixed with steamos-powerbuttond 3.4 and newer.
- Needed when: always
- Not needed any more when: `{"tool": "steamos-powerbuttond", "version": ">=3.4"}`
- Probe: Compares the installed steamos-powerbuttond version with 3.4.
- With the system's own fix also active: harmless (the same setting twice)
- Watches (github-issue): ublue-os/bazzite #6036. Bazzite report.
- Watches (github-issue): ublue-os/bazzite #6180. Bazzite report (powerbuttond at 100 % CPU).
- Sources: <https://discuss.cachyos.org/t/rog-xbox-ally-x-power-button-not-working/17528>; <https://github.com/ublue-os/bazzite/issues/6036>; <https://github.com/ublue-os/bazzite/issues/6180>

### controller-led

**Controller lights** · Optional · risk: low · revision 1 · last audited 2026-11-10

Colour, brightness and effect of the lights around the sticks.

- A setting on the Controller page, not a workaround: it has no lifecycle.
- Changes (sysfs): `/sys/class/leds/<handheld RGB>/`. Colour, brightness and effect; the originals are saved first.
- Undo: Writes the original colours back.
- Risk: A day-to-day setting with checked values; the original is always saved and put back.
- Tested on hardware: not yet
- Sources: fixes/controller-led/README.md

### controller-rumble

**Rumble strength** · Optional · risk: low · revision 1 · last audited 2026-11-10

How strong the built-in controller rumbles.

- A setting on the Controller page, not a workaround: it has no lifecycle.
- Changes (sysfs): `the controller driver's rumble attribute (hid-msi, hid-lenovo-go)`. Rumble strength; the original is saved first.
- Undo: Writes the original strength back.
- Risk: A day-to-day setting with checked values; the original is always saved and put back.
- Tested on hardware: not yet
- Sources: fixes/controller-rumble/README.md

### journal-flood

**Quiet system log** · Optional · risk: low · revision 1 · last audited 2026-11-10

Stops steamos-manager filling the system log with split-lock lines, so older logs aren't wiped. steamos-manager hands every split-lock hit to a crash reporter Bazzite doesn't have; each hit and each failure is logged (about 70,000 lines in five minutes on a Claw 8 EX, 14 % of a CPU core), so the capped journal loses every earlier boot within minutes.

- Optional on: Any handheld with the part
- Changes (file): `/etc/systemd/system/steamos-manager.service.d/50-gamecove-quiet-split-lock.conf`. Sets RUST_LOG=info,steamos_manager::sls=off for steamos-manager.
- Changes (service): `steamos-manager.service`. systemd reloads its units and restarts steamos-manager if it runs.
- Undo: Deletes the drop-in, reloads systemd and restarts steamos-manager.
- Risk: One systemd drop-in; only the log lines of steamos-manager's crash-report forwarding go. Everything else it logs stays.
- Tested on hardware: not yet
- Bazzite: Not fixed: Bazzite ships steamos-manager without steamos-log-submitter. SteamOS: Not needed: SteamOS has steamos-log-submitter, which takes the hits.
- Needed when: always
- Not needed any more when: `{"probe": "os_fixed"}`
- Probe: Looks for another steamos-manager drop-in (not GameCove's) that already turns the forwarding module's log off; the fix is not needed where steamos-log-submitter is installed.
- With the system's own fix also active: harmless (the same setting twice)
- Watches (url): https://gitlab.steamos.cloud/holo/steamos-manager/-/commits/main/steamos-manager/src/sls. steamos-manager's log-submitter forwarding: a change that skips it without the reporter makes this fix unnecessary.
- Watches (github-commits): ublue-os/bazzite `system_files/deck/shared/usr/lib/systemd/system`. Bazzite's own systemd units: a drop-in for steamos-manager there would make this os-fixed.
- Sources: ClawDeck py_modules/clawdeck/quietlog.py and docs/HARDWARE-FINDINGS.md (measured on a Claw 8 EX, 2026-11-04); <https://gitlab.steamos.cloud/holo/steamos-manager/-/blob/a3b2013/steamos-manager/src/sls/ftrace.rs>

### overlay-power

**Watts in the overlay** · Optional · risk: low · revision 1 · last audited 2026-11-10

Shows real CPU watts in the performance overlay. Any program can then read the power counter. The performance overlay shows 0.0 W for the CPU on Intel handhelds: the RAPL energy counter it reads is root-only since 2020.

- Optional on: MSI Claw 8 EX AI+, MSI Claw 8 AI+, MSI Claw 7 AI+, MSI Claw A1M, OneXPlayer X1 (Intel), OneXPlayer X1 Air, OneXPlayer G1 (Intel), OneXPlayer 3, OneXPlayer X2 Mini, Acer Predator Atlas 8
- Changes (file): `/etc/tmpfiles.d/gamecove-overlay-power.conf`. systemd-tmpfiles makes the package energy counters 0444 at every boot, before Game Mode starts.
- Changes (sysfs): `/sys/class/powercap/intel-rapl:0/energy_uj (and intel-rapl-mmio:0)`. Mode 0444 at once; the old mode is saved and put back on undo.
- Undo: Deletes the tmpfiles rule and puts each counter's saved mode back (0400).
- Risk: Reopens what the kernel closed on purpose: any local program can sample the chip's power counter (a side channel). Off by default for that reason.
- Tested on hardware: not yet
- Bazzite: Not changed (the kernel's 0400 default). SteamOS: Not changed (the kernel's 0400 default).
- Needed when: always
- Not needed any more when: `{"probe": "os_fixed"}`
- Probe: Looks for a tmpfiles rule from the system (not GameCove's) that opens the counters, or the counters already being readable by everyone without GameCove.
- With the system's own fix also active: harmless (the same setting twice)
- Watches (github-commits): torvalds/linux `drivers/powercap/intel_rapl_common.c`. The RAPL powercap driver: a change to energy_uj's mode would make the rule unnecessary.
- Sources: ClawDeck py_modules/clawdeck/telemetry.py and docs/HARDWARE-FINDINGS.md (measured on a Claw 8 EX); <https://nvd.nist.gov/vuln/detail/CVE-2020-8694>; <https://www.freedesktop.org/software/systemd/man/latest/tmpfiles.d.html>

### power-tune

**CPU and GPU power** · Optional · risk: low · revision 1 · last audited 2026-11-10

The TDP, boost, governor and GPU limits the Power page and Auto TDP set.

- A setting on the Power page, not a workaround: it has no lifecycle.
- Changes (sysfs): `cpufreq, intel_pstate / amd_pstate, GPU frequency and firmware-attributes power limits (fixes/power-tune/README.md)`. Each value is checked against what the kernel offers; the original is recorded first.
- Changes (service): `thermald.service`. Held while a game runs on Intel handhelds where it would overwrite the TDP; it starts again by itself.
- Undo: `set restore` writes every recorded original back; remove also forgets them.
- Risk: A day-to-day setting with checked values; the original is always saved and put back.
- Tested on hardware: not yet
- Sources: fixes/power-tune/README.md
<!-- fixes:catalogue:end -->
