# Credits

GameCove stands on a lot of other people's work. Thank you.

## People

- **Kisenir** (r/MSIClaw): found and tested how to bring up the MSI Claw 8 EX gyro on Linux (sensor-hub firmware, HID-BPF descriptor fix, keepalive and bias calibration). He gave us permission to use his work (2026-11-08). His HID-BPF program is GPL-2.0-only; his helper scripts are GPL-2.0-or-later once he confirms. GPL-2.0 text: [LICENSES/GPL-2.0-only.txt](LICENSES/GPL-2.0-only.txt).
- **HHHHanasak1**: xess-xmx-linux, XeSS on the XMX cores under Proton.

## Projects we use or build on

| Project | What for | License |
| --- | --- | --- |
| gamescope | Display, frame limit, scaling, overlay layering | BSD-2-Clause |
| Proton / umu-launcher | Running Windows games | Various / GPL-3.0 |
| InputPlumber | Controller input, button and gyro routing; device profiles and D-Bus API for paddles, gyro, rumble | GPL-3.0 |
| PowerStation | TDP, GPU clocks over D-Bus | GPL-3.0 |
| steamos-manager | TDP, GPU, charge limit over D-Bus | MIT |
| legendary, heroic-gogdl, nile | Epic, GOG, Amazon libraries, launch, install / update / repair / uninstall, progress output | GPL-3.0 |
| Heroic Games Launcher | Library, playtime, prefixes and art for games installed through Heroic | GPL-3.0 |
| gamescope-session-plus | The session GameCove runs in | see project |
| xprop (X.Org) | Setting gamescope atoms | MIT |
| MangoHud / mangoapp (flightlessmango) | Performance overlay and the game's frame timings (its log) | MIT |
| rpm-ostree | Checking and staging OS updates on Bazzite / Fedora Atomic | LGPL-2.0-or-later (parts GPL-2.0-or-later, Apache-2.0 OR MIT) |
| steamos-update helpers (Valve; OpenGamingCollective gamescope-session-steam) | OS updates the way Steam's Gaming Mode does them | MIT (OGC) |
| uupd (Universal Blue) | Runs Bazzite's updates behind steamos-update | Apache-2.0 |
| fwupd / LVFS | Firmware updates | LGPL-2.1-or-later |
| Flatpak | App updates | LGPL-2.1-or-later |
| util-linux (findmnt, lsblk) | Drives and free space | GPL-2.0-or-later |
| udev-hid-bpf | Loading HID-BPF fixes | GPL-2.0 |
| Godot Engine | UI | MIT |
| InputPlumber device configs and capability maps (ShadowBlip) | DMI matches, special-button and paddle capabilities, IMU and LED presence for every handheld in `devices.json` / `buttons.gd`; D-Bus intercept mode documented in DEVICES.md | GPL-3.0 |
| PowerStation APU and DMI-override databases (ShadowBlip) | TDP ranges and boost in `devices.json` and its `cpus` fallback table | GPL-3.0 |
| steamos-manager device files (Valve, Collabora, Igalia) | DMI ids, TDP / fan / charge-limit methods per handheld | MIT |
| Handheld Daemon adjustor (hhd-dev) | Per-device TDP tables and profile watts (ROG Ally family, Claw, Legion Go S cap, GPD); the ROG Ally fan curve points and minimum/default curves behind the ASUS "quiet" fan preset | GPL-3.0 (adjustor); hhd itself LGPL-2.1-or-later |
| Bazzite (Universal Blue) | Acer Predator Atlas 8 InputPlumber config (DMI board `F900_PTG`, QAM / M1 / M2 buttons) | Apache-2.0 |
| OpenGamepadUI (ShadowBlip) | How a gamescope main app takes Guide / QAM from InputPlumber (intercept mode) | GPL-3.0 |
| Outfit (Outfit Project Authors, github.com/Outfitio/Outfit-Fonts) | Display and heading type (SemiBold, Bold, ExtraBold; Latin subset in `app/fonts/`, licence `app/fonts/OFL-Outfit.txt`) | OFL-1.1 |
| Plus Jakarta Sans (Plus Jakarta Sans Project Authors, github.com/tokotype/PlusJakartaSans) | Interface text (Regular to Bold; Latin subset, `app/fonts/OFL-PlusJakartaSans.txt`) | OFL-1.1 |
| JetBrains Mono (JetBrains Mono Project Authors, github.com/JetBrains/JetBrainsMono) | Telemetry, counts and micro labels (Medium, Bold; Latin subset, `app/fonts/OFL-JetBrainsMono.txt`) | OFL-1.1 |
| Inter typeface | Banner lettering (`assets/banner.png` only; not bundled) | OFL-1.1 |
| QR Code encoder, kenyoni-software godot-addons (Iceflower S) | QR codes for store sign-in, vendored in `app/addons/kenyoni/qr_code/` (Kanji mode removed; see its README.GameCove.md) | MIT |

