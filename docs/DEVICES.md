# Devices

Which handhelds GameCove knows, what it can drive on each, and how to add one.
The data lives in [`app/data/devices.json`](../app/data/devices.json); button
profiles and glyphs in [`app/scripts/device/buttons.gd`](../app/scripts/device/buttons.gd);
detection in [`app/scripts/device/device.gd`](../app/scripts/device/device.gd).

Nothing here is invented from scratch: DMI ids, button maps and IMU presence
come from InputPlumber's device configs; TDP ranges from PowerStation's APU
database, steamos-manager's device files and Handheld Daemon's adjustor tables;
panels from maker spec pages. Values we couldn't confirm are listed in a row's
`unverified` field and the row has `"verified": false`, so the UI can say so.
Sources and licenses: [CREDITS.md](../CREDITS.md).

## Support levels

| Level | Meaning |
| --- | --- |
| `full` | Tested on the device by us (today: MSI Claw 8 EX). |
| `partial` | Every field comes from upstream data that was tested on the device (InputPlumber, steamos-manager, PowerStation, hhd), but we haven't run GameCove on it. |
| `generic` | Matched, but key values are guesses (no upstream config), or a family row / CPU fallback. |

`beta` (confirmed by testers) is still accepted for rows promoted later.

## Support matrix

TDP is `min / battery_max / plugged_max` watts. Fan shows the kernel interface and, in brackets, what GameCove drives it with today (empty = nothing yet). Paddles = back buttons.

