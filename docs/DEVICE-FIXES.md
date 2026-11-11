# Device fixes for every handheld in devices.json

Research for GameCove's Fixes page (fixes agent, 2026-11-08). For each handheld: what is broken,
whether the shipping Bazzite (deck image, 44/45, read from the local clone of ublue-os/bazzite at
de2198d, 2026-11-08) and SteamOS (3.8 / 3.9 issue tracker) already fix it, how a fix works, and the
sources. **Shipped** = a GameCove fix folder in `fixes/`. **Auto** = the installer applies it (in
the device's `devices.json` "fixes"). **Optional** = offered with Apply on the Fixes page.
**Skipped** = researched, not shipped, with the reason.

Sources read: Bazzite `system_files/` (udev rules, wireplumber/pipewire hardware profiles,
gamescope display scripts, `bazzite-hardware-setup` HWS_VER 86, `hwsupport/*`, all `ujust`
recipes), InputPlumber `rootfs/` (device configs, udev rules, hwdb, 2026-11-07), Handheld Daemon
`src/hhd/device/*` and `usr/lib/udev` (2026-11-08), ChimeraOS gamescope-session `device-quirks`,
gamescope `scripts/00-gamescope/displays/`, aarron-lee legion-go-tricks, gpd-win-tricks and
SimpleDeckyTDP, steam-patch (corando98, Maclay74), ClawDeck docs/HARDWARE-FINDINGS.md, GitHub
issue search of ublue-os/bazzite, ValveSoftware/SteamOS, ShadowBlip/InputPlumber, hhd-dev/hhd
(last 12 months), LKML, universal-blue Discourse, CachyOS forum.

## How the shipped fixes work

All but the three Claw 8 EX fixes are built on `fixes/lib/gcfix.sh`: one udev rule (or one
gamescope-session file) in `/etc`, matched on the DMI ids inside the rule itself (so a drive that
boots several handhelds never applies one handheld's fix to another), applied at once by writing
the same sysfs value (the original is saved and written back by Undo), `os-fixed` when another
rule on the system already does the same (Bazzite) or the value is already right without us,
`not-needed` when the part isn't in this handheld. Apply / Undo need the administrator password
(`gamecove-fix <fix> install|remove`, Desktop Mode): they write a udev rule or session file that acts on
every boot, which isn't a day-to-day setting (review S3-2, docs/SYSTEM.md "GameCove's root actions").

## Shared parts: who else gets each fix (traits pass, 2026-11-09)

Fixes now name the part they're for (selectors over devices.json `traits`, docs/DEVICES.md), not
model ids, and every fix researched for one model was re-checked against its siblings. Each udev
rule's DMI match is generated from the resolved handhelds. `python3 tools/traits/traits.py fixes`
prints the current sets.

| Fix | Keyed by | Was | Now also | Why the siblings have the same issue |
|---|---|---|---|---|
| ally-controller-wakeup | `controller:asus-ally-x` (0b05:1b4c) | Ally X, Xbox Ally, Xbox Ally X | **Xbox Ally X20 (auto)** | Same controller per InputPlumber `50-rog_xbox_ally_x20.yaml`; Bazzite's rule matches the USB id alone. Our old rule also matched `sys_vendor=="ASUSTeK COMPUTER INC."`, which the X20 (`ASUS`) never matched, so the X20 kept waking from stick bumps. |
| ally-fingerprint-drain | `fingerprint:1c7a:0588`; optional `fingerprint:asus-power-button` | Ally, Ally X | **Xbox Ally, Xbox Ally X, X20 (optional)** | They have a power-button reader too; its USB id isn't confirmed, so it's offered and the fix's status shows "not needed" if the id differs. X20 rule DMI fixed as above. |
| claw8ex-vrr | `panel:csw-pn8007qb1-2` + Intel GPU driver; optional `panel:tmx-tl070fvxs02-0` | Claw 8 EX | **Claw 8 AI+ (auto)**, **Claw A1M, Claw 7 AI+ (optional)** | Same body and panel: the fix's own validated panel list (ClawLab catalogue) already had the 8 AI+ panel (CSW0801) and the A1M / 7 AI+ panel (TMA2027), but only the 8 EX got it. Patches only those exact EDIDs (sha256). Excluded: Claw A8 (AMD: the hook runs before xe/i915 only; EDID not validated). |
| claw-wifi-d3cold | `controller:msi-claw` + `cpu_vendor:intel` | A1M, 7 AI+, 8 AI+ (optional) | **Claw 8 EX (optional)** | Same MSI firmware family with an Intel Wi-Fi card; the workaround is user-verified on the other Intel Claws. |
| ax210-d3cold | `wifi:ax210` (auto), `*` (optional) | WIN 5 (auto) | **AYANEO 2, 2S (auto)** | AYANEO ships the AX210 (Bazzite's rule names AYANEO Air devices); the 2 / 2S value is unverified, so the fix checks for PCI 8086:2725 and says "not needed" without it. |
| onexfly-touch | `session_quirk:oxp-120-external-left`; optional the other external + left blocks | OneXFly F1 | **OneXPlayer 2, 2 Pro, AOKZOE A1, A1 Pro, OneXPlayer X1 A, X1 mini (optional)** | device-quirks starts them the same way (PANEL_TYPE=external, ORIENTATION=left) and none has a kernel panel-orientation quirk. Confirmed only on the F1 (Bazzite 5581), so optional elsewhere. The session file and "needed" check now read the product's own device-quirks block. |
| claw-kbd-wakeup | `controller:msi-claw` | every Claw | (same set) | |
| gpd-fingerprint | `fingerprint:2808:9338\|2541:9711` | WIN 4, WIN Max 2 | (same set) | WIN Mini / WIN 5 readers: none known. |
| ally-mcu-powersave | `ec:asus-armoury` + `controller:asus-ally*` | every Ally | (same set) | |
| claw8ex-buttons, claw8ex-gyro | `firmware:msi-e1t91` (+ `imu:ish-hid-sensor`) | Claw 8 EX | (same) | Board-specific InputPlumber config and Panther Lake ISH firmware; Lunar / Meteor Lake Claws use other hubs. |

Other findings from the shared-part pass:

- **ZOTAC Zone:** Linux's panel orientation quirk matches board `G0A1W` only; `G1A1W` units (in
  devices.json and InputPlumber) don't get it (quirk `kernel-orientation-quirk-first-board-only`;
  GameCove's rotation control covers it, an upstream kernel patch would fix it for everyone).
- **Orange Pi Neo:** the kernel's `oxpec` EC driver covers it (board NEO-01) like OneXPlayer and
  AOKZOE, so its fan should work through `oxp_ec`; devices.json still has no fan driver for it
  (left for the power owner to verify on hardware).
- **ONEXPLAYER X1 Pro:** device-quirks has no block for it (only X1 A / X1 i / X1 mini), so
  gamescope doesn't switch its refresh; the display provider used to assume it did. Fixed through
  the `session-refresh-switching` quirk.
- **ONEXPLAYER X2 Mini:** devices.json says AMD, but InputPlumber's config uses the Intel xHCI
  (`usb-0000:00:14.0`) like the OneXPlayer 3; left unknown in traits until someone checks.
- **Thermald** restoring the firmware TDP (found on the Claw 8 EX) applies to every Intel handheld
  (quirk `thermald-restores-tdp`).

## Valve Steam Deck (LCD `Jupiter`, OLED `Galileo`)

| Fix | Symptom | Bazzite | SteamOS | Method | GameCove | Sources |
|---|---|---|---|---|---|---|
| (none needed) | Native platform; jupiter-fan-control, vpower, Valve's udev rules. | Masks InputPlumber/PowerStation, enables Valve's services (bazzite-hardware-setup). | Native. | - | No fix offered | bazzite `bazzite-hardware-setup` |
| OLED speakers silent after resume (max98388 `Unable to sync registers`) | Intermittent no audio after sleep. | Closed 2026-10-31 (kernel). | Fixed in Valve kernel. | kernel | Skipped: fixed upstream | https://github.com/ublue-os/bazzite/issues/6200 |
| Fuzzy sound after resume | Distorted audio for ~30 s after wake. | Not fixed | Not fixed | user service restarting pipewire (aarron-lee) | Skipped: anecdotal Reddit fix, restarts the user's audio | https://github.com/aarron-lee/legion-go-tricks/tree/main/fuzzy-sound-suspend-fix |

## ASUS ROG Ally (RC71L), Ally X (RC72LA), Xbox Ally (RC73YA), Xbox Ally X (RC73XA), Xbox Ally X20 (RC74XA)

| Fix | Symptom | Bazzite | SteamOS | Method | GameCove | Sources |
|---|---|---|---|---|---|---|
| ally-fingerprint-drain | Battery drains while the Ally is off: the fingerprint reader (1c7a:0588) stays powered. | Fixed (50-ally-fingerprint.rules) | Unknown; checked at runtime | udev `power/control=auto` | **Shipped, auto** (Ally, Ally X) | bazzite `system_files/deck/shared/usr/lib/udev/rules.d/50-ally-fingerprint.rules` |
| ally-controller-wakeup | Stick bumps wake the device during / after suspend (controller 0b05:1b4c is a wakeup source). | Fixed (50-ally-x-controller.rules) | Unknown; checked at runtime | udev `power/wakeup=disabled` | **Shipped, auto** (Ally X, Xbox Ally, Xbox Ally X) | bazzite `50-ally-x-controller.rules` |
| ally-mcu-powersave | More drain asleep than needed; MCU powersave off. | Bazzite has its own MCU handling | Not on by default | asus-armoury `mcu_powersave` / asus-wmi `mcu_powersave` = 1 | **Shipped, optional** (needs MCU fw Ally 319+ / Ally X 313+, the kernel hid-asus minimums) | https://github.com/aarron-lee/SimpleDeckyTDP/blob/main/py_modules/devices/rog_ally.py |
| Speaker DSP / EQ | Thin speakers. | Fixed (pipewire filter-chain for RC71L, wireplumber for RC72LA) | Fixed (Valve profile) | pipewire hardware profile | Skipped: fixed by the OS | bazzite `usr/share/pipewire/hardware-profiles/asustek computer inc.-rog ally rc71l_rc71l/` |
| Duplicate power button (ACPI + GPIO) -> sleep loop | Sleeping from a Steam submenu loops wake/sleep. | Open (#5905), fix needs powerbuttond changes too | Similar (#2947) | hwdb `STEAMOS_POWER_BUTTON_IGNORE` + powerbuttond patch | Skipped: half the fix is in powerbuttond; GameCove doesn't run powerbuttond's Steam path | https://github.com/ublue-os/bazzite/issues/5905 |
| Xbox Ally power button doesn't sleep / powerbuttond 100 % CPU | | Open (#6036, #6180) | | powerbuttond regression | Skipped: no fix yet | https://github.com/ublue-os/bazzite/issues/6036 |
| Ally X QAM ignored with HORIPAD target | | Open (#6261) | | SDL mapping env override | Skipped: Steam-input mapping, not a system fix | https://github.com/ublue-os/bazzite/issues/6261 |
| MT7922 Wi-Fi scan failures after sleep | Wi-Fi drops; `CTRL-EVENT-SCAN-FAILED ret=-22`. | Open (#6000), `disable_aspm=Y` merged (#5898) | Similar reports | NetworkManager: no scan MAC randomization | Skipped: one unconfirmed report, a privacy trade-off, and an NM drop-in can't be DMI-gated without a boot service | https://github.com/ublue-os/bazzite/issues/6000 |
| X20 audio / wake issues | | Open (#6060, #6226), device new in testing | | | Skipped: no diagnosis yet | https://github.com/ublue-os/bazzite/issues/6060 |
| Fan floor ~50 % on Xbox Ally X | | | | EC | Skipped: firmware behaviour (documented for the fan preset) | https://github.com/hhd-dev/hhd/issues/337 |

## Lenovo Legion Go (83E1), Legion Go 2 (83N0 / 83N1), Legion Go S (83L3/83Q2, 83N6/83Q3)

| Fix | Symptom | Bazzite | SteamOS | Method | GameCove | Sources |
|---|---|---|---|---|---|---|
| Screen rotation, controller xpad rule | | Fixed | Fixed | kernel quirks, gamescope displays (lenovo.legiongo.lcd, legiongo2.oled, legiongos.lcd) | Skipped: upstream | legion-go-tricks README; gamescope `scripts/00-gamescope/displays/` |
| Speaker DSP (Go) | Thin sound. | Fixed (pipewire filter-chain lenovo-83e1, raise mic, prefer HDMI) | Fixed | pipewire profile | Skipped: OS | bazzite `hardware-profiles/lenovo-83e1/` |
| IOMMU off | | Bazzite removes `amd_iommu=off` on 83N0/83N1/83E1 | | karg | Skipped: OS | bazzite-hardware-setup |
| Legion Go S wake: backlight on, black screen | | Open (#5883) | Similar (#2700 trackpad after sleep) | | Skipped: no fix known | https://github.com/ublue-os/bazzite/issues/5883 |
| Legion Go S gyro (AMD SFH short reports) | | Open (#5796), kernel regression | | kernel | Skipped: kernel fix needed | https://github.com/ublue-os/bazzite/issues/5796 |
| Legion Go 2 gyro not forwarded | | Open (#6034) | | InputPlumber | Skipped: InputPlumber bug | https://github.com/ublue-os/bazzite/issues/6034 |
| Instant wake from sleep (Go / Go S on SteamOS) | | | Open (#2555), no diagnosis | | Skipped: no fix | https://github.com/ValveSoftware/SteamOS/issues/2555 |
| Fuzzy sound after resume (Go) | | | | Pause Games plugin / pipewire restart | Skipped: anecdotal | legion-go-tricks README |

## MSI Claw 8 EX AI+ (MS-1T91), Claw 8 AI+ (MS-1T52), Claw 7 AI+ (MS-1T42), Claw A1M (MS-1T41), Claw A8 (MS-1T8K), other MS-1T*

| Fix | Symptom | Bazzite | SteamOS | Method | GameCove | Sources |
|---|---|---|---|---|---|---|
| claw8ex-buttons | MSI face buttons dead in Gaming Mode (firmware sends Win+G / F15, stock map `claw2` waits for F15+G / F16). | Not fixed | n/a | InputPlumber override + capability map | **Shipped, auto** (8 EX) | ClawDeck HARDWARE-FINDINGS §12; InputPlumber `50-msi_claw8_ex_ai_cg3em.yaml` |
| claw8ex-vrr | VRR only 48-120 Hz (EDID), panel does 30-120. | Not fixed | n/a | EDID override (initramfs) | **Shipped, auto** (8 EX) | ClawDeck §11; fixes/claw8ex-vrr |
| claw8ex-gyro | No gyro (ISH firmware) | Not fixed | n/a | HID-BPF + MSI ISH firmware | **Shipped, auto** (8 EX) | fixes/claw8ex-gyro |
| claw-kbd-wakeup | Volume buttons (i8042 keys) wake the Claw from sleep; with InputPlumber nothing disables it (hhd did, `serio0/power/wakeup`). Kernel quirk was refused: maintainer asked for a udev rule. | Not fixed (Claw moved to InputPlumber in 44) | n/a | udev `serio atkbd power/wakeup=disabled`, MSI MS-1T* boards | **Shipped, auto** (all Claws) | https://lkml.iu.edu/hypermail/linux/kernel/2506.2/01805.html ; https://lkml.indiana.edu/hypermail/linux/kernel/2506.2/03339.html ; hhd `src/hhd/device/claw/__init__.py` |
| claw-wifi-d3cold | Wi-Fi gone after sleep/lock until restart (Intel card in D3cold). | Not fixed (Discourse 2024-12, no answer) | Not fixed; user-verified workaround (#2742, #2703) | udev `d3cold_allowed=0` for Intel network controllers on MS-1T41/42/52 | **Shipped, optional** (a little more drain asleep) | https://github.com/ValveSoftware/SteamOS/issues/2742 ; https://github.com/ValveSoftware/SteamOS/issues/2703 |
| journal-flood | steamos-manager hands every split-lock hit to steamos-log-submitter, which Bazzite doesn't ship; hits and failures flood the journal (about 70,000 lines in 5 minutes, 14 % of a core on the 8 EX) and the capped journal loses older boots. Any handheld with steamos-manager. | Not fixed | Not needed (reporter installed) | systemd drop-in `RUST_LOG=info,steamos_manager::sls=off` | **Shipped, optional** (any handheld; the fix checks for the daemon and the reporter) | ClawDeck `quietlog.py`, HARDWARE-FINDINGS (measured on the 8 EX); steamos-manager `src/sls/ftrace.rs` |
| Speaker headroom (A1M, 7 AI+, 8 AI+) | Crackling | Fixed (wireplumber `80-alsa-headroom.conf`) | n/a | | Skipped: OS | bazzite hardware-profiles `micro-star ... claw-8-ai+-a2vm` |
| Face-button keys (b9/ba -> F15/F16) | | Fixed (systemd/hhd/InputPlumber hwdb) | | hwdb | Skipped: upstream | systemd `hwdb.d/60-keyboard.hwdb` |
| Thermald overwrites TDP (8 EX) | PL1 back to 30 W within 10 s | Not fixed | n/a | stop thermald while GameCove sets TDP | Not a fix folder: belongs to the power controls (ClawDeck §21) | ClawDeck HARDWARE-FINDINGS §21 |
| A1M left button dead after Bazzite 44 | | Open (Discourse 12388) | | InputPlumber | Skipped: no working fix | https://universal-blue.discourse.group/t/msi-claw-a1m-left-quick-access-system-button-not-working-after-update-to-bazzite-44-inputplumber-regression/12388 |
| A1M gamepad stuck in keyboard/mouse after resume | | Open (InputPlumber #722; suspected udev mode rule not re-run) | | | Skipped: cause unconfirmed | https://github.com/ShadowBlip/InputPlumber/issues/722 |
| A8 wake then sleep again / QAM needs several presses | | Open (#5473, #6038) | | | Skipped: no diagnosis (keyboard wake fix may help; it ships anyway) | https://github.com/ublue-os/bazzite/issues/5473 |

## OneXPlayer: OneXFly F1 / F1 Pro / Apex, X1 (AMD, Intel, mini, Pro), 2 / 2 Pro, G1 (AMD, Intel), 3, X2 Mini, Super X

| Fix | Symptom | Bazzite | SteamOS | Method | GameCove | Sources |
|---|---|---|---|---|---|---|
| onexfly-touch | OneXFly F1 touch turned 90° in Gaming Mode (device-quirks `PANEL_TYPE=external`). | Open (#5581), waits for upstream | n/a | `/etc/gamescope-session-plus/sessions.d/<client>`: `PANEL_TYPE=internal`, DMI-checked | **Shipped, auto** (F1, EVA-01); os-fixed once PR 128 lands | https://github.com/ublue-os/bazzite/issues/5581 ; https://github.com/ChimeraOS/gamescope-session/pull/128 |
| F1 boot console rotation | | Fixed (karg `video=eDP-1:panel_orientation=left_side_up`) | | karg | Skipped: OS | bazzite-hardware-setup |
| Turbo button takeover | | Fixed (InputPlumber udev `tt_toggle=1`) | | | Skipped: upstream | InputPlumber `99-inputplumber-device-setup.rules` |
| F1 Pro / OneXFly extra buttons | Turbo / orange / M1 / M2 fail after HHD -> InputPlumber | Open (#5503, #6172) | | InputPlumber configs | Skipped: per-button root causes still open upstream | https://github.com/ublue-os/bazzite/issues/5503 |
| G1 touch keyboard | Taps send F17 + touch coordinates | Open (#6076), userspace driver in a gist | | python uinput driver + per-device calibration | Skipped: large userspace driver needing per-unit calibration; belongs in InputPlumber | https://github.com/ublue-os/bazzite/issues/6076 |
| X1 Pro TDP | | Open (#5990) | | PowerStation | Skipped: power controls | https://github.com/ublue-os/bazzite/issues/5990 |
| OneXPlayer 3 black screen in some games | | Open (#6164) | | | Skipped: no fix | https://github.com/ublue-os/bazzite/issues/6164 |
| Super X fan (oxpec DMI) | | Fixed (closed #5334) | | kernel | Skipped: upstream | https://github.com/ublue-os/bazzite/issues/5334 |

## AOKZOE A1 / A1 Pro / A1X

| Fix | Symptom | Bazzite | SteamOS | Method | GameCove | Sources |
|---|---|---|---|---|---|---|
| A1 EDID | Wrong refresh range | Fixed (karg `drm.edid_firmware=eDP-1:edid/aokzoea1ar07_edid.bin`) | n/a | EDID | Skipped: OS | bazzite-hardware-setup |
| A1X speakers | | Fixed (closed #5071) | | | Skipped: upstream | https://github.com/ublue-os/bazzite/issues/5071 |
| A1 button repeat | | Open (#3262, 2025) | | | Skipped: no fix | https://github.com/ublue-os/bazzite/issues/3262 |

## AYANEO 2 / 2S / 3 / KUN / AIR 1S / AIR Plus / Flip / Flip 1S DS / Slide

| Fix | Symptom | Bazzite | SteamOS | Method | GameCove | Sources |
|---|---|---|---|---|---|---|
| ax210-d3cold | AX210 (stock in some Air units, common swap) dies after sleep | Fixed (50-intel-ax200-ax210-disable-d3cold-state.rules) | Not shipped | udev | **Shipped, optional** on any handheld (status from the PCI id) | https://github.com/ublue-os/bazzite/issues/5867 |
| Air / Air Pro MT7921 sleep | | Fixed (kmod-sleep-workaround@mt7921e via 50-wifi-sleep.rules) | | | Skipped: OS (and the Air isn't in devices.json) | bazzite `50-wifi-sleep.rules` |
| Slide random reboots | | Fixed (karg `acpi=strict`) | | | Skipped: OS | bazzite-hardware-setup |
| Extra keys (66-69 -> F15-F18) | | Fixed (InputPlumber/hhd hwdb) | | | Skipped: upstream | InputPlumber `59-inputplumber.hwdb` |
| AYANEO 3 washed-out colours | | Fixed (closed #5219) | | | Skipped: upstream | https://github.com/ublue-os/bazzite/issues/5219 |
| Geek headphone mutes speakers | | Open (#5823) | | | Skipped: ALSA routing, no fix | https://github.com/ublue-os/bazzite/issues/5823 |

## GPD WIN 4 (G1618-04), WIN Mini (G1617-01/02), WIN Max 2 (G1619-04/05), WIN 5 (G1618-05)

| Fix | Symptom | Bazzite | SteamOS | Method | GameCove | Sources |
|---|---|---|---|---|---|---|
| gpd-fingerprint | Suspend/resume unreliable (fingerprint reader without a driver: Win 4 2808:9338, WM2 2541:9711) | Fixed (50-gpd-win-4-fingerprint.rules, 50-gpd-wm2-fingerprint.rules) | Not shipped | udev `remove=1` | **Shipped, auto** (Win 4, Win Max 2) | https://github.com/aarron-lee/gpd-win-tricks |
| gpd-wm2-touch-wakeup | Win Max 2 (2025) wakes again at once: I2C touch PNP0C50:00 is a wakeup source | Not fixed | Not shipped | udev `power/wakeup=disabled` | **Shipped, optional** ("not thoroughly tested" upstream) | https://github.com/aarron-lee/gpd-win-tricks/blob/main/wm2-suspend-udev.sh |
| ax210-d3cold | WIN 5 Wi-Fi dead after sleep | Fixed | Not shipped | udev | **Shipped, auto** (WIN 5) | https://github.com/ublue-os/bazzite/issues/5867 |
| Hibernation | GPD needs hibernation | Fixed (needs-hibernation enables it) | | | Skipped: OS | bazzite `hwsupport/needs-hibernation` |
| Win 4 refresh rates | | Fixed (gamescope gpd.win4.lcd.lua) | | | Skipped: OS | gamescope / bazzite displays |
| Win Mini / Win 5 speaker EQ | | Fixed (pipewire profiles gpd-g1617-01, gpd-g1618-05) | | | Skipped: OS | bazzite hardware-profiles |
| Win 4 (7840U/8840U) wakes every ~2 h on battery | Firmware wakes per 5 % battery | Open (#5702); hhd's hibernate-at-4 % alarm gone | | | Skipped: firmware; only a shorter sleep timer helps | https://github.com/ublue-os/bazzite/issues/5702 |
| Win 4 gyro after suspend (win4-suspend-mods) | | Was a Bazzite patch for hhd | | systemd suspend hooks | Skipped: written for hhd; Bazzite now uses InputPlumber | gpd-win-tricks `win4-suspend-mods` |
| Win 4 wrong battery after wake | | Open (#5663) | | | Skipped: no fix | https://github.com/ublue-os/bazzite/issues/5663 |

## ZOTAC Gaming Zone

| Fix | Symptom | Bazzite | SteamOS | Method | GameCove | Sources |
|---|---|---|---|---|---|---|
| Panel orientation | | Fixed (kernel quirk, 6.15) | | | Skipped: upstream | https://lkml.rescloud.iu.edu/2506.0/00257.html |
| Guide / QAM dead, dials | Buttons send Meta+F17 / Meta+F18 | Open (#5512, #5535) | | InputPlumber | Skipped: needs an InputPlumber config we can't test | https://github.com/ublue-os/bazzite/issues/5512 |
| Fan not detected | | Open (#3134) | | out-of-tree driver | Skipped: driver | https://github.com/ublue-os/bazzite/issues/3134 |

## Acer Predator Atlas 8, Nitro Blaze 7 / 8 / 11; Orange Pi Neo

| Fix | Symptom | Bazzite | SteamOS | Method | GameCove | Sources |
|---|---|---|---|---|---|---|
| Atlas 8 buttons | | Fixed (Bazzite InputPlumber config 70-acer_atlas8.yaml, testing) | | | Skipped: OS | bazzite `etc/inputplumber/devices.d/70-acer_atlas8.yaml` |
| Nitro Blaze | No reports with a fix | | | | Nothing found | - |
| Orange Pi Neo keys (66/67 -> F15/F16) | | Fixed (hwdb) | | | Skipped: upstream | InputPlumber hwdb |
| Orange Pi Neo controller dead after resume | | | | hhd devhide permission loop | Skipped: hhd-only (#317) | https://github.com/hhd-dev/hhd/issues/317 |

## GameCove's own fix

| Fix | What | GameCove | Source |
|---|---|---|---|
| quiet | While a game runs, GameCove's threads go to the LP-E cores (Atom cores without L3; all Atom cores, or none on AMD) at nice 10, back after. | **Shipped, auto** (every handheld; app-level, no root) | ClawDeck `py_modules/clawdeck/quiet.py` |
