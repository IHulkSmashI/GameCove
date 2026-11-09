# Hardware test plan

How GameCove v0.1.0 is tested on real handhelds, step by step, and what is checked by machine
versus by the owner's hands and eyes. Tools: [tools/testbed/](../tools/testbed/) (`gamecove-testbed.sh`,
`checks/*.sh`). Background: [SESSION.md](SESSION.md) (sessions, packaging, SteamOS),
[SYSTEM.md](SYSTEM.md) (updates, controller, root actions), [CONTROLS.md](CONTROLS.md) (every setting).

| # | Device | OS, drive | Install mode | Extras |
| --- | --- | --- | --- | --- |
| 1 | MSI Claw 8 EX (board MS-1T91) | Bazzite, external SSD | Easy | gyro fix, M1/M2 and MSI buttons, VRR (EDID), XeSS XMX |
| 2 | ROG Ally Z1 Extreme (RC71L) | SteamOS, internal drive | Custom ("Keep Steam, add GameCove", charge limit 80 %) | MCU firmware, Armoury/Command Centre buttons, LEDs, SteamOS updater |
| 3 | Legion Go S Z2 Go (83L3 / 83Q2) | Bazzite, the same SSD | Easy, then Change (Custom) | TDP limits, trackpad, LEDs |

The release under test is **v0.1.0, a GitHub pre-release**. GitHub's `releases/latest` skips
pre-releases, so every install names the tag (`install v0.1.0`, or `GAMECOVE_TAG=v0.1.0`).

## How a session works

1. The owner runs the testbed once per device; `console --keep` starts ttyd on `127.0.0.1:7681`
   under a random path and prints the link.
2. He opens the link in Chrome **on the handheld**. Claude drives that terminal through the Claude in
   Chrome extension: runs the checks, reads results, logs and read-backs.
3. Claude can't type passwords or answer polkit prompts, and can't see the screen or feel the device.
   Those steps are marked below and in the check output:

   | Mark | Who | Examples |
   | --- | --- | --- |
   | **[auto]** | `testbed check <name>` | service states, sysfs/D-Bus read-backs before and after each change, profiles, atoms, logs |
   | **[hands]** | owner | press Guide/QAM in a game, unplug the charger, wake from sleep, approve a password prompt, click through the installer |
   | **[eyes]** | owner | look at the screen, LED colour, feel the rumble, hear audio, watch the fan |

   Each **[hands]/[eyes]** item is a `MANUAL` line in the check results with an id (e.g.
   `controls.feel.rumble`). Claude asks, the owner answers, Claude records it:
   `testbed note controls.feel.rumble pass "strong, weaker at 30 %"`.
4. `--keep` keeps the terminal up while the owner switches to GameCove or Steam Gaming Mode. To keep
   driving it from inside GameCove's session, the owner opens Chrome from GameCove's library (that
   is itself a test of launching a desktop app) and switches with the quick menu; the checks that
   need the session (`gamescope`, `input`) read gamescope's display by themselves. Checks that sleep
   the handheld or wait for the owner run with `check --detach` so a reconnecting tab can't kill them.
5. At the end, `report` makes one bundle; Claude reads `summary.txt` back through the console.

Results live in `~/gamecove-tests/results/<device>/<check>.tsv`, one line per item:
`PASS|FAIL|WARN|SKIP|INFO|MANUAL <tab> <check>.<item> <tab> <message>`, with read-backs and command
output in `out/<check>/`. `testbed results` prints them all.

## The checks