| Device | id | Support | TDP W (min / battery / plugged) | Fan | Charge limit | Gyro | RGB | Buttons | Paddles | Glyphs | Verified |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Steam Deck (LCD) | `steam-deck-lcd` | partial | 3 / 15 / 15 | steamdeck_hwmon (steamos-manager) | yes (steamos-manager) | yes | – | `steam-deck` | 4 | deck | yes |
| Steam Deck (OLED) | `steam-deck-oled` | partial | 3 / 15 / 15 | steamdeck_hwmon (steamos-manager) | yes (steamos-manager) | yes | – | `steam-deck` | 4 | deck | yes |
| ASUS ROG Ally | `asus-rog-ally` | partial | 5 / 25 / 30 | asus_custom_fan_curve (fix) | yes (steamos-manager) | yes | inputplumber | `rog-ally` | 2 | xbox | yes |
| ASUS ROG Ally X | `asus-rog-ally-x` | partial | 5 / 25 / 30 | asus_custom_fan_curve (fix) | yes (steamos-manager) | yes | inputplumber | `rog-ally` | 2 | xbox | yes |
| ASUS ROG Xbox Ally | `asus-rog-xbox-ally` | partial | 4 / 20 / 20 | asus_custom_fan_curve (fix) | yes (steamos-manager) | yes | inputplumber | `rog-xbox-ally` | 2 | xbox | yes |
| ASUS ROG Xbox Ally X | `asus-rog-xbox-ally-x` | partial | 5 / 35 / 35 | asus_custom_fan_curve (fix) | yes (steamos-manager) | yes | inputplumber | `rog-xbox-ally` | 2 | xbox | yes |
| ASUS ROG Xbox Ally X20 | `asus-rog-xbox-ally-x20` | partial | 5 / 35 / 35 | asus_custom_fan_curve (fix) | yes (steamos-manager) | yes | inputplumber | `rog-xbox-ally` | 2 | xbox | no: tdp, panel.vrr |
| Lenovo Legion Go | `lenovo-legion-go` | partial | 5 / 30 / 30 | lenovo_wmi_other | – | yes | hhd | `legion-go` | 4 | xbox | no: charge_limit |
| Lenovo Legion Go 2 | `lenovo-legion-go-2` | partial | 5 / 30 / 35 | lenovo_wmi_other | – | yes | inputplumber | `legion-go-2` | 4 | xbox | no: tdp, charge_limit, panel.vrr |
| Lenovo Legion Go 2 (Z2) | `lenovo-legion-go-2-z2` | partial | 5 / 30 / 35 | lenovo_wmi_other | – | yes | inputplumber | `legion-go-2` | 4 | xbox | no: tdp, charge_limit, panel.vrr, chip |
| Lenovo Legion Go S (Z2 Go) | `lenovo-legion-go-s-z2go` | partial | 5 / 30 / 33 | lenovo_wmi_other | – | yes | inputplumber | `legion-go-s` | 2 | xbox | no: charge_limit |
| Lenovo Legion Go S (Z1 Extreme) | `lenovo-legion-go-s-z1e` | partial | 5 / 30 / 33 | lenovo_wmi_other | – | yes | inputplumber | `legion-go-s` | 2 | xbox | no: charge_limit |
| MSI Claw 8 EX AI+ | `msi-claw-8-ex` | full | 8 / 35 / 35 | msi_wmi_platform (fix) | yes (fix) | fix | hhd | `msi-claw-8-ex` | 2 | xbox | yes |
| MSI Claw 8 AI+ | `msi-claw-8-ai-plus` | partial | 8 / 30 / 30 | msi_wmi_platform (fix) | yes (steamos-manager) | no | hhd | `msi-claw` | 2 | xbox | no: panel.vrr |
| MSI Claw 7 AI+ | `msi-claw-7-ai-plus` | partial | 8 / 30 / 30 | msi_wmi_platform (fix) | yes (steamos-manager) | no | hhd | `msi-claw` | 2 | xbox | no: panel |
| MSI Claw A1M | `msi-claw-a1m` | partial | 8 / 35 / 43 | msi_wmi_platform (fix) | yes (steamos-manager) | yes | hhd | `msi-claw` | 2 | xbox | yes |
| MSI Claw A8 | `msi-claw-a8` | partial | 8 / 35 / 35 | msi_wmi_platform (fix) | yes (steamos-manager) | yes | hhd | `msi-claw` | 2 | xbox | no: panel.vrr |
| MSI Claw (unknown model) *(family)* | `msi-claw-family` | generic | 8 / 25 / 30 | msi_wmi_platform (fix) | – | unknown | – | `msi-claw` | 2 | xbox | no: tdp, panel, chip, buttons |
| OneXFly F1 | `onexplayer-onexfly-f1` | partial | 5 / 28 / 30 | oxp_ec (fix) | yes (sysfs) | yes | inputplumber | `oxp-f1` | 1 | xbox | no: panel.vrr |
| OneXFly F1 Pro | `onexplayer-onexfly-f1-pro` | partial | 5 / 30 / 30 | oxp_ec (fix) | yes (sysfs) | yes | inputplumber | `oxp-f1` | 1 | xbox | no: panel.vrr |
| OneXPlayer X1 (AMD) | `onexplayer-x1-amd` | partial | 5 / 28 / 30 | oxp_ec (fix) | yes (sysfs) | yes | inputplumber | `oxp-x1` | 2 | xbox | no: tdp, panel.vrr |
| OneXPlayer X1 (Intel) | `onexplayer-x1-intel` | partial | 8 / 28 / 35 | oxp_ec (fix) | yes (sysfs) | yes | inputplumber | `oxp-x1` | 2 | xbox | no: tdp, panel.vrr |
| OneXPlayer X1 Mini | `onexplayer-x1-mini` | partial | 5 / 28 / 30 | oxp_ec (fix) | yes (sysfs) | yes | inputplumber | `oxp-x1` | 2 | xbox | no: tdp, panel.vrr |
| OneXPlayer X1 Pro | `onexplayer-x1-pro` | partial | 4 / 30 / 30 | oxp_ec (fix) | yes (sysfs) | yes | inputplumber | `oxp-x1` | 2 | xbox | no: dmi, buttons, panel |
| OneXPlayer 2 | `onexplayer-2` | partial | 5 / 28 / 33 | oxp_ec (fix) | – | yes | – | `oxp-2` | 0 | xbox | yes |
| OneXPlayer 2 Pro | `onexplayer-2-pro` | partial | 5 / 30 / 30 | oxp_ec (fix) | – | yes | – | `oxp-2` | 0 | xbox | yes |
| OneXPlayer G1 (AMD) | `onexplayer-g1-amd` | partial | 5 / 30 / 35 | oxp_ec (fix) | yes (sysfs) | none | – | `oxp-g1` | 0 | xbox | no: tdp, panel.vrr, chip |
| OneXPlayer G1 (Intel) | `onexplayer-g1-intel` | partial | 8 / 30 / 35 | oxp_ec (fix) | yes (sysfs) | none | – | `oxp-g1` | 0 | xbox | no: tdp, panel.vrr, chip |
| OneXPlayer 3 | `onexplayer-3` | partial | 8 / 35 / 35 | oxp_ec (fix) | yes (sysfs) | yes | – | `oxp-x2` | 2 | xbox | no: panel.resolution, panel.vrr |
| OneXPlayer X2 Mini | `onexplayer-x2-mini` | generic | 3 / 30 / 45 | oxp_ec (fix) | yes (sysfs) | yes | – | `oxp-x2` | 2 | xbox | no: chip, panel, tdp |
| OneXFly Apex | `onexplayer-onexfly-apex` | partial | 8 / 35 / 35 | oxp_ec (fix) | yes (sysfs) | yes | inputplumber | `oxp-apex` | 2 | xbox | no: panel, tdp |
| OneXPlayer Super X | `onexplayer-super-x` | generic | 8 / 45 / 80 | oxp_ec (fix) | yes (sysfs) | unknown | – | `generic` | 0 | xbox | no: buttons, panel, tdp.battery_max |
| OneXPlayer (unknown model) *(family)* | `onexplayer-family` | generic | 5 / 25 / 28 | oxp_ec (fix) | – | unknown | – | `oxp-generic` | 0 | xbox | no: tdp, panel, chip, buttons |
| AOKZOE A1 | `aokzoe-a1` | partial | 5 / 28 / 33 | oxp_ec (fix) | – | yes | oxp-ec | `aokzoe` | 0 | xbox | no: panel |
| AOKZOE A1 Pro | `aokzoe-a1-pro` | partial | 5 / 30 / 30 | oxp_ec (fix) | – | yes | oxp-ec | `aokzoe` | 0 | xbox | no: panel |
| AOKZOE A1X | `aokzoe-a1x` | partial | 5 / 30 / 30 | oxp_ec (fix) | – | yes | – | `aokzoe` | 0 | xbox | no: panel, chip, tdp |
| AOKZOE (unknown model) *(family)* | `aokzoe-family` | generic | 5 / 25 / 28 | oxp_ec (fix) | – | unknown | – | `aokzoe` | 0 | xbox | no: tdp, panel, chip, buttons |
| AYANEO 2S | `ayaneo-2s` | partial | 5 / 28 / 28 | ayaneo_ec (fix) | yes (sysfs) | yes | ayaneo-ec | `aya-classic` | 0 | xbox | no: charge_limit |
| AYANEO 2 | `ayaneo-2` | partial | 5 / 28 / 33 | ayaneo_ec (fix) | yes (sysfs) | yes | ayaneo-ec | `aya-classic` | 0 | xbox | no: charge_limit |
| AYANEO KUN | `ayaneo-kun` | partial | 5 / 30 / 30 | ayaneo_ec (fix) | yes (sysfs) | yes | ayaneo-ec | `aya-kun` | 0 | xbox | no: charge_limit, tdp |
| AYANEO AIR 1S | `ayaneo-air-1s` | partial | 5 / 25 / 25 | ayaneo_ec (fix) | yes (sysfs) | yes | ayaneo-ec | `aya-classic` | 0 | xbox | no: charge_limit |
| AYANEO AIR Plus | `ayaneo-air-plus` | partial | 5 / 28 / 28 | ayaneo_ec (fix) | – | yes | ayaneo-ec | `aya-classic` | 0 | xbox | no: chip |
| AYANEO Flip | `ayaneo-flip` | partial | 5 / 28 / 28 | ayaneo_ec (fix) | – | yes | – | `aya-classic` | 0 | xbox | no: tdp, panel.vrr |
| AYANEO Flip 1S DS | `ayaneo-flip-1s-ds` | partial | 5 / 30 / 30 | ayaneo_ec (fix) | – | yes | – | `aya-flip-1s` | 2 | xbox | no: chip, panel, tdp |
| AYANEO 3 | `ayaneo-3` | partial | 5 / 30 / 30 | ayaneo_ec (fix) | yes (sysfs) | yes | inputplumber | `aya-3` | 0 | xbox | no: tdp, panel, charge_limit |
| AYANEO Slide | `ayaneo-slide` | partial | 5 / 28 / 28 | ayaneo_ec (fix) | – | yes | ayaneo-ec | `aya-classic` | 0 | xbox | no: tdp |
| AYANEO (unknown model) *(family)* | `ayaneo-family` | generic | 5 / 25 / 28 | ayaneo_ec (fix) | – | unknown | – | `aya-classic` | 0 | xbox | no: tdp, panel, chip, buttons |
| GPD WIN 4 | `gpd-win-4` | partial | 5 / 28 / 28 | gpdfan (fix) | – | yes | – | `gpd-win4` | 1 | xbox | no: chip |
| GPD WIN Mini | `gpd-win-mini` | partial | 5 / 28 / 28 | gpdfan (fix) | – | yes | – | `gpd-win4` | 1 | xbox | no: chip, panel.vrr |
| GPD WIN Max 2 | `gpd-win-max-2` | partial | 5 / 28 / 28 | gpdfan (fix) | – | yes | – | `gpd-winmax2` | 2 | xbox | no: chip |
| GPD WIN 5 | `gpd-win-5` | partial | 4 / 50 / 85 | gpdfan (fix) | – | yes | – | `gpd-win5` | 2 | xbox | no: tdp.battery_max, panel |
| GPD (unknown model) *(family)* | `gpd-family` | generic | 5 / 25 / 28 | gpdfan (fix) | – | unknown | – | `gpd-win4` | 1 | xbox | no: tdp, panel, chip, buttons |
| ZOTAC Gaming Zone | `zotac-zone` | partial | 5 / 28 / 30 | zotac_zone_platform (fix) | – | yes | inputplumber | `zotac-zone` | 2 | xbox | no: tdp, charge_limit |
| Acer Predator Atlas 8 | `acer-predator-atlas-8` | partial | 8 / 30 / 40 | – | – | unknown | – | `acer-atlas` | 2 | xbox | no: tdp, panel.vrr, gyro |
| Acer Nitro Blaze 7 | `acer-nitro-blaze-7` | generic | 5 / 28 / 30 | – | – | unknown | – | `acer-blaze` | 0 | xbox | no: dmi, buttons, tdp, panel.vrr, gyro |
| Acer Nitro Blaze 8 | `acer-nitro-blaze-8` | generic | 5 / 28 / 30 | – | – | unknown | – | `acer-blaze` | 0 | xbox | no: dmi, buttons, tdp, panel.vrr, gyro |
| Acer Nitro Blaze 11 | `acer-nitro-blaze-11` | generic | 5 / 28 / 30 | – | – | unknown | – | `acer-blaze` | 0 | xbox | no: dmi, buttons, tdp, panel.vrr, gyro |
| Orange Pi Neo | `orangepi-neo` | partial | 8 / 28 / 28 | – | – | yes | – | `orangepi-neo` | 0 | xbox | no: panel.vrr |

