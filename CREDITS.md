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
| Inter typeface | Banner lettering | OFL-1.1 |

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
- **proton-cachyos** (CachyOS), **GE-Proton** (GloriousEggroll) and **low_latency_layer** (Korthos-Software): their docs for the launch variables we set.

## Data

| Source | Use | License |
| --- | --- | --- |
| Wikidata | Titles, dates, cross-store IDs | CC0 |
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