## Ideas and findings we borrowed

- **ClawDeck**: the Claw 8 EX power backend findings, launch environment, face-button and EDID findings, ported here.
- **DeckyTDPTuner**: ideas behind Auto TDP.
- **Zendo-GIT Intel-Handheld-and-ARC-GPU-laboratory** (MIT, © 2026 ClawLab contributors): the VRR range fix and the checked panel list. Notice reproduced in [fixes/claw8ex-vrr/LICENSE.ClawLab-MIT](fixes/claw8ex-vrr/LICENSE.ClawLab-MIT).
- **OpenGamepadUI** and **gamescope-x11-client**: how a gamescope main app sets its atoms and base layers.
- **Decky Loader** (GPL-2.0) and **@decky/ui / decky-frontend-lib** (LGPL-2.1): how to reach the Steam client's `SteamClient` API over CEF remote debugging (port, tab, `.cef-enable-remote-debugging`) and the API's method names, for the opt-in Steam control. No code copied.
- **Heroic Games Launcher**: how it runs legendary, gogdl and nile for installs and parses their progress; its `heroic://` protocol for hand-offs.
- **SteamKit2** (LGPL-2.1): the `EAppState` bit values behind appmanifest `StateFlags`.
- **OpenGamepadUI** (`core/systems/mangoapp/mangoapp.gd`, GPL-3.0) and **gamescope-session-plus** (MIT): driving mangoapp's overlay level through `MANGOHUD_CONFIGFILE`.
- **node-vdf** (Anthony Beaumont, MIT): the binary KeyValues type table our parser follows. **Achievement Watcher** / **celes** (GPL) and **Steam Achievement Manager** (gibbed, zlib): where Steam keeps achievement stats and how the schema is laid out. Our code is our own.
- **Bazzite** (Apache-2.0): its Gaming Mode update path (`os-update`, polkit rules) shows which update commands work without a password.
- **Heroic Games Launcher**: the GOG sign-in URL and where gogdl keeps its login.
- **HueSync** (honjow, GPL-3.0): tested RGB handling for handheld LED nodes (Legion Go ring profile/mode/enabled order and 0-100 channels, the Ally's 12-channel layout, kernel effect names, re-applying lights after resume), followed in `fixes/controller-led` and `app/scripts/controls/input/leds.gd`. **hhd-decky** (hhd-dev): where Handheld Daemon's HTTP port and token live. Our code is our own.
- **proton-cachyos** (CachyOS), **GE-Proton** (GloriousEggroll) and **low_latency_layer** (Korthos-Software): their docs for the launch variables we set.

## Data

| Source | Use | License |
| --- | --- | --- |
| Wikidata | Titles, dates, cross-store IDs (queried through QLever, University of Freiburg, with the Wikidata Query Service as fallback) | CC0 |
| AreWeAntiCheatYet | Anti-cheat status | MIT |
| Steam Web API (`GetGlobalAchievementPercentagesForApp`) | Global achievement rarity, at most once per game per day | Steam Web API Terms of Use |
| ProtonDB data dumps | Compatibility reports | ODbL (credit and share-alike) |
| IGDB | Time to beat; upcoming release dates (nightly, when the job has Twitch credentials) | Free for non-commercial use under the [Twitch Developer Service Agreement](https://api-docs.igdb.com/#getting-started); commercial use needs an IGDB partnership; credit IGDB.com |
| SteamGridDB | Optional artwork, only with each user's own API key | [Terms](https://www.steamgriddb.com/terms): personal, non-commercial use; no key ships with GameCove |
| [CheapShark](https://www.cheapshark.com) | Which stores have a game on sale and by how much, links, and (US only, where they're the local price) prices and historical lows | [API terms](https://apidocs.cheapshark.com/): free, no key; deals must be opened through CheapShark's redirect links (we never use affiliate or direct links for CheapShark deals); descriptive User-Agent; no catalogue crawling. Price data by CheapShark. |
| Steam (Valve) | Prices for the user's country, sale end dates, release state and art by app id (`IStoreBrowseService/GetItems`); public wishlist import (`IWishlistService/GetWishlist`); coming-soon list for the nightly calendar (`IStoreQueryService/Query`); custom-URL lookup through the public profile XML | [Steam Web API Terms of Use](https://steamcommunity.com/dev/apiterms); called without a key; not affiliated with or endorsed by Valve. Game art © its publishers, shown to identify the game. |
| [GG.deals](https://gg.deals/) | Optional: best official-store price and historical low in your region's currency for Steam games, with your own free API key | [API terms](https://gg.deals/api/): free plan for personal, hobby and open-source use; credit GG.deals with an active link wherever its data is shown; its referral links are never altered or removed (rows open its URLs unchanged); 100 ids/min, 1,000/hour per key. No key ships with GameCove. |
| European Central Bank | Euro reference exchange rates, published in the nightly upcoming.json.gz; not used for any price the app shows | [ECB reuse policy](https://www.ecb.europa.eu/stats/ecb_statistics/governance_and_quality_framework/html/usage_policy.en.html): free for any use, unmodified, with credit. Source: ECB statistics. |
| Wikidata | Upcoming release dates for the calendar | CC0 |

We looked at IsThereAnyDeal for regional deal prices and don't use it: its [API terms](https://docs.isthereanydeal.com/) forbid apps "that could be considered a competition to IsThereAnyDeal" and using the API to help its competition, which a deals and price-alert feature next to CheapShark could be read as.

GOG and Epic prices for your country aren't shown (their rows say "See price"):
- GOG: the catalog API does return local prices, but the [GOG User Agreement](https://support.gog.com/hc/articles/212632089) (effective 9 March 2026, clause 11.1(e)) forbids software that "interact[s] with or affect[s] GOG services or GOG content in any way", so we don't call it.
- Epic: store search (store.epicgames.com/graphql) sits behind a Cloudflare challenge, which we won't get around, and the open free-games promotions feed only covers the week's free and featured games. Epic's [Terms of Service](https://legal.epicgames.com/epicgames/tos) (10 Sept 2026) don't address reading its store data, and our rule is to leave out unclear sources.
| IGDB | Time to beat | IGDB terms; credit IGDB.com |
| SteamGridDB | Optional artwork, with each user's own key | SteamGridDB terms |
| Maker spec pages and launch coverage (ASUS, Lenovo, MSI, OneXPlayer, AYANEO, GPD, Acer, ZOTAC) | Panel size, resolution and refresh in `devices.json` | facts, cited per row in `sources` |

Device data was taken as facts (DMI strings, wattages, capability names, which buttons exist), rewritten into GameCove's own format; no code was copied from these projects. The button glyphs and device pictures in `app/assets/devices/` are original drawings made for GameCove (generated by `app/assets/devices/_tools/gen_svgs.py`, GPL-3.0-or-later) and contain no maker logos.

## Device photos

"About this device" and the first-run welcome show a real photo of your handheld when a freely licensed one exists on [Wikimedia Commons](https://commons.wikimedia.org/). The photos aren't in the app: the weekly `device-photos` workflow re-checks each license through the Commons API, scales the photo to 1200 px wide, converts it to WebP and publishes it to the `device-photos` release; the app downloads only your device's photo, once. Converting and resizing is the only change made. Each photo stays under its own license (below), not GameCove's GPL; the credit line under the photo in the app links to its Commons page. Where a row lists more than one device, the models look the same from the front and share the photo.

| Device | Commons file | Author | License |
| --- | --- | --- | --- |
| Steam Deck (LCD) | [Steam Deck (front).png](https://commons.wikimedia.org/wiki/File:Steam_Deck_(front).png) | Liam Dawe/GamingOnLinux (PNG version by VulcanSphere) | [CC BY-SA 4.0](https://creativecommons.org/licenses/by-sa/4.0/) |
| Steam Deck (OLED) | [Steam Deck OLED framsida hemskärm.jpg](https://commons.wikimedia.org/wiki/File:Steam_Deck_OLED_framsida_hemsk%C3%A4rm.jpg) | SparklesTrainNerd | [CC BY-SA 4.0](https://creativecommons.org/licenses/by-sa/4.0/) |
| ASUS ROG Ally | [Asus ROG Ally.jpg](https://commons.wikimedia.org/wiki/File:Asus_ROG_Ally.jpg) | TheHDGamer2008 | [CC BY-SA 4.0](https://creativecommons.org/licenses/by-sa/4.0/) |
| ASUS ROG Ally X | [Tokyo-Game-Show-2024-Day4---2024-09-29 235.jpg](https://commons.wikimedia.org/wiki/File:Tokyo-Game-Show-2024-Day4---2024-09-29_235.jpg) | RuinDig/Yuki Uchida | [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/) |
| ASUS ROG Xbox Ally | [ROG XBOX ALLY.jpg](https://commons.wikimedia.org/wiki/File:ROG_XBOX_ALLY.jpg) | Kyu3a | [CC BY-SA 4.0](https://creativecommons.org/licenses/by-sa/4.0/) |
| ASUS ROG Xbox Ally X | [ROG XBOX ALLY X.jpg](https://commons.wikimedia.org/wiki/File:ROG_XBOX_ALLY_X.jpg) | Kyu3a | [CC BY-SA 4.0](https://creativecommons.org/licenses/by-sa/4.0/) |
| Lenovo Legion Go | [Lenovo Legion Go.jpg](https://commons.wikimedia.org/wiki/File:Lenovo_Legion_Go.jpg) | TaurusEmerald | [CC BY-SA 4.0](https://creativecommons.org/licenses/by-sa/4.0/) |
| MSI Claw A1M | [MSI Claw - Co poszło nie tak¿ (2160p 30fps AV1-128kbit AAC)-00.08.15.665.png](https://commons.wikimedia.org/wiki/File:MSI_Claw_-_Co_posz%C5%82o_nie_tak%C2%BF_(2160p_30fps_AV1-128kbit_AAC)-00.08.15.665.png) | ZMASLO | [CC BY 3.0](https://creativecommons.org/licenses/by/3.0/) |
| OneXFly F1, OneXFly F1 Pro | [Tokyo-Game-Show-2024-Day4---2024-09-29 469.jpg](https://commons.wikimedia.org/wiki/File:Tokyo-Game-Show-2024-Day4---2024-09-29_469.jpg) | RuinDig/Yuki Uchida | [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/) |
| OneXPlayer X1 Mini | [Tokyo-Game-Show-2024-Day4---2024-09-29 477.jpg](https://commons.wikimedia.org/wiki/File:Tokyo-Game-Show-2024-Day4---2024-09-29_477.jpg) | RuinDig/Yuki Uchida | [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/) |
| OneXPlayer 2 Pro, OneXPlayer 2 | [Tokyo-Game-Show-2023-Day3-2023-09-23 381.jpg](https://commons.wikimedia.org/wiki/File:Tokyo-Game-Show-2023-Day3-2023-09-23_381.jpg) | RuinDig/Yuki Uchida | [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/) |
| AOKZOE A1, AOKZOE A1 Pro | [AOKZOE A1.jpg](https://commons.wikimedia.org/wiki/File:AOKZOE_A1.jpg) | Kyu3a | [CC BY-SA 4.0](https://creativecommons.org/licenses/by-sa/4.0/) |
| AYANEO Slide | [Tokyo-Game-Show-2023-Day3-2023-09-23 393.jpg](https://commons.wikimedia.org/wiki/File:Tokyo-Game-Show-2023-Day3-2023-09-23_393.jpg) | RuinDig/Yuki Uchida | [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/) |
| AYANEO 3 | [Tokyo-Game-Show-2025 0728.jpg](https://commons.wikimedia.org/wiki/File:Tokyo-Game-Show-2025_0728.jpg) | RuinDig/Yuki Uchida | [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/) |

## Trademarks

Product and company names are trademarks of their respective owners; GameCove is not affiliated with or endorsed by them.

GameCove shows a company's logo only when that company's own published terms let a free, unaffiliated app do so without asking (checked 2026-11-08; the table and its sources are in [`app/data/brand_logos.json`](app/data/brand_logos.json)). Everyone else's name is shown as plain text.

| Logo | Notice |
| --- | --- |
| Heroic Games Launcher icon (`app/assets/brand/heroic.svg`) | Heroic Games Launcher icon © Heroic Games Launcher contributors, GPL-3.0-only ([github.com/Heroic-Games-Launcher/HeroicGamesLauncher](https://github.com/Heroic-Games-Launcher/HeroicGamesLauncher)). Unmodified. |

Store and launcher icons other than these (Steam, Heroic, Lutris, Bottles) come from the user's own system: GameCove shows the icon that app installed into the desktop icon theme, the same way any Linux desktop does. Nothing is copied into GameCove or redistributed. Steam is a trademark of Valve Corporation.

Not bundled because their terms need a licence or written permission, or publish no terms for third parties: Valve (Steam, Steam Deck), Epic Games, GOG, Amazon, MSI, ASUS / ROG, Lenovo / Legion, Acer / Predator, OneXPlayer, AYANEO, GPD, ZOTAC, Intel. AMD's brand terms cover only products that contain an AMD chip.