## Matching

`Device.detect()` reads `/sys/class/dmi/id/{sys_vendor,product_name,board_name,board_vendor,product_family}`, `/proc/cpuinfo` and `/sys/class/drm/card*/device/uevent`, then:

1. Every row's `match` is tried. `match` is one object or a list of objects (any may match). Inside an object every key must match one of its glob patterns (`*`, `?`, case-insensitive), like InputPlumber's `dmi_data`. A key the caller didn't read is skipped, but at least one key must be compared.
2. The best match wins: `tier` first (`specific` > `family`), then how many keys matched, then exact (wildcard-free) hits. Family rows (`msi-claw-family`, `onexplayer-family`, `ayaneo-family`, `aokzoe-family`, `gpd-family`) catch new models of handheld-only makers.
3. Rows sold with several chips (`chip_from_cpu: true`) and family rows take `chip`, `cpu_vendor`, `gpu_family`, `gpu_arch`, `xmx` from the CPU table (`cpus` in devices.json); family rows also take its TDP range.
4. No match: a `generic` row is built from the CPU table (or, failing that, conservative AMD 5–20 W / Intel 8–25 W and the GPU driver: `xe` means Xe2 or newer). It has `id: "unknown"`, `support: "generic"`, the generic picture and Xbox glyphs.

The tests check that each real DMI fixture (`app/tests/fixtures/devices/dmi.json`) resolves to exactly one specific row, that common laptops and the Steam Machine resolve to nothing, and that every specific row has a fixture.

## Fields

| Field | Meaning |
| --- | --- |
| `id` | Stable id, lower-case words joined by `-`. |
| `name`, `maker`, `family` | Display name, maker, and a family key shared by similar models. |
| `tier` | `specific` or `family` (see Matching). |
| `match` | DMI patterns (see Matching). Keys: `sys_vendor`, `product_name`, `board_name`, `board_vendor`, `product_family`. |
| `chip`, `cpu_vendor` | APU name; `amd` or `intel`. `chip_from_cpu: true` when the CPU decides. |
| `gpu`, `gpu_family`, `gpu_arch`, `xmx` | GPU name; `gpu_family` is what the launcher keys upscalers on (`amd-vega`, `amd-rdna2`, `amd-rdna3` (also RDNA 3.5, for the FSR 4 RDNA 3 path), `intel-xe-lpg`, `intel-xe2`, `intel-xe3`); `gpu_arch` the exact architecture (`RDNA2`, `RDNA3`, `RDNA3.5`, `Xe-LPG`, `Xe2`, `Xe3`, `Vega`); `xmx` = Intel XMX cores for XeSS. |
| `panel` | `{size_in, resolution: [w, h], type: IPS/OLED}`. |
| `panel_hz`, `vrr_range` | Native refresh `[min, max]` (the UI offers rates inside it); VRR window `[lo, hi]` or `null`. |
| `tdp` | `{min, battery_max, plugged_max, boost_max?}` watts. `min < battery_max <= plugged_max`, `boost_max >= plugged_max`. |
| `profiles` | Watts for `battery` / `balanced` / `performance`, inside `min..battery_max`. Missing: Power spreads the range. |
| `pl2_offset_w` | Intel: PL2 = TDP + this. |
| `tdp_backends` | Power services to try in order: `steamos-manager`, `powerstation`. |
| `power_backend` | What actually writes the limit under those services (informational): `intel-rapl`, `intel-rapl-mmio`, `powerstation`, `steamos-manager`. |
| `fan`, `fan_via` | Kernel fan interface (hwmon name or driver: `steamdeck_hwmon`, `msi_wmi_platform`, `asus_custom_fan_curve`, `lenovo_wmi_other`, `oxp_ec`, `ayaneo_ec`, `gpdfan`, `zotac_zone_platform`); how GameCove drives it today (`steamos-manager`, `fix`, or `null` = not yet). |
| `charge_limit`, `charge_limit_via` | Battery charge limit available; through `steamos-manager`, the `charge-limit` fix (`fix`) or a kernel battery control (`sysfs`: `charge_control_end_threshold`, or `charge_behaviour` on AYANEO), which Power also writes through the `charge-limit` fix. Power reads this flag. |
| `gyro`, `imu` | `yes` (works through InputPlumber), `fix` (needs a GameCove fix), `no` (sensor present, not on Linux yet), `none` (no sensor), `unknown`; `imu` names the sensor. |
| `rgb` | `null` or `{zones, via}`; `via` is who drives the LEDs (`inputplumber`, `hhd`, `ayaneo-ec`, `oxp-ec`). |
| `buttons`, `glyphs`, `art` | Button profile in buttons.gd, glyph set (`xbox`, `deck`), picture in `app/assets/devices/art/`. |
| `fixes` | Root fixes the Device page offers (folder names in `fixes/`). |
| `quirks` | Known issues, one sentence each. |
| `support`, `verified`, `unverified`, `sources` | Support level; `verified` is true exactly when `unverified` (field names that are best guesses) is empty; where the values came from. |