| Check | What it does | Needs |
| --- | --- | --- |
| `env` | device (DMI), OS, kernel, versions (release, sysext/rpm, gamescope, Mesa, InputPlumber, steamos-manager, Chrome, Moonlight), service states, `wheel` | — |
| `install` | files in `/usr`, gamescope-session-plus and its unit, xprop; SteamOS: `/etc/extensions` link to a root-owned image on `/home`, keep list, `systemd-sysext` enabled and merged, `steamos-readonly` still on, no rpm-ostree; Bazzite: layered in `rpm-ostree status`; both polkit actions loaded and `fix-set` prompt-free; release tag (`GAMECOVE_EXPECT_TAG`) and signature; `installer.log` failures | — |
| `selftest` | `gamecove-selftest --no-network` (`GC_SELFTEST_WRITE=1` adds `--write`), every fail/warn line | — |
| `session` | steamos-manager lists `gamecove.desktop`; default login mode and desktop session; the real desktop saved and the login guard present when GameCove is the default; which gamescope session runs; recent crashes | — |
| `controls` | every control on this device (the quick menu's tabs): available, or the plain reason; then each safe one is changed through the **real Controls code** (`gamecove.x86_64 --headless -- --controls probe <id>`), read back from the system, put back, and the power/display/LED sysfs nodes are snapshotted before and after each; ends with "every node back to its value" | GameCove installed |
| `profiles` | a game layer goes on at game start and off at the end; AC and battery layers follow a charger change (`Profiles.set_plugged`, what `Power.changed` calls); every stored layer put back | GameCove installed, a per-game control (TDP, EPP, fan, FPS limit, overlay) |
| `power-source` | **[hands]** the real charger: unplug, replug; snapshots after each | by name only |
| `suspend` | `systemctl suspend`, wakes by itself after 40 s with `GC_RTC=1` (`pkexec rtcwake`: **[hands]** password once) or **[hands]** power button; values, InputPlumber devices and network before vs after; kernel resume lines | by name only, `--detach` |
| `input` | InputPlumber devices (name, profile, intercept mode, capabilities: gyro, paddles, touchpad; target device types), stuck intercept mode outside GameCove, Handheld Daemon conflicts | — |
| `gamescope` | `GAMESCOPECTRL_BASELAYER_APPID` holds 769, `GAMESCOPE_FOCUSABLE_APPS`, focused app, FPS limit, other `GAMESCOPE_*` atoms, mangoapp, panel `vrr_capable` | GameCove's session running |
| `device` | the device's extras (sections below) | — |
| `system` | every fix's status; OS update check (SteamOS `steamos-update check`, Bazzite `rpm-ostree upgrade --check`, both read-only), fwupd devices, Flatpak updates, `gamecove-upscale state`, lsfg-vk | — |
| `streaming` | Moonlight installed; the PC's public `serverinfo` on 47989 (no pairing, ids blanked) | `GC_STREAM_HOST=<pc>`; else skipped |
| `logs` | user and system journal lines (GameCove, gamescope, InputPlumber, sysext, polkit), Godot log errors, failed root actions in `changes.log`, crash dumps | — |
| `uninstall` | after Uninstall: nothing left in `/usr`, `/etc/extensions`, keep list, `/home/.steamos/offload/gamecove`; default desktop not GameCove, boot mode game; user units, entries, `pending-choices` gone; no fix state; no Steam launch option calling `gamecove-run` | GameCove removed (skips before) |

Never probed automatically (changed by hand once, **[hands]/[eyes]**): sleep, screenshot, keep awake,
Wi-Fi, Bluetooth, airplane mode, refresh rate (it has a keep/revert dialog), rotation, HDR, custom fan
curve, SMT / core count / sleep mode / MCU power saving (they ask for the admin password), reset layout,
rumble test, shader cache, launch wrapper and Proton per game.

## Steps, for each device

Run the commands from the [per-device commands](#exact-commands-per-device). `T=~/src/GameCove/tools/testbed/gamecove-testbed.sh`.

### 0. Prepare (Desktop Mode)
1. **[hands]** Konsole: `curl … gamecove-testbed.sh`, `prepare`, then `sh $T console --keep`; open the link in Chrome.
2. **[auto]** `sh $T status` and `sh $T check env` (right device, right OS; note versions).

### 1. Install
1. **[auto]** `sh $T install v0.1.0`: downloads the tag's `get-gamecove.sh`, which checks the Sigstore
   signature and checksums; then the installer app opens.
2. **[hands]** Go through the installer: Easy (Claw, Legion Go S) or Custom (Ally: "Keep Steam, add
   GameCove", Steam silent, the fixes it offers, charge limit 80 %, Moonlight on). Approve each
   password prompt. **[eyes]** every page reads right, the summary matches the choices.
3. **[auto]** `GAMECOVE_EXPECT_TAG=v0.1.0 sh $T check install selftest session logs`.
   On Bazzite, if `--apply-live` didn't work, restart first (the check says "staged").
4. **[eyes]** "GameCove" entry in the app menu; the desktop shortcut.

### 2. First boot
1. **[hands]** Restart (Claw, Legion Go S: should boot into GameCove; Ally: boots Steam Gaming Mode, then
   the "GameCove" entry switches).
2. **[eyes]** No black screen; home within ~10 s; the first-run setup shows nothing the installer covered.
3. **[auto]** from Chrome in GameCove: `sh $T check gamescope input session`.

### 3. Quick menu, every tab and setting on this device
1. **[auto]** `sh $T check controls` (available/unavailable with reasons, then every safe control
   changed, read back and restored). Unavailable ones must have a reason that's true for this device.
2. **[hands]/[eyes]** in a game, open the quick menu (Guide): tabs This game, Power, Display, Audio,
   Controller, Device. For each item the check printed as `MANUAL`: brightness follows; vibrance /
   colour temperature / night light visibly change; each overlay preset; rumble strength felt; LED colour,
   effect, brightness; volume, mute, output; then once by hand Wi-Fi, Bluetooth, airplane, refresh rate
   (accept, then let it revert), rotation (if offered), HDR (if offered), keep awake, screenshot, sleep.
3. **[eyes]** values shown in the quick menu match what `controls` read back (`out/controls/probe.txt`).

### 4. Profiles in a real game
Light, free Steam games that run on Linux (check Steam's Deck compatibility badge before
downloading): **Brawlhalla** (2D, Proton), **Team Fortress 2** (native Linux build). Use one per device.
1. **[auto]** `sh $T check profiles` (game layer on/off; AC vs battery layers).
2. **[hands]** In the game: quick menu → TDP and FPS limit → "Save as this game's profile"; quit;
   relaunch: values come back; at home: the everyday values. **[auto]** `sh $T check gamescope` during and after.
3. **[hands]** `sh $T check --detach power-source` then unplug and replug when asked. **[eyes]** TDP in
   the quick menu follows the charger.

### 5. Upscaling and frame generation (one game, Claw first)
A DX11/12 game with FSR 2+/XeSS/DLSS, e.g. **Warframe** (free, large download) or any such game
the owner has. **[auto]** `sh $T check system device` (upscale state); **[hands]** Upscaling page:
the recommended upscaler, launch, **[eyes]** confirm in the game / OptiScaler overlay (Insert),
then Undo; frame generation 2x if lsfg-vk and Lossless Scaling are there. Note fps before and after.

### 6. Fixes page
**[auto]** `sh $T check system` lists every fix's status. **[eyes]** Settings → Fixes shows the same per
fix, with the right "what it fixes" line. **[hands]** In Desktop Mode, Undo one optional fix and Apply it
again (password prompt); re-run `check system`.

### 7. Updates page
**[auto]** `check system` runs the same read-only OS check. **[eyes]** Updates page: OS, firmware,
Flatpak and drivers rows match; checking again changes nothing; nothing applies by itself. Don't apply
an OS update during the run, except the planned SteamOS interplay on the Ally (below).

### 8. Streaming (only if the PC with Vibepollo is reachable)
**[auto]** `GC_STREAM_HOST=<pc address> sh $T check streaming`; skipped otherwise. **[hands]** pair,
stream, play a minute, quit back to GameCove.

### 9. Sleep and wake
**[hands]** `GC_RTC=1 sh $T check --detach suspend` (type the password for rtcwake), or without
`GC_RTC` press power after ~20 s. **[auto]** values, InputPlumber devices, network compared. **[eyes]**
controller works at once, LEDs come back, the game resumes. Then once from the quick menu's Sleep.

### 10. Desktop and back, Steam's session
**[hands]** quick menu → Switch to Desktop Mode (lands in Plasma); back to GameCove; quick menu → Steam
Gaming Mode; Steam's own "Switch to Desktop" (must reach Plasma, not GameCove); back to GameCove.
**[auto]** `sh $T check session` after each (the console survives with `--keep`). A Steam game from
GameCove's library: starts, comes to the front, Shift+Tab overlay, quit returns home.

### 11. Uninstall
**[hands]** `sh $T uninstall` → Uninstall (keep settings off on the last device). Restart.
**[auto]** `sh $T check uninstall logs`. **[eyes]** boots into Steam Gaming Mode; Steam's Switch to
Desktop reaches Plasma.

### 12. Report and reset
**[auto]** `sh $T report` (Claude reads `summary.txt`), then `sh $T reset` (Claw, before moving the
SSD) or `reset --full` (when the next device needs a from-scratch install). Shut down, move the SSD.

## Per-device extras

**MSI Claw 8 EX (Bazzite).** `check device`: gyro, buttons, VRR, wake and Wi-Fi fix statuses;
`msi-wmi-platform` TDP attributes; eDP `vrr_capable`; XeSS XMX state. **[hands]/[eyes]** gyro (with
the gyro fix: smooth, no drift at rest, Steam sees it); M1/M2 and the MSI Center / Quick Settings
buttons do what the Buttons page says; VRR on: smooth frametimes at 40–60 fps, no flicker; XeSS on an
XeSS game shows the XMX path. Thermald: TDP holds during a game (the `controls` probe shows it in
`ppt_*` before/after) and thermald is running again after the game.

**ROG Ally Z1 Extreme (SteamOS).** `check device`: `asus-armoury` TDP attributes with min/max,
`mcu_powersave`, cached MCU firmware version (319+ needed for MCU power saving; run
`pkexec /usr/libexec/gamecove/gamecove-fix ally-mcu-powersave status` once, **[hands]** password),
stick-ring LED nodes, steamos-manager `TdpLimit1`, platform profile (steamos-manager wants
`performance`), `steamos-update check`. SteamOS ships no InputPlumber entry for the Ally (Steam reads its
controller itself), so `input` reports that as info, not a failure. **[hands]/[eyes]** Armoury Crate and
Command Centre buttons; LEDs red → off → effect, and after sleep. **SteamOS updater interplay:** GameCove's
Updates page check matches Steam's; when an update is out, apply it from GameCove, then `check install`
*before* restarting (the sysext is unmerged until the reboot: expected), restart, `check install` again
(the image, link, keep list and `systemd-sysext` enable must all survive the update).

**Legion Go S (Bazzite).** `check device`: `lenovo-wmi-other-0` TDP attributes with min/max on
battery and AC, platform profile (`custom` for manual TDP), LED nodes, `charge_types`.
**[hands]/[eyes]** TDP slider range matches the firmware's on battery and on AC, 8 W and 25 W read back in
`ppt_pl1_spl`; trackpad mouse mode in Desktop and a game menu, then off; LED colour and brightness.
Then the installer's Change (Custom) path: switch "Boot into GameCove" ↔ "Keep Steam", re-run `check session`.

## Exact commands per device

Once per drive, in Konsole (Desktop Mode):

```
curl -fsSL https://raw.githubusercontent.com/IHulkSmashI/GameCove/main/tools/testbed/gamecove-testbed.sh -o ~/gamecove-testbed.sh
GAMECOVE_TESTBED_REF=main sh ~/gamecove-testbed.sh prepare
T=~/src/GameCove/tools/testbed/gamecove-testbed.sh
sh $T console --keep            # open the printed link in Chrome, tell Claude
```

Then Claude types, in that terminal (the owner does what the `[hands]` lines ask):

| Device | Commands |
| --- | --- |
| Claw 8 EX, Bazzite SSD | `sh $T install v0.1.0` → `GAMECOVE_EXPECT_TAG=v0.1.0 sh $T check` → restart → `sh $T check gamescope input controls profiles device` → `sh $T check --detach power-source` → `GC_RTC=1 sh $T check --detach suspend` → `sh $T check system logs` → `sh $T report` → `sh $T reset` |
| ROG Ally, SteamOS internal | `prepare` and `console --keep` as above (the Ally's own drive) → `sh $T install v0.1.0` → `GAMECOVE_EXPECT_TAG=v0.1.0 sh $T check` → `sh $T check controls profiles device` → `sh $T check --detach power-source` → `GC_RTC=1 sh $T check --detach suspend` → `sh $T uninstall` → restart → `sh $T check uninstall logs` → `sh $T report` |
| Legion Go S, Bazzite SSD | (after the Claw's `reset --full`) `sh $T install v0.1.0` → `GAMECOVE_EXPECT_TAG=v0.1.0 sh $T check` → restart → `sh $T check gamescope input controls profiles device` → `sh $T check --detach power-source` → `GC_RTC=1 sh $T check --detach suspend` → `sh $T uninstall` → restart → `sh $T check uninstall logs` → `sh $T report` → `sh $T reset` |

Streaming on any device: `GC_STREAM_HOST=<pc address> sh $T check streaming`.

## If something goes wrong

- Black screen or stuck in GameCove: the session falls back to Steam after 3 crashes in 2 minutes. With a
  keyboard: Ctrl+Alt+F3, log in as yourself, `gamecove-session-select restore`, then
  `gamecove-session-select desktop` (SESSION.md, "If GameCove won't let you out").
- The console is gone after a session switch (the user manager stopped): back in Desktop Mode, run
  `console --keep` again; results so far are kept.
- A refresh-rate change blanked the panel: wait 15 s (it reverts), or from the console
  `rm ~/.config/environment.d/80-gamecove-display.conf` and switch sessions.