## Buttons

Each device's special buttons, as InputPlumber reports them (Gamepad:Button:&lt;capability&gt;):

| Profile | Special buttons → InputPlumber capability | Back buttons | Source |
| --- | --- | --- | --- |
| `generic` | Guide → Guide | – | InputPlumber generic gamepad |
| `steam-deck` | STEAM → Guide; Quick Access (…) → QuickAccess | L4 = LeftPaddle1, L5 = LeftPaddle2, R4 = RightPaddle1, R5 = RightPaddle2 | InputPlumber steam_deck driver |
| `rog-ally` | Command Center → Guide; Command Center (hold) → Keyboard; Armoury Crate → QuickAccess; Armoury Crate (hold) → QuickAccess2 | M1 = LeftPaddle1, M2 = RightPaddle1 | InputPlumber ally_type1 |
| `rog-xbox-ally` | Xbox button → Guide; Armoury Crate → Keyboard; Armoury Crate (hold) → LeftPaddle2; Library → QuickAccess; Library (hold) → QuickAccess2 | M1 = LeftPaddle1, M2 = RightPaddle1 | InputPlumber ally_type2 |
| `legion-go` | Legion L → Guide; Legion R → QuickAccess; M1 → LeftStickTouch; M2 → RightStickTouch | Y1 = LeftPaddle1, Y2 = LeftPaddle2, Y3 = RightPaddle1, M3 = RightPaddle2 | InputPlumber legion_go driver (go1) |
| `legion-go-2` | Legion L → Guide; Legion R → QuickAccess; Desktop (⧉) → Keyboard; Menu (☰) → QuickAccess2 | Y1 = LeftPaddle1, Y2 = LeftPaddle2, Y3 = RightPaddle1, M3 = RightPaddle2 | InputPlumber legion_go driver (go2) |
| `legion-go-s` | Legion L → Guide; Legion R → QuickAccess | Y1 = LeftPaddle1, Y2 = RightPaddle1 | InputPlumber legion_go_s driver |
| `msi-claw` | MSI Center M → Guide; Quick Settings → QuickAccess; Quick Settings (hold) → QuickAccess2 | M2 = LeftPaddle1, M1 = RightPaddle1 | InputPlumber msiclaw_type1 |
| `msi-claw-8-ex` | MSI Center M → Guide; Quick Settings → QuickAccess | M2 = LeftPaddle1, M1 = RightPaddle1 | InputPlumber msiclaw_type2, tested on the device |
| `oxp-generic` | Home (orange) → Guide; Home (hold) → QuickAccess2; Turbo → QuickAccess; Keyboard → Keyboard; Turbo + Home → Screenshot | – | InputPlumber onexplayer_type3 |
| `oxp-f1` | Home (orange) → Guide; Home (hold) → QuickAccess2; Turbo → QuickAccess; Keyboard → Keyboard; Turbo + Home → Screenshot | M2 = RightPaddle1 | InputPlumber onexplayer_type7 |
| `oxp-apex` | Home (orange) → Guide; Home (hold) → QuickAccess2; Turbo → QuickAccess; Keyboard → Keyboard; Turbo + Home → Screenshot | M1 = LeftPaddle1, M2 = RightPaddle1 | InputPlumber onexplayer_type8 |
| `oxp-x1` | Turbo → Keyboard; Keyboard button → QuickAccess; Keyboard button (controller mode) → QuickAccess2 | M1 = LeftPaddle1, M2 = RightPaddle1 | InputPlumber onexplayer_type5 |
| `oxp-2` | Turbo → QuickAccess | – | InputPlumber onexplayer_type4 |
| `oxp-g1` | Home → Guide; Home (hold) → QuickAccess2; Turbo → QuickAccess | – | InputPlumber onexplayer_type6 |
| `oxp-x2` | OneX button → QuickAccess; Keyboard button → QuickAccess2 (overrides: QuickAccess2: osk) | M1 = LeftPaddle1, M2 = RightPaddle1 | InputPlumber onexplayer_type9 |
| `aokzoe` | Home (orange) → Guide; Home (hold) → QuickAccess2; Turbo → QuickAccess; Keyboard → Keyboard; Turbo + Home → Screenshot | – | InputPlumber onexplayer_type3 |
| `aya-classic` | AYA Space → Guide; Custom → QuickAccess; LC → LeftTop; RC → RightTop; Second screen (Flip DS) → Keyboard | – | InputPlumber ayaneo_type4 |
| `aya-kun` | AYA Space → QuickAccess2; Custom → QuickAccess; LC → LeftTop; RC → RightTop; T → RightTop (overrides: QuickAccess2: home) | – | InputPlumber ayaneo_type6 |
| `aya-3` | AYA Space → Guide; Quick Access → QuickAccess; LC → LeftTop; RC → RightTop | – | InputPlumber ayaneo_type7 |
| `aya-flip-1s` | AYA Space → QuickAccess; LC → LeftTop; RC → RightTop | L = LeftPaddle2, R = RightPaddle2 | InputPlumber ayaneo_type8 |
| `gpd-win4` | R4 (back) → QuickAccess | L4 = LeftPaddle1 | InputPlumber gpd_type3 |
| `gpd-winmax2` | – | L4 = LeftPaddle1, R4 = RightPaddle1 | InputPlumber gpd_type2 |
| `gpd-win5` | Home → Guide; Mode switch → QuickAccess; Keyboard → Keyboard | L4 = LeftPaddle1, R4 = RightPaddle1 | InputPlumber gpd_type4 |
| `zotac-zone` | ZOTAC button → Guide; More (…) → QuickAccess; Home → QuickAccess2; Home (hold) → Keyboard (overrides: QuickAccess2: home) | M1 = LeftPaddle1, M2 = RightPaddle1 | InputPlumber zone_buttons |
| `acer-atlas` | Guide (hold) → Guide; Quick Access → QuickAccess; Quick Access (hold) → QuickAccess2 | M2 = LeftPaddle1, M1 = RightPaddle1 | Bazzite acer_atlas8_hid_type1/2 |
| `acer-blaze` | Guide → Guide; Quick Access → QuickAccess | – | guess: no InputPlumber config yet |
| `orangepi-neo` | Guide → Guide; Quick Access → QuickAccess; LC → LeftTop; RC → RightTop | – | InputPlumber orangepi_type1 |

Default GameCove actions (`Buttons.DEFAULT_ACTIONS`, overridable per profile): **Guide → GameCove home**, **QuickAccess → quick menu**, **Keyboard → on-screen keyboard**, **Screenshot → screenshot**. QuickAccess2, LeftTop/RightTop and the paddles pass through to Steam or the game unless a profile says otherwise (Zotac Zone's and AYANEO KUN's Home buttons arrive as QuickAccess2 and open home; OneXPlayer 3 / X2 Mini's keyboard button arrives as QuickAccess2 and opens the keyboard). Devices without a button for an action (GPD WIN Max 2 has no Guide, for example) get `Buttons.FALLBACK_CHORDS`: QuickAccess + A for home, QuickAccess + Y for the keyboard, QuickAccess + RB for a screenshot.

### What the Input service must do

InputPlumber already turns every special button into a capability (above). To get them to GameCove inside gamescope without fighting Steam, do what OpenGamepadUI does (`core/ui/card_ui/card_ui.gd`):

1. On start, and for every new composite device (service `org.shadowblip.InputPlumber`, objects `/org/shadowblip/InputPlumber/CompositeDeviceN`, interface `org.shadowblip.Input.CompositeDevice`; the manager is `/org/shadowblip/InputPlumber/Manager`), call `SetInterceptActivation(["Gamepad:Button:Guide"], "Gamepad:Button:Guide")`.
2. While GameCove's own UI has focus, set the `InterceptMode` property to `2` (Always): every input goes to InputPlumber's D-Bus target instead of the virtual gamepad, so a game in the background sees nothing. Listen to `org.shadowblip.Input.DBusDevice.InputEvent(event s, value d)` on the composite device's D-Bus target (`/org/shadowblip/InputPlumber/devices/target/dbusN`; the composite device's `TargetDevices` property lists it) and map `event` with `Buttons.action_for_dbus(device_id, event)`: `ui_guide` → home, `ui_quick` → quick menu, `ui_osk` → keyboard, `ui_screenshot` → screenshot, `ui_accept`/`ui_back`/... → navigation. Value 1.0 = pressed, 0.0 = released.
3. While a game has focus, set `InterceptMode` to `1` (Pass): everything reaches the game's virtual controller except the activation button. When Guide is pressed InputPlumber switches the device to Always and emits `ui_guide`; GameCove opens its home or quick menu and sets the mode back to `1` when it closes.
4. QuickAccess: InputPlumber's Xbox targets turn QuickAccess into Guide + A, which Steam reads as its Quick Access Menu. To open GameCove's quick menu instead from inside a game, use OpenGamepadUI's overlay approach: `SetInterceptActivation(["Gamepad:Button:Guide", "Gamepad:Button:East"], "Gamepad:Button:QuickAccess2")`, or load a per-device profile (`LoadProfileFromYaml`) that maps QuickAccess to a DBus action. Only do this when GameCove is the session's main app; under Steam's own session leave InputPlumber alone.
5. Steam games: Steam Input talks to InputPlumber's virtual controller (`deck-uhid` on steamos-manager setups, `xbox-elite` otherwise) like any pad. In Pass mode Steam keeps its Guide/QAM chords for everything except the intercepted button, so Steam's overlay still works.
6. `InterceptMode` 3 (GamepadOnly) is available on newer InputPlumber: gamepad input goes to D-Bus but keyboard and mouse still reach the focused window, useful for the on-screen keyboard.

The capability strings are the same names buttons.gd uses, so `Buttons.capabilities(device_id)` tells the Input service which ones to expect.

## Glyphs and pictures

- `Buttons.glyph_for(name, device)` → `res://assets/devices/glyphs/…svg` for an action (`accept`, `back`, `option`, `context`, `menu`, `view`, `tab_left`, `tab_right`, `page_left`, `page_right`, `home`, `quick_menu`, `osk`, `screenshot`), a capability (`South`, `Guide`, `LeftPaddle1`…) or a special-button id (`armoury_crate`). Never empty. Sets: `xbox` (A/B/X/Y, LB/RB/LT/RT, View/Menu) and `deck` (the Deck's own L1/R1/L2/R2/L4/L5/R4/R5, STEAM and … buttons). No current handheld uses PlayStation labels, so there's no PlayStation set. Special buttons get abstract icons (house, sliders, keyboard, camera, letters), never a maker's logo.
- `Device.picture_for(device_id)` / `Device.picture()` → `res://assets/devices/art/<art>.svg`, a flat front view of the layout. Parts carry ids named after capabilities so a controller page can light one up: `btn-South`, `btn-Guide`, `btn-QuickAccess`, `btn-DPadUp` (inside `btn-DPad`), `btn-LeftStick` (inside `axis-LeftStick`), `btn-LeftBumper`, `btn-LeftTrigger`, `btn-LeftPaddle1` (back buttons, dashed, under the body), `pad-Left`/`pad-Right` (trackpads), `dial-Left`/`dial-Right`, `part-screen`, `part-body`.
- Both are generated by `app/assets/devices/_tools/gen_svgs.py` (run `python3 -I app/assets/devices/_tools/gen_svgs.py app/assets/devices`). Add a glyph or layout there rather than drawing by hand, so the style stays the same.

## Real photos

"About this device" and the first-run welcome show a real photo of the handheld when there's a freely licensed one, with a credit line under it ("Photo: <author>, <license>", A opens the Commons page). No photo, offline, or "Show a real photo of my device" switched off (Settings > Device; on by default): the drawing from `Device.picture_for` shows, as before.

- `app/data/device_photos.json`: `{device_id: {file, author, license, license_url, page_url, family_of?, note?}}`. `file` is the Commons file name without `File:`. A Flickr photo uses `"source": "openverse", "openverse_id": "<uuid>"` instead of `file`, with `page_url` = the Flickr photo page. `_manual` lists candidates the build can't fetch (see below).
- `.github/workflows/device-photos.yml` (weekly + manual) runs `tools/device_photos/build.py`: re-checks each license at its source (Commons API `extmetadata.LicenseShortName`; for Flickr, Openverse's image API, since Flickr's own API needs a key), skips anything not on the allowlist with a `::warning::` on the run, downloads a 1200 px rendition, converts it to WebP and uploads it plus `manifest.json` (`{devices: {id: {asset, sha256, size, credit}}}`) to the rolling `device-photos` release. If Commons is down, a device keeps last week's entry. User-Agent: `GameCove/<version> (+https://github.com/IHulkSmashI/GameCove)`, per Wikimedia's policy.
- `DevicePhoto` (`app/scripts/device/photo.gd`, autoload): `photo_for(device_id) -> {} | {path, credit}` never blocks. A miss fetches the manifest (at most once a week, one try per session) and then only this device's file, once, checks size and sha256 against the manifest and keeps it in `user://device_photos/`; `photo_ready(device_id, path)` follows. The app re-applies the license allowlist to the manifest, so a bad build can't push a non-free photo.
- UI: `app/scripts/ui/device/device_photo_view.gd` (`make(photo, height, open_link)` returns null when there's nothing to show). About and setup call it from one small function each (`_device_photo_hook`).

### License rules

- Only Wikimedia Commons files, or Flickr photos found through [Openverse](https://openverse.org/), under **CC0, public domain, CC BY or CC BY-SA** (any version). Unsplash/Pexels photos can't be re-checked automatically without an API key, so they go through Commons first, like YouTube frames (below). Press-kit images only if their terms explicitly allow redistribution in software; "editorial use only" isn't enough. No NonCommercial (NC), NoDerivatives (ND), GFDL-only, "fair use" or other non-free files, even if Wikipedia uses them.
- No press or marketing images, even if someone uploaded them as their own work: an unsourced, studio-clean product render is almost always one (`ROG Xbox Ally X.jpg` on Commons is an example; we use `ROG XBOX ALLY X.jpg`, a store photo, instead). Prefer files with `{{own}}` as source, a Flickr/YouTube license review, or a `LicenseReview` template.
- Always credit author and license with a link; the in-app credit line and the CREDITS.md table do this.
- Prefer a straight front view with the screen visible, a plain background and no faces. Hands are fine if there's nothing better.
- `family_of` reuses another model's photo only when the two look the same from the front (same shell; e.g. AOKZOE A1 Pro and A1). Different shells (Claw A1M vs Claw 8 AI+, Legion Go vs Legion Go 2) don't share.

### Adding a photo

1. Find a file on Commons (search the device's category, `Category:Handheld gaming computers`, or Tokyo Game Show / Computex categories), or a Flickr photo on Openverse (`https://api.openverse.org/v1/images/?q=<model>&license=by,by-sa,cc0,pdm`; the result's `id` is the `openverse_id`). Open the source page and check the license and that it's really the uploader's photo.
2. Add an entry to `app/data/device_photos.json` (copy an existing one; `page_url` is `https://commons.wikimedia.org/wiki/File:` + the name with spaces as `_`).
3. Add a row to the "Device photos" table in CREDITS.md.
4. Run `python -m pytest -q tools/device_photos` and the Godot tests (`test_device_photo.gd` checks every entry), then run the workflow by hand from the Actions tab.

### YouTube frames (manual)

Some reviewers (Booredatwork.com, Tame That Tech, RetroBoy, GPD's own channel and others) publish under CC BY on YouTube. YouTube refuses scripted access from servers ("confirm you're not a bot"), so the workflow can't check the license or grab a frame. `_manual` in `device_photos.json` lists, per model, videos that came up under YouTube's Creative Commons filter. To turn one into a photo, on your own computer:

1. Open the video and check the description box says "Creative Commons Attribution license (reuse allowed)". If not, skip it.
2. Find a clean front view (screen on, no faces) and note the time, e.g. `1:23`.
3. Grab the frame at full resolution: `yt-dlp -f "bv*[height<=2160]" --download-sections "*83-84" -o clip.mp4 <url>` then `ffmpeg -ss 0.3 -i clip.mp4 -frames:v 1 frame.png`. Crop to the device if needed.
4. Upload `frame.png` to Commons (Upload Wizard, "This file is not my own work", source = the video URL, author = the channel, license `{{YouTube CC-BY|<channel>}}`, plus `{{From YouTube|<id>}}`). A reviewer or bot confirms the license (the Claw A1M photo went this way).
5. Add a normal Commons entry for the device, remove it from `_manual`, add the CREDITS.md row, run the tests and the workflow.

No free photo of your handheld? Take one and upload it to Commons as your own work under CC0 or CC BY-SA 4.0: front view, screen on, straight on at screen height, on a plain light or dark background, in soft even light (daylight from a window or two lamps from the sides, no flash), no reflections of you on the screen, at least 2000 px wide. Testers can also offer one in the tester sign-up form.

## Adding a device

1. Find its DMI ids: `cat /sys/class/dmi/id/{sys_vendor,product_name,board_name,board_vendor}` (or the InputPlumber config in `rootfs/usr/share/inputplumber/devices/`). Add them to `app/tests/fixtures/devices/dmi.json` with `"expect": "<new id>"` and where they came from.
2. Copy this template into `devices.json` and fill it in; put anything you guessed into `unverified`:

```json
{
  "id": "maker-model",
  "name": "Maker Model",
  "maker": "Maker",
  "family": "maker-line",
  "tier": "specific",
  "match": {"sys_vendor": ["Maker"], "product_name": ["Exact Product Name"]},
  "chip": "AMD Ryzen Z2 Extreme", "cpu_vendor": "amd",
  "gpu": "Radeon (RDNA 3.5)", "gpu_family": "amd-rdna3", "gpu_arch": "RDNA3.5", "xmx": false,
  "panel": {"size_in": 7.0, "resolution": [1920, 1080], "type": "IPS"},
  "panel_hz": [48, 120], "vrr_range": [48, 120],
  "tdp": {"min": 5, "battery_max": 25, "plugged_max": 30},
  "tdp_backends": ["steamos-manager", "powerstation"],
  "fan": null, "fan_via": null,
  "charge_limit": false, "charge_limit_via": null,
  "gyro": "unknown", "imu": null, "rgb": null,
  "buttons": "generic", "glyphs": "xbox", "art": "generic",
  "fixes": [], "quirks": [],
  "support": "generic", "verified": false, "unverified": ["tdp", "panel"],
  "sources": ["where each value came from"]
}
```

3. If its special buttons differ from an existing profile, add one to `Buttons.PROFILES` from its InputPlumber capability map, and a picture to `gen_svgs.py` if no existing layout fits.
4. Run the tests: `godot --headless --path app -s res://tests/run_tests.gd`. `Device.row_problems(row)` is the schema check (required fields, `min < battery_max <= plugged_max`, profiles inside the range, refresh and VRR ranges, known enum values); the detection tests catch overlapping DMI patterns.
5. Credit new sources in CREDITS.md.
6. Optional: add a real photo (see "Real photos" above).

## One drive, several handhelds

Bazzite on an external SSD boots on more than one handheld (for example an MSI Claw 8 EX AI+, a ROG Ally and a Legion Go S). GameCove detects the handheld at every start (`Device.detect()`, DMI) and is built so that nothing set up for one handheld acts on another.

### Secure Boot, per handheld

Each handheld keeps its own Secure Boot keys in its own firmware, not on the drive. With Secure Boot on, enroll Bazzite's key once on **each** handheld: boot the drive on it, run `ujust enroll-secure-boot-key` (password `universalblue`), restart, and confirm in the blue MokManager screen. Until then that handheld refuses the drive's kernel. Boot order (USB/SSD first) is also set per handheld in its firmware setup. Nothing GameCove installs changes this: the drive's boot entries and kernel arguments are shared, so GameCove adds no device-specific kernel argument.

### What is per handheld

| What | How it's kept apart |
| --- | --- |
| Claw VRR fix (`claw8ex-vrr`) | No kernel argument. A modprobe hook gives the Intel GPU driver the patched EDID only when `board_name` is the board it was installed on. The Ally and Legion Go S use AMD's driver, so the hook never even runs there. Older installs (kernel arguments) are moved over by `install` or a root `status`; seen from another handheld, the old install is removed. |
| Claw gyro fix (`claw8ex-gyro`) | Its two services have `ExecCondition` on board MS-1T91 and are skipped elsewhere. The firmware search path (`firmware_class.path=/etc/firmware`) and the HID-BPF program (matched to the Claw's sensor hub id) do nothing on other hardware. |
| Claw buttons fix (`claw8ex-buttons`) | InputPlumber override with the stock `dmi_data: board_name: MS-1T91` match, so InputPlumber only uses it on the Claw. |
| Fan and charge-limit fixes | Only act on handhelds in `fixes/lib/handhelds.txt`. What they saved (the values `remove` writes back) is kept per handheld (`/var/lib/gamecove/fixes/<fix>/device`, others parked in `devices/<id>/`). |
| TDP profile, custom watts, charge limit, fan preset | `user://power.cfg`, sections `<name>@<device id>`. |
| Controller layouts and per-game controller profiles | `~/.config/inputplumber/profiles/gamecove/<device id>/`. |
| Measured frame rates (frame generation hint) | `user://launch_settings.json`, `measured.<device id>`. |
| Controller service | Detected at start: InputPlumber (Bazzite's default on every handheld today) or Handheld Daemon if you installed it. The controller page only shows what that service can do on this handheld (`Controller.state()["capabilities"]`). |
| TDP service | Detected at start: Handheld Daemon when its TDP plugin is on (then GameCove sets TDP through it and leaves fan and charge limit to it), else steamos-manager / PowerStation. |

Values saved by an older GameCove belong to no handheld yet; the first handheld that starts the new version takes them over. Start the update on the handheld you set them on.

### What is shared

- Library, store sign-ins, Discover, wishlist, achievements, theme and look, the overlay level, Steam itself.
- A game's settings (goal, frame limit, upscaler, frame generation, low latency). They resolve per handheld at launch: upscaler **Auto** is XeSS on the Claw (Intel Xe, with the XeSS XMX driver), FSR 4 on the Ally and Legion Go S (AMD, with a Proton that has it). An explicit **XeSS** picked on the Claw falls back to Auto on an AMD handheld, with a note on the launch screen; the saved choice stays XeSS for the Claw.
- The drive's OS, kernel arguments, initramfs and boot entries. Root fixes are installed once per drive but only act on their handheld (above).
- Handheld Daemon, if installed, keeps its own settings per device type in `/etc/hhd`.

### Handheld Daemon (hhd) or InputPlumber

Bazzite enables InputPlumber and PowerStation on every non-Valve handheld (`bazzite-hardware-setup`) and no longer ships Handheld Daemon; you can still install hhd, which replaces InputPlumber. GameCove works with either:

| | InputPlumber | Handheld Daemon |
| --- | --- | --- |
| Guide / Quick Access in GameCove | Intercept over D-Bus, also inside games | Virtual pad's Guide while GameCove has focus; hhd's Steam shortcuts arrive as Ctrl+1 (home) and Ctrl+2 (quick menu). Inside a game hhd keeps its buttons (its own overlay). |
| Back paddles | Remap each paddle | As a whole: Steam Input, hhd shortcuts, touchpad, or off |
| Gyro | Off, mouse, stick | On / off (Steam Input maps it) |
| Rumble | On / off, test buzz | On / off (vibration intensity 0 or 100) |
| RGB | Not settable (no API) | Solid color and brightness (ROG Ally, Legion Go) |
| Per-game | InputPlumber profile per game | Controller section and LEDs of hhd's state per game |
| TDP | PowerStation / steamos-manager | hhd's API (when its TDP plugin is on) |

## Testing on your handheld

`gamecove-selftest` (installed with GameCove, source `packaging/bin/gamecove-selftest`) checks what GameCove needs on the handheld it runs on and writes one report, `~/gamecove-selftest-<device>-<date>.txt`. Run it from a terminal (Konsole) in Desktop Mode, as your normal user, on each handheld:

```
gamecove-selftest                      # reads only
gamecove-selftest --write              # also sets the TDP to its current value and reads it back
gamecove-selftest --interactive        # then: press each special button and paddle, move the device
gamecove-selftest --no-network         # skip the GitHub check
```

Automatic checks: the device GameCove detects (the app's `--selftest` mode: row id, support level, chip, GPU family, TDP range, fixes) and the DMI strings it matched on; OS / image, kernel, Mesa, GPU driver, Secure Boot state; a leftover global Claw EDID kernel argument (a failure on any other handheld); gamescope session or Desktop Mode; Steam running and signed in (yes/no only); InputPlumber or Handheld Daemon and which controllers it sees (both running is a warning: they fight); the TDP through Handheld Daemon (when its TDP plugin is on), steamos-manager or PowerStation, and with `--write` a write and read-back of the same value; whether RAPL / GPU power readings are readable by the user (Auto TDP and the overlay need one); every fix's `status` (fan, charge limit, Claw fixes); store tools (legendary, gogdl, nile, umu-run, Heroic), MangoHud and mangohudctl; GitHub releases reachable; free disk space.

`--interactive` asks for the home / Guide button, Quick Access, each back paddle and a tilt of the device, and watches every readable `/dev/input` device for a press (or gyro motion) for 10 seconds each; Enter skips a step. It names the device and button it saw (for example `Microsoft X-Box 360 pad 0: BTN_MODE`), which shows whether the press reached the virtual controller. Steam or GameCove may react to the presses if they run.

The report has no personal data: user and host names, serial numbers, MAC addresses, account names, Steam ids and tokens are never read or are replaced (`<user>`, `<steamid>`, `<redacted>`). The script prints the report and its path; attach it to a GitHub issue. It exits 1 when a check failed. Its tests (`packaging/tests/selftest.sh`, run by `packaging/tests/run.sh`) use a fake root and stub commands.

## Known issues per device

- **Steam Deck (LCD)**: Steam Deck controller is a HID device; InputPlumber's deck driver exposes L4/L5/R4/R5 as paddles and both trackpads.
- **Steam Deck (OLED)**: Panel runs 45-90 Hz; gamescope handles refresh switching.
- **ASUS ROG Ally**: TDP through the asus-armoury firmware attributes (steamos-manager); older kernels only have asus-wmi ppt_* files. Fan curves live in the asus_custom_fan_curve hwmon (GameCove's fan fix); changing the platform profile puts the factory curve back.
- **ASUS ROG Ally X**: Same controls as the ROG Ally; 80 Wh battery.
- **ASUS ROG Xbox Ally**: steamos-manager drives TDP through amdgpu hwmon (4-20 W) on this model.
- **ASUS ROG Xbox Ally X20**: DMI sys_vendor is 'ASUS', not 'ASUSTeK COMPUTER INC.' like older Allys. TDP copied from the Xbox Ally X until someone measures it.
- **Lenovo Legion Go**: Detachable controllers: gyro and buttons come from whichever halves are attached. TDP through lenovo-wmi-other firmware attributes in Lenovo's 'custom' mode (steamos-manager, kernel 6.17+); older kernels need hhd/acpi_call. Panel has no VRR; it switches between 60 and 144 Hz.
- **Lenovo Legion Go 2**: Also sold as the SteamOS edition (same DMI). Detachable controllers.
- **Lenovo Legion Go 2 (Z2)**: steamos-manager lists 83N1 as the 'Z2 SKU' (8AHP2).
- **Lenovo Legion Go S (Z2 Go)**: Also sold as the 'Powered by SteamOS' edition (same DMI, 83L3). hhd caps it at 33 W.
- **Lenovo Legion Go S (Z1 Extreme)**: SteamOS edition with Z1 Extreme uses the same DMI.
- **MSI Claw 8 EX AI+**: MSI buttons need the claw8ex-buttons fix on older InputPlumber. VRR floor is 48 Hz until the claw8ex-vrr fix. Gyro needs the sensor-hub firmware (claw8ex-gyro fix).
- **MSI Claw 8 AI+**: Has a gyro in hardware behind the Intel sensor hub; not exposed on Linux yet.
- **MSI Claw A1M**: hhd uses 20 W as the lowest useful TDP on this chip.
- **MSI Claw (unknown model)**: A Claw board we don't know yet; chip details come from the CPU.
- **OneXFly F1**: Fan and charge limit through the oxpec kernel driver (6.16+; oxp-sensors before).
- **OneXPlayer X1 (AMD)**: Detachable controllers; tablet with keyboard cover.
- **OneXPlayer X1 Pro**: Only PowerStation knows this DMI name; InputPlumber has no X1 Pro config yet, so its buttons may not work.
- **OneXPlayer 2**: Detachable controllers.
- **OneXPlayer 2 Pro**: Detachable controllers.
- **OneXPlayer G1 (AMD)**: Clamshell with a keyboard; no IMU in InputPlumber's config.
- **OneXPlayer 3**: Detachable controllers. Like the Claw 8 EX, Panther Lake TDP is written through intel-rapl-mmio (PowerStation).
- **OneXPlayer X2 Mini**: Chip comes from the CPU at run time.
- **OneXFly Apex**: PowerStation caps it at 35 W sustained; the chip can take far more when plugged in.
- **OneXPlayer Super X**: Tablet with detachable controllers; no InputPlumber config yet.
- **AOKZOE (unknown model)**: Covers newer AOKZOE models (e.g. A2) until they get their own row.
- **AYANEO 2S**: Fan, charge limit and RGB through the ayaneo-ec kernel driver (new; check your kernel).
- **AYANEO AIR Plus**: Three boards share the name; chip details come from the CPU when they differ.
- **AYANEO Flip**: Clamshell. The DS has a second 3.5in touch screen; its button maps to Keyboard in InputPlumber.
- **AYANEO 3**: Modular side modules; the IPS 120 Hz panel option exists too.
- **AYANEO Slide**: Slide-out keyboard.
- **AYANEO (unknown model)**: Covers newer AYANEO models (NEXT II, Konkr) until they get their own row.
- **GPD WIN 4**: Slide-out keyboard. Early units are 6800U (RDNA 2); chip details come from the CPU. Fan through the gpd-fan kernel driver (6.18+).
- **GPD WIN Mini**: Clamshell with touchpad. G1617-02 is the 2025 refresh; InputPlumber only matches G1617-01.
- **GPD WIN Max 2**: Small laptop with gamepad controls hidden under covers.
- **GPD WIN 5**: External battery pack; PowerStation allows up to 85 W.
- **ZOTAC Gaming Zone**: TDP and fan through the out-of-tree zotac_zone_platform driver (steamos-manager uses its firmware attributes). Two trackpads and two dials around the sticks.
- **Acer Predator Atlas 8**: InputPlumber config ships in Bazzite (devices.d/70-acer_atlas8.yaml), not upstream yet.
- **Acer Nitro Blaze 7**: DMI pattern is a guess from the model number; please send a device report.
- **Acer Nitro Blaze 8**: DMI pattern is a guess from the model number; please send a device report.
- **Acer Nitro Blaze 11**: DMI pattern is a guess from the model number; please send a device report.
- **Orange Pi Neo**: Two trackpads; ships with Manjaro.

## Not done yet (needs other parts of GameCove)

- **Fan control**: the `fan` fix drives `msi_wmi_platform`, `asus_custom_fan_curve` (Auto, Quiet, Max: fan tables), `oxp_ec`/`oxpec`, `ayaneo_ec`, `gpdfan` and `zotac_*` (Auto, Max: one duty, no safe fixed "quiet"); the Steam Deck uses steamos-manager's `FanControl1`. Lenovo's `lenovo_wmi_other` has no fan interface GameCove can drive yet. The Zotac driver is out of tree and its sysfs layout is unverified (`unverified: fan`).
- **Charge limit**: rows with `charge_limit_via: "sysfs"` go through the `charge-limit` fix too. OneXPlayer (oxpec) has `charge_control_end_threshold`; AYANEO's ayaneo-ec only has `charge_behaviour` (`auto` / `inhibit-charge`), so the fix holds charging while plugged in at or above the limit and GameCove re-runs it when the charger or the level crosses the line (every 15 s check, only while plugged in); unplugging always returns to `auto`.
- **RGB**: no GameCove control yet; InputPlumber exposes LEDs as `org.shadowblip.Input.Source.LEDDevice` on devices with a `led` source group (Ally, Go S, AYANEO, Zotac); Claw and Legion Go LEDs are driven by hhd today.
- **Legion Go charge limit**: with lenovo-wmi-other's battery extension (kernel 6.19+) the battery offers `charge_types` Long_Life (stops at 80 %); GameCove's `power.battery_long_life` control sets it through the power-tune helper. Older kernels: hhd/acpi_call only.
- **Custom fan curves**: `power.fan_curve` on the two table drivers (msi_wmi_platform, asus_custom_fan_curve); never quieter than the Quiet preset at any point. Every other power setting per device: [CONTROLS.md](CONTROLS.md#power-providerspowergd-scriptscontrolspower).
